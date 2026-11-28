use ed25519_dalek::SigningKey;
use myterm_local_terminal::enrollment::{
    AccountGenesis, Authority, CredentialMode, EnrollmentRequest, Error, HolderProof,
    IssueCredential, ManagementRequest, MembershipOperation, Signed, SigningIdentity,
};
use rand::rngs::OsRng;

#[test]
fn single_use_redemption_is_bound_to_one_identity_and_retries_after_restart() {
    let path = tempfile::tempdir().unwrap();
    let directory = path.path().join("authority");
    let first_client = SigningKey::generate(&mut OsRng);
    let authority_signer = SigningKey::generate(&mut OsRng);
    let holder = SigningKey::generate(&mut OsRng);
    let genesis = Signed::sign(
        &first_client,
        &AccountGenesis::new(&first_client, &authority_signer, &mut OsRng),
    )
    .unwrap();
    let account = AccountGenesis::anchor(&genesis).unwrap();
    let mut authority =
        Authority::open(&directory, &genesis, account.clone(), &authority_signer).unwrap();
    let request = Signed::sign(
        &first_client,
        &IssueCredential {
            account: account.clone(),
            operation: "0123456789abcdef0123456789abcdef".into(),
            creator: SigningIdentity::from_key(&first_client),
            holder: SigningIdentity::from_key(&holder),
            mode: CredentialMode::SingleUse,
            lifetime_seconds: None,
        },
    )
    .unwrap();
    let credential = authority.issue(&request).unwrap();

    assert_eq!(authority.issue(&request).unwrap(), credential);
    drop(authority);

    let presentations: Vec<_> = (0..12)
        .map(|_| {
            let server = SigningKey::generate(&mut OsRng);
            let enrollment = EnrollmentRequest::new(
                account.clone(),
                &credential,
                &authority_signer.verifying_key(),
                &server,
                "Build server".into(),
                false,
            )
            .unwrap();
            let signed = Signed::sign(&server, &enrollment).unwrap();
            let possession = Signed::sign(&holder, &HolderProof::new(&signed).unwrap()).unwrap();
            (signed, possession)
        })
        .collect();
    let barrier = std::sync::Barrier::new(presentations.len());
    let results = std::thread::scope(|scope| {
        let contenders: Vec<_> = presentations
            .iter()
            .map(|(signed, possession)| {
                let credential = &credential;
                let directory = &directory;
                let genesis = &genesis;
                let signer = &authority_signer;
                let account = &account;
                let barrier = &barrier;
                scope.spawn(move || {
                    let authority = Authority::open(directory, genesis, account.clone(), signer);
                    barrier.wait();
                    authority?.redeem(credential, signed, possession)
                })
            })
            .collect();
        contenders
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .collect::<Vec<_>>()
    });
    let mut restarted = Authority::open(&directory, &genesis, account, &authority_signer).unwrap();
    let mut winner_count = 0;
    for ((signed, possession), result) in presentations.iter().zip(results) {
        match result {
            Ok(receipt) => {
                winner_count += 1;
                assert_eq!(
                    restarted.redeem(&credential, signed, possession).unwrap(),
                    receipt
                );
            }
            Err(Error::CredentialConsumed) => {}
            Err(error) => panic!("Unexpected enrollment result: {error:?}"),
        }
    }
    assert_eq!(winner_count, 1);
    assert_eq!(restarted.events_after(0).unwrap().len(), 2);
}

#[test]
fn fresh_approval_consumes_a_single_use_credential_and_records_the_retry() {
    let path = tempfile::tempdir().unwrap();
    let directory = path.path().join("authority");
    let first_client = SigningKey::generate(&mut OsRng);
    let authority_signer = SigningKey::generate(&mut OsRng);
    let holder = SigningKey::generate(&mut OsRng);
    let genesis = Signed::sign(
        &first_client,
        &AccountGenesis::new(&first_client, &authority_signer, &mut OsRng),
    )
    .unwrap();
    let account = AccountGenesis::anchor(&genesis).unwrap();
    let mut authority =
        Authority::open(&directory, &genesis, account.clone(), &authority_signer).unwrap();
    let client = SigningIdentity::from_key(&first_client);
    let issued = Signed::sign(
        &first_client,
        &IssueCredential {
            account: account.clone(),
            operation: "1".repeat(32),
            creator: client.clone(),
            holder: SigningIdentity::from_key(&holder),
            mode: CredentialMode::SingleUse,
            lifetime_seconds: None,
        },
    )
    .unwrap();
    let credential = authority.issue(&issued).unwrap();
    let create_enrollment = || {
        let server = SigningKey::generate(&mut OsRng);
        let request = EnrollmentRequest::new(
            account.clone(),
            &credential,
            &authority_signer.verifying_key(),
            &server,
            "Build server".into(),
            false,
        )
        .unwrap();
        Signed::sign(&server, &request).unwrap()
    };
    let approval = |operation: String, enrollment: Signed| {
        Signed::sign(
            &first_client,
            &ManagementRequest {
                account: account.clone(),
                operation,
                actor: client.clone(),
                change: MembershipOperation::FreshApprove(enrollment),
            },
        )
        .unwrap()
    };
    let enrolled = create_enrollment();
    let receipt = authority
        .manage(&approval("2".repeat(32), enrolled.clone()))
        .unwrap();
    assert_eq!(
        authority
            .manage(&approval("3".repeat(32), enrolled))
            .unwrap(),
        receipt
    );
    assert!(matches!(
        authority.manage(&approval("3".repeat(32), create_enrollment())),
        Err(Error::IdentityConflict)
    ));
    assert!(matches!(
        authority.manage(&approval("4".repeat(32), create_enrollment())),
        Err(Error::CredentialConsumed)
    ));
}

#[test]
fn saturated_deployment_can_be_revoked_and_another_deployment_can_enroll() {
    use myterm_local_terminal::enrollment::MembershipEvent;
    let started = std::time::Instant::now();
    let path = tempfile::tempdir().unwrap();
    let directory = path.path().join("authority");
    let first_client = SigningKey::generate(&mut OsRng);
    let authority_signer = SigningKey::generate(&mut OsRng);
    let holder = SigningKey::generate(&mut OsRng);
    let replacement_holder = SigningKey::generate(&mut OsRng);
    let genesis = Signed::sign(
        &first_client,
        &AccountGenesis::new(&first_client, &authority_signer, &mut OsRng),
    )
    .unwrap();
    let account = AccountGenesis::anchor(&genesis).unwrap();
    let mut authority =
        Authority::open(&directory, &genesis, account.clone(), &authority_signer).unwrap();
    let owner = SigningIdentity::from_key(&first_client);
    let issue = |holder: &SigningKey, operation: &str| {
        Signed::sign(
            &first_client,
            &IssueCredential {
                account: account.clone(),
                operation: operation.into(),
                creator: owner.clone(),
                holder: SigningIdentity::from_key(holder),
                mode: CredentialMode::Reusable,
                lifetime_seconds: None,
            },
        )
        .unwrap()
    };
    let credential = authority
        .issue(&issue(&holder, "10000000000000000000000000000000"))
        .unwrap();
    let make_presentation = |issuer, holder: &SigningKey| {
        let server = SigningKey::generate(&mut OsRng);
        let request = EnrollmentRequest::new(
            account.clone(),
            issuer,
            &authority_signer.verifying_key(),
            &server,
            "Build server".into(),
            false,
        )
        .unwrap();
        let signed = Signed::sign(&server, &request).unwrap();
        let possession = Signed::sign(holder, &HolderProof::new(&signed).unwrap()).unwrap();
        (request, signed, possession)
    };
    let first = make_presentation(&credential, &holder);
    let initial_receipt = authority.redeem(&credential, &first.1, &first.2).unwrap();
    for _ in 1..360 {
        let (_, signed, possession) = make_presentation(&credential, &holder);
        authority.redeem(&credential, &signed, &possession).unwrap();
    }
    let rejected = make_presentation(&credential, &holder);
    assert!(matches!(
        authority.redeem(&credential, &rejected.1, &rejected.2),
        Err(Error::AdmissionLimited)
    ));
    assert_eq!(
        authority.redeem(&credential, &first.1, &first.2).unwrap(),
        initial_receipt
    );
    let management = |operation: &str, change| {
        Signed::sign(
            &first_client,
            &ManagementRequest {
                account: account.clone(),
                operation: operation.into(),
                actor: owner.clone(),
                change,
            },
        )
        .unwrap()
    };
    authority
        .manage(&management(
            "10000000000000000000000000000001",
            MembershipOperation::RevokeCredential(first.0.credential),
        ))
        .unwrap();
    assert!(matches!(
        authority.redeem(&credential, &rejected.1, &rejected.2),
        Err(Error::FreshApprovalRequired)
    ));
    authority
        .manage(&management(
            "10000000000000000000000000000002",
            MembershipOperation::RemoveIdentity(first.0.server),
        ))
        .unwrap();
    assert!(matches!(
        authority.redeem(&credential, &first.1, &first.2),
        Err(Error::IdentityRemoved)
    ));
    let replacement = authority
        .issue(&issue(
            &replacement_holder,
            "10000000000000000000000000000003",
        ))
        .unwrap();
    let (_, signed, possession) = make_presentation(&replacement, &replacement_holder);
    let admitted = authority
        .redeem(&replacement, &signed, &possession)
        .unwrap();
    let event: MembershipEvent = admitted.verify(&authority_signer.verifying_key()).unwrap();
    assert_eq!(event.sequence, 365);
    assert_eq!(authority.events_after(0).unwrap().len(), 128);
    let bytes = std::fs::metadata(directory.join("enrollment.sqlite3"))
        .unwrap()
        .len();
    println!(
        "360 admissions, subsequent denial, revocation/removal and replacement admission: {:?}, SQLite bytes {bytes}",
        started.elapsed()
    );
}
