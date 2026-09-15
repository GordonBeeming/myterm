package store

import (
	"bytes"
	"context"
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
	rotated, err := storage.RotateRefresh(context.Background(), "refresh-one", "refresh-two", "access-two", now.Add(time.Minute), now.Add(time.Hour), now)
	if err != nil {
		t.Fatal(err)
	}
	if rotated.ID != device.ID {
		t.Fatalf("refresh changed device identity: %s != %s", rotated.ID, device.ID)
	}
	if _, err := storage.AuthenticateAccess(context.Background(), "access-one", now); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("old access token survived rotation: %v", err)
	}
	replayed, err := storage.RotateRefresh(context.Background(), "refresh-one", "refresh-three", "access-three", now.Add(time.Minute), now.Add(time.Hour), now)
	if !errors.Is(err, ErrUnauthorized) || replayed.ID != device.ID {
		t.Fatalf("old refresh token survived rotation: %v", err)
	}
	if _, err := storage.AuthenticateAccess(context.Background(), "access-two", now); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("refresh replay did not revoke descendant access: %v", err)
	}
	if _, err := storage.RotateRefresh(context.Background(), "refresh-two", "refresh-four", "access-four", now.Add(time.Minute), now.Add(time.Hour), now); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("refresh replay left descendant refresh active: %v", err)
	}
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
