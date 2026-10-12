package store

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"errors"
	"testing"
	"time"
)

func TestAuthorizationCodeRefreshRotationAndRevocation(t *testing.T) {
	storage, owner := newStoreTest(t)
	now := time.Now()
	oauth := OAuthContext{RedirectURI: "myterm-companion://auth/callback", CodeChallenge: "challenge", DeviceName: "iPhone", DeviceKind: "client"}
	if err := storage.SaveAuthCode(context.Background(), "code", owner.ID, oauth, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := storage.ExchangeAuthCode(context.Background(), "code", oauth.RedirectURI, "wrong", now); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("wrong PKCE challenge: %v", err)
	}
	device, err := storage.ExchangeAuthCode(context.Background(), "code", oauth.RedirectURI, oauth.CodeChallenge, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := storage.CreateDeviceTokens(context.Background(), device, "access-one", "refresh-one", now.Add(time.Minute), now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}
	if _, err := storage.AuthenticateAccess(context.Background(), "access-one", now); err != nil {
		t.Fatal(err)
	}
	rotated, err := storage.RotateRefresh(context.Background(), "refresh-one", "refresh-two", "access-two", now.Add(time.Minute), now.Add(time.Hour), now, testReplayGrace)
	if err != nil {
		t.Fatal(err)
	}
	if rotated.ID != device.ID {
		t.Fatalf("refresh changed device identity: %s != %s", rotated.ID, device.ID)
	}
	if _, err := storage.AuthenticateAccess(context.Background(), "access-one", now); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("old access token survived rotation: %v", err)
	}
	// Past the grace window, so this still asserts what it was written to assert: a replay that is
	// not a client catching up on a lost reply costs the device its registration. The clock has to
	// move or the grace path would answer and the theft response would go untested.
	late := now.Add(testReplayGrace + time.Minute)
	replayed, err := storage.RotateRefresh(context.Background(), "refresh-one", "refresh-three", "access-three", late.Add(time.Minute), late.Add(time.Hour), late, testReplayGrace)
	if !errors.Is(err, ErrUnauthorized) || replayed.ID != device.ID {
		t.Fatalf("old refresh token survived rotation: %v", err)
	}
	if _, err := storage.AuthenticateAccess(context.Background(), "access-two", late); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("refresh replay did not revoke descendant access: %v", err)
	}
	if _, err := storage.RotateRefresh(context.Background(), "refresh-two", "refresh-four", "access-four", late.Add(time.Minute), late.Add(time.Hour), late, testReplayGrace); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("refresh replay left descendant refresh active: %v", err)
	}
}

// Matches the relay's shipped default so the tests exercise the window the deployment uses.
const testReplayGrace = 60 * time.Second

// Every deployed relay has a database that predates `consumed_at`, and a migration that fails takes
// the relay down on start rather than degrading. Opening twice covers the second launch, where a
// bare ALTER would fail on the column already being there.
func TestOpeningADatabaseWithoutConsumedAtAddsItAndStaysOpenable(t *testing.T) {
	path := t.TempDir() + "/relay.sqlite3"

	old, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := old.Exec(`CREATE TABLE devices (
		id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
		refresh_hash BLOB, refresh_expires_at INTEGER NOT NULL, revoked_at INTEGER,
		created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
	CREATE TABLE used_refresh_tokens (
		token_hash BLOB PRIMARY KEY,
		device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
		expires_at INTEGER NOT NULL);`); err != nil {
		t.Fatal(err)
	}
	if err := old.Close(); err != nil {
		t.Fatal(err)
	}

	for attempt := 1; attempt <= 2; attempt++ {
		storage, err := Open(context.Background(), path)
		if err != nil {
			t.Fatalf("open %d: %v", attempt, err)
		}
		var count int
		if err := storage.db.QueryRow(
			"SELECT COUNT(*) FROM pragma_table_info('used_refresh_tokens') WHERE name='consumed_at'",
		).Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != 1 {
			t.Fatalf("open %d left consumed_at missing", attempt)
		}
		if err := storage.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestRefreshReplayInsideGraceServesTheClientInsteadOfRevokingIt(t *testing.T) {
	storage, device, now := newDeviceWithTokens(t)

	if _, err := storage.RotateRefresh(context.Background(), "refresh-one", "refresh-two", "access-two", now.Add(time.Minute), now.Add(time.Hour), now, testReplayGrace); err != nil {
		t.Fatal(err)
	}

	// The client never saw that reply, so it asks again with the token it still holds. This is the
	// shape a Mac produces when it sleeps between the request and the response.
	retry := now.Add(4 * time.Second)
	served, err := storage.RotateRefresh(context.Background(), "refresh-one", "refresh-three", "access-three", retry.Add(time.Minute), retry.Add(time.Hour), retry, testReplayGrace)
	if err != nil {
		t.Fatalf("a retry inside the grace window was refused: %v", err)
	}
	if served.ID != device.ID {
		t.Fatalf("grace rotation changed device identity: %s != %s", served.ID, device.ID)
	}
	if revoked := revokedAt(t, storage, device.ID); revoked.Valid {
		t.Fatal("a retry inside the grace window revoked the device")
	}
	if _, err := storage.AuthenticateAccess(context.Background(), "access-three", retry); err != nil {
		t.Fatalf("grace rotation did not issue a usable access token: %v", err)
	}
}

func TestRefreshReplayOutsideGraceStillRevokesTheDevice(t *testing.T) {
	storage, device, now := newDeviceWithTokens(t)

	if _, err := storage.RotateRefresh(context.Background(), "refresh-one", "refresh-two", "access-two", now.Add(time.Minute), now.Add(time.Hour), now, testReplayGrace); err != nil {
		t.Fatal(err)
	}

	late := now.Add(testReplayGrace + time.Second)
	if _, err := storage.RotateRefresh(context.Background(), "refresh-one", "refresh-three", "access-three", late.Add(time.Minute), late.Add(time.Hour), late, testReplayGrace); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("a replay past the grace window was served: %v", err)
	}
	if revoked := revokedAt(t, storage, device.ID); !revoked.Valid {
		t.Fatal("a replay past the grace window left the device live")
	}
	if _, err := storage.AuthenticateAccess(context.Background(), "access-two", late); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("a replay past the grace window left an access token working: %v", err)
	}
}

func TestGraceRotationIssuesATokenThatWorksAndRetiresTheOneReplayed(t *testing.T) {
	storage, _, now := newDeviceWithTokens(t)

	if _, err := storage.RotateRefresh(context.Background(), "refresh-one", "refresh-two", "access-two", now.Add(time.Minute), now.Add(time.Hour), now, testReplayGrace); err != nil {
		t.Fatal(err)
	}
	retry := now.Add(4 * time.Second)
	if _, err := storage.RotateRefresh(context.Background(), "refresh-one", "refresh-three", "access-three", retry.Add(time.Minute), retry.Add(time.Hour), retry, testReplayGrace); err != nil {
		t.Fatal(err)
	}

	// The token the grace path handed back has to be a real rotation, or the fix degrades into
	// accepting a consumed token forever.
	next := retry.Add(time.Second)
	if _, err := storage.RotateRefresh(context.Background(), "refresh-three", "refresh-five", "access-five", next.Add(time.Minute), next.Add(time.Hour), next, testReplayGrace); err != nil {
		t.Fatalf("the token issued by the grace rotation did not work: %v", err)
	}
	// And the one it replaced must not still rotate once the window has passed.
	late := next.Add(testReplayGrace + time.Second)
	if _, err := storage.RotateRefresh(context.Background(), "refresh-two", "refresh-six", "access-six", late.Add(time.Minute), late.Add(time.Hour), late, testReplayGrace); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("a token superseded by the grace rotation still rotated: %v", err)
	}
}

// A device holding "access-one" / "refresh-one", the starting point for the replay tests.
func newDeviceWithTokens(t *testing.T) (*Store, Device, time.Time) {
	t.Helper()
	storage, owner := newStoreTest(t)
	now := time.Now()
	oauth := OAuthContext{RedirectURI: "myterm-companion://auth/callback", CodeChallenge: "challenge", DeviceName: "blastoise", DeviceKind: "host"}
	if err := storage.SaveAuthCode(context.Background(), "code", owner.ID, oauth, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	device, err := storage.ExchangeAuthCode(context.Background(), "code", oauth.RedirectURI, oauth.CodeChallenge, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := storage.CreateDeviceTokens(context.Background(), device, "access-one", "refresh-one", now.Add(time.Minute), now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}
	return storage, device, now
}

func revokedAt(t *testing.T, storage *Store, deviceID string) sql.NullInt64 {
	t.Helper()
	var revoked sql.NullInt64
	if err := storage.db.QueryRow("SELECT revoked_at FROM devices WHERE id=?", deviceID).Scan(&revoked); err != nil {
		t.Fatal(err)
	}
	return revoked
}

func TestAuthorizationCodeReplayRevokesIssuedDeviceAndClosesExchangeRace(t *testing.T) {
	storage, owner := newStoreTest(t)
	now := time.Now()
	oauth := OAuthContext{RedirectURI: "myterm-companion://auth/callback", CodeChallenge: "challenge", DeviceName: "Phone", DeviceKind: "client"}
	exchange := func(code string) Device {
		if err := storage.SaveAuthCode(context.Background(), code, owner.ID, oauth, now.Add(time.Minute)); err != nil {
			t.Fatal(err)
		}
		device, err := storage.ExchangeAuthCode(context.Background(), code, oauth.RedirectURI, oauth.CodeChallenge, now)
		if err != nil {
			t.Fatal(err)
		}
		return device
	}
	device := exchange("normal-replay")
	if err := storage.CreateDeviceTokens(context.Background(), device, "access", "refresh", now.Add(time.Minute), now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}
	if replayed, err := storage.ExchangeAuthCode(context.Background(), "normal-replay", oauth.RedirectURI, oauth.CodeChallenge, now); !errors.Is(err, ErrConsumed) || replayed.ID != device.ID {
		t.Fatalf("replay result %+v %v", replayed, err)
	}
	if _, err := storage.AuthenticateAccess(context.Background(), "access", now); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("replay left issued access active: %v", err)
	}
	raceDevice := exchange("race-replay")
	if _, err := storage.ExchangeAuthCode(context.Background(), "race-replay", oauth.RedirectURI, oauth.CodeChallenge, now); !errors.Is(err, ErrConsumed) {
		t.Fatalf("race replay: %v", err)
	}
	if err := storage.CreateDeviceTokens(context.Background(), raceDevice, "race-access", "race-refresh", now.Add(time.Minute), now.Add(time.Hour), now); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("race created tokens after replay: %v", err)
	}
	device = exchange("wrong-proof")
	if _, err := storage.ExchangeAuthCode(context.Background(), "wrong-proof", "myterm-dev://companion-auth/callback", oauth.CodeChallenge, now); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("wrong callback replay: %v", err)
	}
	if err := storage.CreateDeviceTokens(context.Background(), device, "proof-access", "proof-refresh", now.Add(time.Minute), now.Add(time.Hour), now); err != nil {
		t.Fatalf("wrong proof revoked legitimate exchange: %v", err)
	}
}

func TestStableHostRegistrationAndOneUsePairingEnvelope(t *testing.T) {
	storage, owner := newStoreTest(t)
	now := time.Now()
	first := Device{ID: mustID(t), OwnerID: owner.ID, Kind: "host", Name: "Mac login one"}
	second := Device{ID: mustID(t), OwnerID: owner.ID, Kind: "host", Name: "Mac login two"}
	for index, device := range []Device{first, second} {
		if err := storage.CreateDeviceTokens(context.Background(), device, "access-"+string(rune('a'+index)), "refresh-"+string(rune('a'+index)), now.Add(time.Hour), now.Add(time.Hour), now); err != nil {
			t.Fatal(err)
		}
	}
	hostID := mustID(t)
	if _, err := storage.UpsertHost(context.Background(), Host{ID: hostID, OwnerID: owner.ID, DeviceID: first.ID, Name: "Mac"}, bytes.Repeat([]byte{1}, 32), now); err != nil {
		t.Fatal(err)
	}
	updated, err := storage.UpsertHost(context.Background(), Host{ID: hostID, OwnerID: owner.ID, DeviceID: second.ID, Name: "Renamed Mac"}, bytes.Repeat([]byte{2}, 32), now.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if updated.ID != hostID {
		t.Fatalf("stable host ID changed: %s", updated.ID)
	}
	hosts, err := storage.ListHosts(context.Background(), owner.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) != 1 || hosts[0].DeviceID != second.ID || hosts[0].Name != "Renamed Mac" {
		t.Fatalf("unexpected stable host update: %+v", hosts)
	}

	envelope := bytes.Repeat([]byte{9}, 64)
	if err := storage.CreatePairingTicket(context.Background(), owner.ID, hostID, "public-ticket", envelope, now.Add(time.Minute), now); err != nil {
		t.Fatal(err)
	}
	ticket, err := storage.TakePairingTicket(context.Background(), owner.ID, "public-ticket", now)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := base64.RawURLEncoding.DecodeString(ticket.EncryptedEnvelope)
	if err != nil || !bytes.Equal(decoded, envelope) {
		t.Fatalf("opaque envelope changed: %v", err)
	}
	if _, err := storage.TakePairingTicket(context.Background(), owner.ID, "public-ticket", now); !errors.Is(err, ErrConsumed) {
		t.Fatalf("ticket was reusable: %v", err)
	}
}

func TestOwnerEnrollmentPurposeAndCredentialFailureRollBackToken(t *testing.T) {
	storage, owner := newStoreTest(t)
	now := time.Now()
	token, _ := NewToken(32)
	if err := storage.CreateOwnerEnrollmentToken(context.Background(), token, "add", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := storage.AddOrRecoverCredential(context.Background(), owner.ID, "recover", CredentialRecord{ID: []byte("wrong-purpose"), JSON: []byte(`{}`)}, HashToken(token), now); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("wrong purpose: %v", err)
	}
	if _, err := storage.AddOrRecoverCredential(context.Background(), owner.ID, "add", CredentialRecord{ID: []byte("credential-two"), JSON: []byte(`{}`)}, HashToken(token), now); err != nil {
		t.Fatalf("purpose token was consumed by wrong purpose: %v", err)
	}
	rollbackToken, _ := NewToken(32)
	if err := storage.CreateOwnerEnrollmentToken(context.Background(), rollbackToken, "add", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := storage.AddOrRecoverCredential(context.Background(), owner.ID, "add", CredentialRecord{ID: []byte("credential"), JSON: []byte(`{}`)}, HashToken(rollbackToken), now); err == nil {
		t.Fatal("duplicate credential unexpectedly added")
	}
	if _, err := storage.AddOrRecoverCredential(context.Background(), owner.ID, "add", CredentialRecord{ID: []byte("credential-three"), JSON: []byte(`{}`)}, HashToken(rollbackToken), now); err != nil {
		t.Fatalf("transaction failure consumed token: %v", err)
	}
}

func newStoreTest(t *testing.T) (*Store, Owner) {
	t.Helper()
	storage, err := Open(context.Background(), "file:"+t.Name()+"?mode=memory&cache=shared")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { storage.Close() })
	bootstrap, _ := NewToken(32)
	if err := storage.CreateBootstrapToken(context.Background(), bootstrap, time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	owner := Owner{ID: mustID(t), WebAuthnID: []byte("owner-handle"), Name: "owner", DisplayName: "Owner"}
	if err := storage.CreateOwnerCredential(context.Background(), owner, CredentialRecord{ID: []byte("credential"), JSON: []byte(`{"id":"Y3JlZGVudGlhbA"}`)}, bootstrap, time.Now()); err != nil {
		t.Fatal(err)
	}
	return storage, owner
}

func mustID(t *testing.T) string {
	t.Helper()
	id, err := NewID()
	if err != nil {
		t.Fatal(err)
	}
	return id
}
