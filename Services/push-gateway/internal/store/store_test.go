package store

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestSQLiteRecoveryGrantScopingRotationAndRevocation(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.sqlite3")
	s, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	first, firstToken := seedDevice(t, s, "key-one", now)
	second, _ := seedDevice(t, s, "key-two", now)
	grantToken := "grant-one"
	grant := Grant{ID: uuid.NewString(), RecipientID: first.RecipientID, RelayOrigin: "https://relay.example.com", HostID: uuid.NewString(), HostPublicKey: bytes.Repeat([]byte{1}, 65)}
	if err = s.CreateGrant(ctx, grant, grantToken, now); err != nil {
		t.Fatal(err)
	}
	if err = s.RotateGrant(ctx, second.RecipientID, grant.ID, "stolen", now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross recipient rotation: %v", err)
	}
	if _, err = s.GrantByToken(ctx, grantToken); err != nil {
		t.Fatal(err)
	}
	if err = s.RotateGrant(ctx, first.RecipientID, grant.ID, "grant-two", now); err != nil {
		t.Fatal(err)
	}
	if _, err = s.GrantByToken(ctx, grantToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("old token survived: %v", err)
	}
	if err = s.RevokeGrant(ctx, second.RecipientID, grant.ID, now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross recipient revoke: %v", err)
	}
	if err = s.RevokeGrant(ctx, first.RecipientID, grant.ID, now); err != nil {
		t.Fatal(err)
	}
	if _, err = s.GrantByToken(ctx, "grant-two"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("revoked grant survived: %v", err)
	}
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	recovered, err := s.AuthenticateDevice(ctx, firstToken, now)
	if err != nil || recovered.RecipientID != first.RecipientID {
		t.Fatalf("SQLite recovery: %+v %v", recovered, err)
	}
}

func TestAPNSTokenChallengeIsRecipientScopedAndOneUse(t *testing.T) {
	s, err := Open(context.Background(), ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now()
	first, _ := seedDevice(t, s, "one", now)
	second, _ := seedDevice(t, s, "two", now)
	challenge := []byte("challenge")
	record := APNSTokenChallenge{ID: uuid.NewString(), RecipientID: first.RecipientID, PendingToken: strings.Repeat("a", 64), Challenge: challenge, ExpiresAt: now.Add(time.Minute).Unix()}
	if err = s.CreateAPNSTokenChallenge(context.Background(), record); err != nil {
		t.Fatal(err)
	}
	if err = s.ConfirmAPNSToken(context.Background(), second.RecipientID, record.ID, challenge, now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross recipient confirm: %v", err)
	}
	if err = s.ConfirmAPNSToken(context.Background(), first.RecipientID, record.ID, []byte("wrong"), now); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("wrong challenge: %v", err)
	}
	if err = s.ConfirmAPNSToken(context.Background(), first.RecipientID, record.ID, challenge, now); err != nil {
		t.Fatal(err)
	}
	if err = s.ConfirmAPNSToken(context.Background(), first.RecipientID, record.ID, challenge, now); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("challenge replay: %v", err)
	}
}

func seedDevice(t *testing.T, s *Store, keyID string, now time.Time) (Device, string) {
	t.Helper()
	id := uuid.NewString()
	challenge := []byte("initial")
	if err := s.CreateEnrollment(context.Background(), Enrollment{ID: id, Challenge: challenge, ExpiresAt: now.Add(time.Minute).Unix()}); err != nil {
		t.Fatal(err)
	}
	e := Enrollment{ID: id, KeyID: keyID, AppAttestPublicKey: bytes.Repeat([]byte{2}, 65), Receipt: []byte("receipt"), DevicePublicKey: bytes.Repeat([]byte{3}, 65), PendingAPNSToken: strings.Repeat("b", 64), APNSChallenge: []byte("push"), ExpiresAt: now.Add(time.Minute).Unix()}
	if err := s.CompleteAttestation(context.Background(), id, e.KeyID, e.AppAttestPublicKey, e.Receipt, e.DevicePublicKey, e.PendingAPNSToken, e.APNSChallenge, now); err != nil {
		t.Fatal(err)
	}
	session := "session-" + keyID
	recipient := "recipient-" + keyID
	if err := s.Activate(context.Background(), id, e, 1, recipient, session, now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}
	return Device{RecipientID: recipient}, session
}
