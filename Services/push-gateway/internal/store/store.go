package store

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	_ "embed"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

//go:embed migrations.sql
var migrations string
var ErrNotFound = errors.New("not found")
var ErrConflict = errors.New("conflict")
var ErrExpired = errors.New("expired")
var ErrUnauthorized = errors.New("unauthorized")

type Store struct{ db *sql.DB }
type Enrollment struct {
	ID                                           string
	Challenge                                    []byte
	ExpiresAt                                    int64
	KeyID                                        string
	AppAttestPublicKey, Receipt, DevicePublicKey []byte
	Counter                                      uint32
	PendingAPNSToken                             string
	APNSChallenge                                []byte
}
type Device struct {
	RecipientID      string
	DevicePublicKey  []byte
	APNSToken        string
	SessionExpiresAt int64
	Active           bool
}
type Grant struct {
	ID, RecipientID, RelayOrigin, HostID string
	HostPublicKey                        []byte
}
type APNSTokenChallenge struct {
	ID, RecipientID, PendingToken string
	Challenge                     []byte
	ExpiresAt                     int64
}

func Open(ctx context.Context, path string) (*Store, error) {
	if path != ":memory:" && !strings.HasPrefix(path, "file:") {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return nil, err
		}
	}
	dsn := path
	if path == ":memory:" {
		dsn = "file:push-gateway?mode=memory&cache=shared"
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err = db.ExecContext(ctx, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;"); err != nil {
		db.Close()
		return nil, err
	}
	if _, err = db.ExecContext(ctx, migrations); err != nil {
		db.Close()
		return nil, err
	}
	if path != ":memory:" && !strings.HasPrefix(path, "file:") {
		if err = os.Chmod(path, 0600); err != nil {
			db.Close()
			return nil, err
		}
	}
	return &Store{db}, nil
}
func (s *Store) Close() error                   { return s.db.Close() }
func (s *Store) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }
func Token(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
func Random(n int) ([]byte, error) { b := make([]byte, n); _, err := rand.Read(b); return b, err }
func Hash(value string) []byte     { h := sha256.Sum256([]byte(value)); return h[:] }

func (s *Store) CreateEnrollment(ctx context.Context, e Enrollment) error {
	_, err := s.db.ExecContext(ctx, "INSERT INTO enrollments(id,challenge,expires_at) VALUES(?,?,?)", e.ID, e.Challenge, e.ExpiresAt)
	return err
}
func (s *Store) Enrollment(ctx context.Context, id string, now time.Time) (Enrollment, error) {
	var e Enrollment
	err := s.db.QueryRowContext(ctx, "SELECT id,challenge,expires_at FROM enrollments WHERE id=? AND attested_at IS NULL", id).Scan(&e.ID, &e.Challenge, &e.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return e, ErrNotFound
	}
	if err != nil {
		return e, err
	}
	if e.ExpiresAt <= now.Unix() {
		return e, ErrExpired
	}
	return e, nil
}
func (s *Store) CompleteAttestation(ctx context.Context, id, keyID string, appKey, receipt, deviceKey []byte, apnsToken string, apnsChallenge []byte, now time.Time) error {
	r, err := s.db.ExecContext(ctx, `UPDATE enrollments SET attested_at=?,key_id=?,app_attest_public_key=?,app_attest_receipt=?,app_attest_counter=0,device_public_key=?,pending_apns_token=?,apns_challenge=? WHERE id=? AND attested_at IS NULL AND expires_at>?`, now.Unix(), keyID, appKey, receipt, deviceKey, apnsToken, apnsChallenge, id, now.Unix())
	if err != nil {
		return err
	}
	if n, _ := r.RowsAffected(); n != 1 {
		return ErrConflict
	}
	return nil
}
func (s *Store) DeleteEnrollment(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, "DELETE FROM enrollments WHERE id=? AND activated_at IS NULL", id)
	return err
}
func (s *Store) PendingActivation(ctx context.Context, id string, now time.Time) (Enrollment, error) {
	var e Enrollment
	err := s.db.QueryRowContext(ctx, `SELECT id,key_id,app_attest_public_key,app_attest_receipt,app_attest_counter,device_public_key,pending_apns_token,apns_challenge,expires_at FROM enrollments WHERE id=? AND attested_at IS NOT NULL AND activated_at IS NULL`, id).Scan(&e.ID, &e.KeyID, &e.AppAttestPublicKey, &e.Receipt, &e.Counter, &e.DevicePublicKey, &e.PendingAPNSToken, &e.APNSChallenge, &e.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return e, ErrNotFound
	}
	if err != nil {
		return e, err
	}
	if e.ExpiresAt <= now.Unix() {
		return e, ErrExpired
	}
	return e, nil
}
func (s *Store) Activate(ctx context.Context, enrollmentID string, e Enrollment, newCounter uint32, recipientID, session string, sessionExpiry time.Time, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	r, err := tx.ExecContext(ctx, "UPDATE enrollments SET activated_at=?,app_attest_counter=? WHERE id=? AND activated_at IS NULL", now.Unix(), newCounter, enrollmentID)
	if err != nil {
		return err
	}
	if n, _ := r.RowsAffected(); n != 1 {
		return ErrConflict
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO devices(recipient_id,key_id,app_attest_public_key,app_attest_receipt,app_attest_counter,device_public_key,apns_token,session_hash,session_expires_at,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)`, recipientID, e.KeyID, e.AppAttestPublicKey, e.Receipt, newCounter, e.DevicePublicKey, e.PendingAPNSToken, Hash(session), sessionExpiry.Unix(), now.Unix(), now.Unix())
	if err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Store) AuthenticateDevice(ctx context.Context, token string, now time.Time) (Device, error) {
	var d Device
	err := s.db.QueryRowContext(ctx, "SELECT recipient_id,device_public_key,apns_token,session_expires_at,active FROM devices WHERE session_hash=?", Hash(token)).Scan(&d.RecipientID, &d.DevicePublicKey, &d.APNSToken, &d.SessionExpiresAt, &d.Active)
	if errors.Is(err, sql.ErrNoRows) {
		return d, ErrUnauthorized
	}
	if err != nil {
		return d, err
	}
	if !d.Active || d.SessionExpiresAt <= now.Unix() {
		return d, ErrUnauthorized
	}
	return d, nil
}
func (s *Store) ConsumeNonce(ctx context.Context, deviceID, nonce string, expires time.Time) error {
	_, err := s.db.ExecContext(ctx, "INSERT INTO device_nonces(device_id,nonce_hash,expires_at) VALUES(?,?,?)", deviceID, Hash(nonce), expires.Unix())
	if err != nil {
		return ErrConflict
	}
	return nil
}
func (s *Store) CreateGrant(ctx context.Context, g Grant, token string, now time.Time) error {
	_, err := s.db.ExecContext(ctx, "INSERT INTO grants(id,recipient_id,relay_origin,host_id,host_public_key,token_hash,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)", g.ID, g.RecipientID, g.RelayOrigin, g.HostID, g.HostPublicKey, Hash(token), now.Unix(), now.Unix())
	return err
}
func (s *Store) GrantByToken(ctx context.Context, token string) (Grant, error) {
	var g Grant
	var revoked sql.NullInt64
	var active bool
	err := s.db.QueryRowContext(ctx, `SELECT g.id,g.recipient_id,g.relay_origin,g.host_id,g.host_public_key,g.revoked_at,d.active FROM grants g JOIN devices d ON d.recipient_id=g.recipient_id WHERE g.token_hash=?`, Hash(token)).Scan(&g.ID, &g.RecipientID, &g.RelayOrigin, &g.HostID, &g.HostPublicKey, &revoked, &active)
	if errors.Is(err, sql.ErrNoRows) {
		return g, ErrUnauthorized
	}
	if err != nil {
		return g, err
	}
	if revoked.Valid || !active {
		return g, ErrUnauthorized
	}
	return g, nil
}
func (s *Store) RotateGrant(ctx context.Context, recipientID, grantID, token string, now time.Time) error {
	r, err := s.db.ExecContext(ctx, "UPDATE grants SET token_hash=?,updated_at=? WHERE id=? AND recipient_id=? AND revoked_at IS NULL", Hash(token), now.Unix(), grantID, recipientID)
	if err != nil {
		return err
	}
	if n, _ := r.RowsAffected(); n != 1 {
		return ErrNotFound
	}
	return nil
}
func (s *Store) RevokeGrant(ctx context.Context, recipientID, grantID string, now time.Time) error {
	r, err := s.db.ExecContext(ctx, "UPDATE grants SET revoked_at=?,updated_at=? WHERE id=? AND recipient_id=? AND revoked_at IS NULL", now.Unix(), now.Unix(), grantID, recipientID)
	if err != nil {
		return err
	}
	if n, _ := r.RowsAffected(); n != 1 {
		return ErrNotFound
	}
	return nil
}
func (s *Store) ConsumeEvent(ctx context.Context, grantID, eventID string, now time.Time) error {
	_, err := s.db.ExecContext(ctx, "INSERT INTO events(grant_id,event_id,created_at) VALUES(?,?,?)", grantID, eventID, now.Unix())
	if err != nil {
		return ErrConflict
	}
	return nil
}
func (s *Store) DeleteEvent(ctx context.Context, grantID, eventID string) error {
	_, err := s.db.ExecContext(ctx, "DELETE FROM events WHERE grant_id=? AND event_id=?", grantID, eventID)
	return err
}
func (s *Store) DeviceToken(ctx context.Context, recipientID string) (string, bool, error) {
	var token string
	var active bool
	err := s.db.QueryRowContext(ctx, "SELECT apns_token,active FROM devices WHERE recipient_id=?", recipientID).Scan(&token, &active)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, ErrNotFound
	}
	return token, active, err
}
func (s *Store) DisableDevice(ctx context.Context, recipientID string, now time.Time) error {
	_, err := s.db.ExecContext(ctx, "UPDATE devices SET active=0,updated_at=? WHERE recipient_id=?", now.Unix(), recipientID)
	return err
}
func (s *Store) CreateAPNSTokenChallenge(ctx context.Context, c APNSTokenChallenge) error {
	_, err := s.db.ExecContext(ctx, "INSERT INTO apns_token_challenges(id,recipient_id,pending_token,challenge,expires_at) VALUES(?,?,?,?,?)", c.ID, c.RecipientID, c.PendingToken, c.Challenge, c.ExpiresAt)
	return err
}
func (s *Store) DeleteAPNSTokenChallenge(ctx context.Context, recipientID, id string) error {
	_, err := s.db.ExecContext(ctx, "DELETE FROM apns_token_challenges WHERE id=? AND recipient_id=?", id, recipientID)
	return err
}
func (s *Store) ConfirmAPNSToken(ctx context.Context, recipientID, challengeID string, challenge []byte, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var pending string
	var stored []byte
	var expiry int64
	var consumed sql.NullInt64
	err = tx.QueryRowContext(ctx, "SELECT pending_token,challenge,expires_at,consumed_at FROM apns_token_challenges WHERE id=? AND recipient_id=?", challengeID, recipientID).Scan(&pending, &stored, &expiry, &consumed)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if consumed.Valid || expiry <= now.Unix() || !bytes.Equal(stored, challenge) {
		return ErrUnauthorized
	}
	if _, err = tx.ExecContext(ctx, "UPDATE apns_token_challenges SET consumed_at=? WHERE id=?", now.Unix(), challengeID); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE devices SET apns_token=?,active=1,updated_at=? WHERE recipient_id=?", pending, now.Unix(), recipientID); err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Store) Prune(ctx context.Context, now time.Time) error {
	_, err := s.db.ExecContext(ctx, "DELETE FROM device_nonces WHERE expires_at<=?; DELETE FROM enrollments WHERE expires_at<=? AND activated_at IS NULL; DELETE FROM apns_token_challenges WHERE expires_at<=? OR consumed_at IS NOT NULL; DELETE FROM events WHERE created_at<=?;", now.Unix(), now.Unix(), now.Unix(), now.Add(-30*24*time.Hour).Unix())
	return err
}
func Wrap(op string, err error) error { return fmt.Errorf("%s: %w", op, err) }
