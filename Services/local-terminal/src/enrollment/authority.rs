use super::statements::valid_id;
use super::{
    AccountGenesis, Admission, Credential, CredentialMode, EnrollmentRequest, Error, HolderProof,
    IssueCredential, ManagementRequest, MembershipEvent, MembershipOperation, Result, Signed,
    SigningIdentity,
};
use ed25519_dalek::SigningKey;
use rusqlite::{
    params, Connection, OpenFlags, OptionalExtension, Transaction, TransactionBehavior,
};
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const EVENT_PAGE_SIZE: u32 = 128;
const ADMISSIONS_PER_HOUR: i64 = 360;
const ADMISSION_WINDOW_SECONDS: i64 = 3_600;

pub struct Authority {
    connection: Connection,
    account: String,
    first_client: SigningIdentity,
    signer: SigningKey,
    clock_start: i64,
    started_at: Instant,
}

impl Authority {
    pub fn open(
        directory: &Path,
        genesis: &Signed,
        account: String,
        signer: &SigningKey,
    ) -> Result<Self> {
        Self::open_database(directory, genesis, account, signer, true)
    }

    pub(super) fn reopen(
        directory: &Path,
        genesis: &Signed,
        account: String,
        signer: &SigningKey,
    ) -> Result<Self> {
        Self::open_database(directory, genesis, account, signer, false)
    }

    fn open_database(
        directory: &Path,
        genesis: &Signed,
        account: String,
        signer: &SigningKey,
        initialize: bool,
    ) -> Result<Self> {
        if AccountGenesis::anchor(genesis)? != account {
            return Err(Error::WrongAccount);
        }
        let genesis: AccountGenesis = genesis.read()?;
        if SigningIdentity::from_key(signer) != genesis.authority {
            return Err(Error::UntrustedEndpoint);
        }
        let mut flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW;
        if initialize {
            super::storage::prepare_state_directory(directory)?;
            flags |= OpenFlags::SQLITE_OPEN_CREATE;
        } else {
            super::storage::validate_state_directory(directory)?;
        }
        let mut connection = Connection::open_with_flags(
            directory.canonicalize()?.join("enrollment.sqlite3"),
            flags,
        )?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch(
            "PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA fullfsync=ON;",
        )?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let version: i64 = transaction.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if version == 0 && initialize {
            transaction.execute_batch(include_str!("enrollment.sql"))?;
            transaction.execute(
                "INSERT INTO account VALUES (1, ?1, ?1, 0, ?2)",
                params![account, wall_clock()?],
            )?;
        } else if version != 1 {
            return Err(Error::InvalidArtifact);
        }
        let (stored_account, last_clock): (String, i64) = transaction.query_row(
            "SELECT anchor, last_clock FROM account WHERE singleton = 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        if stored_account != account {
            return Err(Error::WrongAccount);
        }
        transaction.commit()?;
        Ok(Self {
            connection,
            account,
            first_client: genesis.first_client,
            signer: signer.clone(),
            clock_start: wall_clock()?.max(last_clock),
            started_at: Instant::now(),
        })
    }

    pub fn issue(&mut self, signed: &Signed) -> Result<Signed> {
        let untrusted: IssueCredential = signed.read()?;
        let request: IssueCredential = signed.verify(&untrusted.creator.key()?)?;
        let actor = request.creator.id()?;
        let holder = request.holder.id()?;
        self.check_request(&request.account, &request.operation)?;
        if request.creator == request.holder
            || request.holder == self.first_client
            || request.holder == SigningIdentity::from_key(&self.signer)
        {
            return Err(Error::InvalidCredential);
        }
        let ttl = request.mode.lifetime(request.lifetime_seconds)?;
        let request_digest = signed.digest::<IssueCredential>()?;
        let clock = (self.clock_start, self.started_at);
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        require_actor(&tx, &self.first_client, &request.creator)?;
        if let Some(saved) = operation_result(&tx, &actor, &request.operation, &request_digest)? {
            return Ok(saved);
        }
        if identity_exists(&tx, &holder)? || holder_exists(&tx, &holder)? {
            return Err(Error::InvalidCredential);
        }
        let now = record_clock(&tx, clock)?;
        let credential = Credential {
            account: self.account.clone(),
            id: request_digest.clone(),
            creator: request.creator,
            holder: request.holder,
            mode: request.mode,
            issued_at: now,
            expires_at: now.checked_add(ttl).ok_or(Error::InvalidCredential)?,
        };
        let certificate = Signed::sign(&self.signer, &credential)?;
        let id = credential.id.clone();
        let sequence = append(
            &tx,
            &self.signer,
            &self.account,
            MembershipOperation::Issue(credential),
        )?
        .0;
        tx.execute(
            "INSERT INTO credentials (id, holder, issue_sequence) VALUES (?1, ?2, ?3)",
            params![id, holder, sequence],
        )?;
        save_operation(
            &tx,
            &actor,
            &request.operation,
            &request_digest,
            &certificate,
        )?;
        tx.commit()?;
        Ok(certificate)
    }

    pub fn redeem(
        &mut self,
        certificate: &Signed,
        signed: &Signed,
        possession: &Signed,
    ) -> Result<Signed> {
        let credential =
            Credential::verify(certificate, &self.account, &self.signer.verifying_key())?;
        let request = EnrollmentRequest::verify(signed, &self.account)?;
        HolderProof::verify(possession, signed, &credential)?;
        if request.credential != credential.id {
            return Err(Error::InvalidCredential);
        }
        let admission = Admission {
            request,
            enrollment_digest: signed.digest::<EnrollmentRequest>()?,
            confirmed_by: None,
        };
        let clock = (self.clock_start, self.started_at);
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let server = admission.request.server.id()?;
        check_server_role(
            &tx,
            &self.signer,
            &self.first_client,
            &admission.request.server,
            &server,
        )?;
        if let Some(existing) = admission_retry(&tx, &server, &admission.enrollment_digest)? {
            return Ok(existing);
        }
        let (revoked, allocated, window, count) = tx
            .query_row(
                "SELECT revoked, allocated, rate_window, rate_count FROM credentials WHERE id = ?1",
                [&credential.id],
                |row| {
                    Ok((
                        row.get::<_, bool>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                    ))
                },
            )
            .optional()?
            .ok_or(Error::InvalidCredential)?;
        if allocated.is_some() {
            return Err(Error::CredentialConsumed);
        }
        let now = record_clock(&tx, clock)?;
        if revoked || now < credential.issued_at || now >= credential.expires_at {
            // Persist the observed clock even though the credential could not be used.
            tx.commit()?;
            return Err(Error::FreshApprovalRequired);
        }
        let (window_start, rate_count) = if now - window < ADMISSION_WINDOW_SECONDS {
            (window, count)
        } else {
            (now, 0)
        };
        if rate_count >= ADMISSIONS_PER_HOUR {
            return Err(Error::AdmissionLimited);
        }
        let allocated = (credential.mode == CredentialMode::SingleUse).then_some(&server);
        tx.execute(
            "UPDATE credentials SET allocated = ?1, rate_window = ?2, rate_count = ?3 WHERE id = ?4",
            params![allocated, window_start, rate_count + 1, credential.id],
        )?;
        let receipt = admit(&tx, &self.signer, &self.account, &server, admission)?;
        tx.commit()?;
        Ok(receipt)
    }

    pub fn manage(&mut self, signed: &Signed) -> Result<Signed> {
        let untrusted: ManagementRequest = signed.read()?;
        let request: ManagementRequest = signed.verify(&untrusted.actor.key()?)?;
        let actor = request.actor.id()?;
        self.check_request(&request.account, &request.operation)?;
        let digest = signed.digest::<ManagementRequest>()?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        require_actor(&tx, &self.first_client, &request.actor)?;
        if let Some(saved) = operation_result(&tx, &actor, &request.operation, &digest)? {
            return Ok(saved);
        }
        let receipt = match request.change {
            MembershipOperation::RevokeCredential(id) => {
                if !valid_id(&id, 64)
                    || tx.execute("UPDATE credentials SET revoked = 1 WHERE id = ?1", [&id])? == 0
                {
                    return Err(Error::InvalidCredential);
                }
                append(
                    &tx,
                    &self.signer,
                    &self.account,
                    MembershipOperation::RevokeCredential(id),
                )?
                .1
            }
            MembershipOperation::RemoveIdentity(target) => {
                if target == SigningIdentity::from_key(&self.signer) {
                    return Err(Error::UntrustedEndpoint);
                }
                tx.execute(
                    "INSERT INTO tombstones (id) VALUES (?1) ON CONFLICT DO NOTHING",
                    [target.id()?],
                )?;
                append(
                    &tx,
                    &self.signer,
                    &self.account,
                    MembershipOperation::RemoveIdentity(target),
                )?
                .1
            }
            MembershipOperation::FreshApprove(enrollment) => {
                let proposed = EnrollmentRequest::verify(&enrollment, &self.account)?;
                let server = proposed.server.id()?;
                check_server_role(
                    &tx,
                    &self.signer,
                    &self.first_client,
                    &proposed.server,
                    &server,
                )?;
                let request_digest = enrollment.digest::<EnrollmentRequest>()?;
                if let Some(existing) = admission_retry(&tx, &server, &request_digest)? {
                    return Ok(existing);
                }
                let recorded: bool = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM credentials WHERE id = ?1)",
                    [&proposed.credential],
                    |row| row.get(0),
                )?;
                if !recorded {
                    return Err(Error::InvalidCredential);
                }
                admit(
                    &tx,
                    &self.signer,
                    &self.account,
                    &server,
                    Admission {
                        request: proposed,
                        enrollment_digest: request_digest,
                        confirmed_by: Some(request.actor),
                    },
                )?
            }
            _ => return Err(Error::InvalidArtifact),
        };
        save_operation(&tx, &actor, &request.operation, &digest, &receipt)?;
        tx.commit()?;
        Ok(receipt)
    }

    pub fn events_after(&self, sequence: i64) -> Result<Vec<Signed>> {
        if sequence < 0 {
            return Err(Error::InvalidArtifact);
        }
        let mut statement = self
            .connection
            .prepare("SELECT receipt FROM events WHERE sequence > ?1 ORDER BY sequence LIMIT ?2")?;
        let receipts = statement.query_map(params![sequence, EVENT_PAGE_SIZE], |row| {
            row.get::<_, Vec<u8>>(0)
        })?;
        receipts.map(|receipt| unpack(receipt?)).collect()
    }

    fn check_request(&self, account: &str, operation: &str) -> Result<()> {
        if account != self.account {
            return Err(Error::WrongAccount);
        }
        if !valid_id(operation, 32) {
            return Err(Error::InvalidArtifact);
        }
        Ok(())
    }
}

fn record_clock(tx: &Transaction, (started_wall, started_at): (i64, Instant)) -> Result<i64> {
    let elapsed = i64::try_from(started_at.elapsed().as_secs()).map_err(|_| Error::Clock)?;
    let projected = started_wall.checked_add(elapsed).ok_or(Error::Clock)?;
    let now = wall_clock()?.max(projected);
    Ok(tx.query_row(
        "UPDATE account SET last_clock = max(last_clock, ?1) WHERE singleton = 1 RETURNING last_clock",
        [now], |row| row.get(0),
    )?)
}

fn wall_clock() -> Result<i64> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Error::Clock)?;
    i64::try_from(elapsed.as_secs()).map_err(|_| Error::Clock)
}

fn require_actor(
    tx: &Transaction,
    first_client: &SigningIdentity,
    actor: &SigningIdentity,
) -> Result<()> {
    let id = actor.id()?;
    if is_removed(tx, &id)? || (actor != first_client && !identity_exists(tx, &id)?) {
        return Err(Error::UntrustedEndpoint);
    }
    Ok(())
}

fn identity_exists(tx: &Transaction, id: &str) -> Result<bool> {
    Ok(tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM admissions WHERE id = ?1)",
        [id],
        |row| row.get(0),
    )?)
}

fn holder_exists(tx: &Transaction, id: &str) -> Result<bool> {
    Ok(tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM credentials WHERE holder = ?1)",
        [id],
        |row| row.get(0),
    )?)
}

fn is_removed(tx: &Transaction, id: &str) -> Result<bool> {
    Ok(tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM tombstones WHERE id = ?1)",
        [id],
        |row| row.get(0),
    )?)
}

fn check_server_role(
    tx: &Transaction,
    authority: &SigningKey,
    first_client: &SigningIdentity,
    server: &SigningIdentity,
    id: &str,
) -> Result<()> {
    if is_removed(tx, id)? {
        return Err(Error::IdentityRemoved);
    }
    if server == first_client
        || server == &SigningIdentity::from_key(authority)
        || holder_exists(tx, id)?
    {
        return Err(Error::IdentityConflict);
    }
    Ok(())
}

fn admission_retry(tx: &Transaction, id: &str, digest: &str) -> Result<Option<Signed>> {
    let prior = tx.query_row(
        "SELECT a.request_digest, e.receipt FROM admissions a JOIN events e ON e.sequence = a.sequence WHERE a.id = ?1",
        [id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?)),
    ).optional()?;
    match prior {
        Some((previous, _)) if previous != digest => Err(Error::IdentityConflict),
        Some((_, receipt)) => Ok(Some(unpack(receipt)?)),
        None => Ok(None),
    }
}

fn admit(
    tx: &Transaction,
    signer: &SigningKey,
    account: &str,
    server: &str,
    admission: Admission,
) -> Result<Signed> {
    let digest = admission.enrollment_digest.clone();
    let (sequence, receipt) = append(tx, signer, account, MembershipOperation::Admit(admission))?;
    tx.execute(
        "INSERT INTO admissions (id, request_digest, sequence) VALUES (?1, ?2, ?3)",
        params![server, digest, sequence],
    )?;
    Ok(receipt)
}

fn append(
    tx: &Transaction,
    signer: &SigningKey,
    account: &str,
    change: MembershipOperation,
) -> Result<(i64, Signed)> {
    let (last_sequence, previous): (i64, String) = tx.query_row(
        "SELECT sequence, head FROM account WHERE singleton = 1",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let sequence = last_sequence.checked_add(1).ok_or(Error::InvalidArtifact)?;
    let event = MembershipEvent {
        account: account.into(),
        sequence,
        previous,
        change,
    };
    let receipt = Signed::sign(signer, &event)?;
    tx.execute(
        "INSERT INTO events (sequence, receipt) VALUES (?1, ?2)",
        params![sequence, pack(&receipt)?],
    )?;
    tx.execute(
        "UPDATE account SET sequence = ?1, head = ?2 WHERE singleton = 1",
        params![sequence, receipt.digest::<MembershipEvent>()?],
    )?;
    Ok((sequence, receipt))
}

fn operation_result(
    tx: &Transaction,
    actor: &str,
    operation: &str,
    digest: &str,
) -> Result<Option<Signed>> {
    let prior = tx
        .query_row(
            "SELECT request_digest, result FROM operations WHERE actor = ?1 AND operation = ?2",
            [actor, operation],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?)),
        )
        .optional()?;
    match prior {
        Some((previous, _)) if previous != digest => Err(Error::IdentityConflict),
        Some((_, result)) => Ok(Some(unpack(result)?)),
        None => Ok(None),
    }
}

fn save_operation(
    tx: &Transaction,
    actor: &str,
    operation: &str,
    digest: &str,
    result: &Signed,
) -> Result<()> {
    tx.execute(
        "INSERT INTO operations (actor, operation, request_digest, result) VALUES (?1, ?2, ?3, ?4)",
        params![actor, operation, digest, pack(result)?],
    )?;
    Ok(())
}

fn pack(signed: &Signed) -> Result<Vec<u8>> {
    serde_json::to_vec(signed).map_err(|_| Error::InvalidArtifact)
}

fn unpack(bytes: Vec<u8>) -> Result<Signed> {
    serde_json::from_slice(&bytes).map_err(|_| Error::InvalidArtifact)
}
