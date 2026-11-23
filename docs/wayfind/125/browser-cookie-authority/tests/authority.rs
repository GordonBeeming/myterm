use myterm_browser_cookie_authority_probe::{
    ApprovedClientScope, Authority, Change, Rejection, Scope,
};
use std::fs;
use tempfile::tempdir;

// Fixed, public key and values for the disposable test store.
const KEY: [u8; 32] = [3u8; 32];
const SESSION: &str = "example.test / session";

fn scope(account: &str, server: &str, profile: &str) -> Scope {
    Scope {
        account: account.into(),
        server: server.into(),
        profile: profile.into(),
    }
}

fn change(key: &str, prior: Option<u64>, value: Option<&str>) -> Change {
    Change {
        cookie_key: key.into(),
        previous_version: prior,
        value: value.map(str::to_owned),
    }
}

#[test]
fn approved_peers_share_the_same_server_profile_in_both_directions_and_after_restart() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("cookie-state");
    let scope = scope("account-a", "server-a", "profile-a");
    let phone = ApprovedClientScope(scope.clone());
    let tablet = ApprovedClientScope(scope.clone());
    let mut server = Authority::create(scope.clone(), &path, &KEY).unwrap();
    let epoch = server.snapshot(&phone).unwrap().epoch;
    server
        .apply(
            &phone,
            epoch,
            vec![change(SESSION, None, Some("fixture-phone-sign-in"))],
        )
        .unwrap();
    let snapshot = server.snapshot(&tablet).unwrap();
    assert_eq!(
        snapshot.entries[SESSION].value.as_deref(),
        Some("fixture-phone-sign-in")
    );
    server
        .apply(
            &tablet,
            epoch,
            vec![change(
                SESSION,
                Some(snapshot.entries[SESSION].version),
                Some("fixture-tablet-sign-in"),
            )],
        )
        .unwrap();
    drop(server);
    let server = Authority::open(scope, &path, &KEY).unwrap();
    assert_eq!(
        server.snapshot(&phone).unwrap().entries[SESSION]
            .value
            .as_deref(),
        Some("fixture-tablet-sign-in")
    );
    assert!(!fs::read(&path)
        .unwrap()
        .windows(b"fixture-tablet-sign-in".len())
        .any(|bytes| bytes == b"fixture-tablet-sign-in"));
}

#[test]
fn signout_cannot_be_undone_by_an_offline_writer_after_restart() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("cookie-state");
    let scope = scope("account-a", "server-a", "profile-a");
    let client = ApprovedClientScope(scope.clone());
    let mut server = Authority::create(scope.clone(), &path, &KEY).unwrap();
    server
        .apply(
            &client,
            0,
            vec![change(SESSION, None, Some("fixture-active"))],
        )
        .unwrap();
    let stale_version = server.snapshot(&client).unwrap().entries[SESSION].version;
    server
        .apply(&client, 0, vec![change(SESSION, Some(stale_version), None)])
        .unwrap();
    drop(server);
    let mut server = Authority::open(scope, &path, &KEY).unwrap();
    for prior in [None, Some(stale_version)] {
        let stale_update = vec![change(SESSION, prior, Some("fixture-stale"))];
        assert_eq!(
            server.apply(&client, 0, stale_update),
            Err(Rejection::Conflict)
        );
    }
    assert_eq!(
        server.snapshot(&client).unwrap().entries[SESSION].value,
        None
    );
}

#[test]
fn independent_changes_merge_but_a_conflicting_batch_is_atomic() {
    let directory = tempdir().unwrap();
    let scope = scope("account-a", "server-a", "profile-a");
    let client = ApprovedClientScope(scope.clone());
    let mut server =
        Authority::create(scope, &directory.path().join("cookie-state"), &KEY).unwrap();
    let left = "example.test / left";
    let right = "example.test / right";
    server
        .apply(&client, 0, vec![change(left, None, Some("left"))])
        .unwrap();
    server
        .apply(&client, 0, vec![change(right, None, Some("right"))])
        .unwrap();
    assert_eq!(server.snapshot(&client).unwrap().entries.len(), 2);
    let conflicting = vec![
        change("example.test / new", None, Some("new")),
        change(left, None, Some("stale")),
    ];
    assert_eq!(
        server.apply(&client, 0, conflicting),
        Err(Rejection::Conflict)
    );
    assert_eq!(server.snapshot(&client).unwrap().entries.len(), 2);
}

#[test]
fn either_workspace_can_disable_sharing_and_old_epochs_cannot_write_after_reenable() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("cookie-state");
    let scope = scope("account-a", "server-a", "profile-a");
    let client = ApprovedClientScope(scope.clone());
    let mut server = Authority::create(scope.clone(), &path, &KEY).unwrap();
    let previous_epoch = server.snapshot(&client).unwrap().epoch;
    server.set_workspace_opt_out("workspace-a", true).unwrap();
    server.set_workspace_opt_out("workspace-b", true).unwrap();
    server.set_workspace_opt_out("workspace-a", false).unwrap();
    drop(server);
    let mut server = Authority::open(scope, &path, &KEY).unwrap();
    assert!(matches!(
        server.snapshot(&client),
        Err(Rejection::SharingDisabled)
    ));
    assert_eq!(
        server.apply(
            &client,
            previous_epoch,
            vec![change(SESSION, None, Some("offline"))]
        ),
        Err(Rejection::SharingDisabled)
    );
    server.set_workspace_opt_out("workspace-b", false).unwrap();
    assert_eq!(
        server.apply(
            &client,
            previous_epoch,
            vec![change(SESSION, None, Some("offline"))]
        ),
        Err(Rejection::StaleSharingPolicy)
    );
    let refreshed_epoch = server.snapshot(&client).unwrap().epoch;
    server
        .apply(
            &client,
            refreshed_epoch,
            vec![change(SESSION, None, Some("current"))],
        )
        .unwrap();
}

#[test]
fn another_account_server_or_profile_cannot_use_the_same_jar_or_its_copied_ciphertext() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("cookie-state");
    let home = scope("account-a", "server-a", "profile-a");
    let client = ApprovedClientScope(home.clone());
    let mut server = Authority::create(home, &path, &KEY).unwrap();
    server
        .apply(
            &client,
            0,
            vec![change(SESSION, None, Some("fixture-value"))],
        )
        .unwrap();
    for foreign in [
        scope("account-b", "server-a", "profile-a"),
        scope("account-a", "server-b", "profile-a"),
        scope("account-a", "server-a", "profile-b"),
    ] {
        let foreign_client = ApprovedClientScope(foreign.clone());
        assert!(matches!(
            server.snapshot(&foreign_client),
            Err(Rejection::ForeignScope)
        ));
        assert_eq!(
            server.apply(
                &foreign_client,
                0,
                vec![change(SESSION, None, Some("foreign"))]
            ),
            Err(Rejection::ForeignScope)
        );
        assert!(matches!(
            Authority::open(foreign, &path, &KEY),
            Err(Rejection::UnreadableState)
        ));
    }
    let mut bytes = fs::read(&path).unwrap();
    let last = bytes.last_mut().unwrap();
    *last ^= 1;
    fs::write(&path, bytes).unwrap();
    assert!(matches!(
        Authority::open(client.0, &path, &KEY),
        Err(Rejection::UnreadableState)
    ));
}

#[test]
fn unsuccessful_disk_commit_does_not_publish_the_new_value() {
    let directory = tempdir().unwrap();
    let root = directory.path().join("profile");
    fs::create_dir(&root).unwrap();
    let path = root.join("cookie-state");
    let scope = scope("account-a", "server-a", "profile-a");
    let client = ApprovedClientScope(scope.clone());
    let mut server = Authority::create(scope, &path, &KEY).unwrap();
    fs::rename(&root, directory.path().join("unavailable")).unwrap();
    assert_eq!(
        server.apply(&client, 0, vec![change(SESSION, None, Some("uncommitted"))]),
        Err(Rejection::StorageFailure)
    );
    assert!(server.snapshot(&client).unwrap().entries.is_empty());
}

#[test]
fn missing_state_fails_closed_and_creation_refuses_existing_state() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("cookie-state");
    let scope = scope("account-a", "server-a", "profile-a");
    assert!(matches!(
        Authority::open(scope.clone(), &path, &KEY),
        Err(Rejection::UnreadableState)
    ));
    let mut server = Authority::create(scope.clone(), &path, &KEY).unwrap();
    let client = ApprovedClientScope(scope.clone());
    server
        .apply(&client, 0, vec![change(SESSION, None, Some("existing"))])
        .unwrap();
    drop(server);
    assert!(matches!(
        Authority::create(scope.clone(), &path, &KEY),
        Err(Rejection::StorageFailure)
    ));
    let server = Authority::open(scope, &path, &KEY).unwrap();
    assert_eq!(
        server.snapshot(&client).unwrap().entries[SESSION]
            .value
            .as_deref(),
        Some("existing")
    );
}
