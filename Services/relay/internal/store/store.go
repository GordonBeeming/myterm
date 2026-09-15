package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
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

var (
	ErrNotFound     = errors.New("not found")
	ErrConflict     = errors.New("conflict")
	ErrExpired      = errors.New("expired")
	ErrConsumed     = errors.New("already consumed")
	ErrUnauthorized = errors.New("unauthorized")
	ErrOwnerExists  = errors.New("owner already exists")
	ErrOwnerMissing = errors.New("owner is not registered")
)

type Store struct {
	db *sql.DB
}

type Owner struct {
	ID          string
	WebAuthnID  []byte
	Name        string
	DisplayName string
}

type CredentialRecord struct {
	ID   []byte
	JSON []byte
}

type OAuthContext struct {
	RedirectURI   string `json:"redirect_uri"`
	State         string `json:"state"`
	CodeChallenge string `json:"code_challenge"`
	DeviceName    string `json:"device_name"`
	DeviceKind    string `json:"device_kind"`
	BootstrapHash []byte `json:"bootstrap_hash,omitempty"`
	OwnerID       string `json:"owner_id,omitempty"`
	WebAuthnID    []byte `json:"webauthn_id,omitempty"`
	OwnerName     string `json:"owner_name,omitempty"`
	DisplayName   string `json:"display_name,omitempty"`
	Purpose       string `json:"purpose,omitempty"`
}

type Ceremony struct {
	Kind        string
	SessionJSON []byte
	OAuth       OAuthContext
}

type Device struct {
	ID              string `json:"id"`
	OwnerID         string `json:"-"`
	Kind            string `json:"kind"`
	Name            string `json:"name"`
	AccessExpiresAt int64  `json:"-"`
}
type DeviceSummary struct {
	ID        string `json:"device_id"`
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	CreatedAt int64  `json:"created_at"`
	RevokedAt *int64 `json:"revoked_at,omitempty"`
}

type Host struct {
	ID        string `json:"id"`
	OwnerID   string `json:"-"`
	DeviceID  string `json:"device_id"`
	Name      string `json:"name"`
	PublicKey string `json:"public_key"`
	Online    bool   `json:"online"`
}

type PairingTicket struct {
	TicketID          string `json:"ticket_id"`
	HostID            string `json:"host_id"`
	HostName          string `json:"host_name"`
	HostPublicKey     string `json:"host_public_key"`
	EncryptedEnvelope string `json:"encrypted_envelope"`
	ExpiresAt         int64  `json:"expires_at"`
}

func Open(ctx context.Context, path string) (*Store, error) {
	if path != ":memory:" && !strings.HasPrefix(path, "file:") {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return nil, fmt.Errorf("create database directory: %w", err)
		}
	}
	dsn := path
	if path == ":memory:" {
		dsn = "file:myterm-relay?mode=memory&cache=shared"
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1)
	if _, err := db.ExecContext(ctx, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;"); err != nil {
		db.Close()
		return nil, fmt.Errorf("configure sqlite: %w", err)
	}
	if _, err := db.ExecContext(ctx, migrations); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate sqlite: %w", err)
	}
	if path != ":memory:" && !strings.HasPrefix(path, "file:") {
		if err := os.Chmod(path, 0o600); err != nil {
			db.Close()
			return nil, fmt.Errorf("protect sqlite database: %w", err)
		}
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) PruneExpired(ctx context.Context, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	statements := []string{
		"DELETE FROM ceremonies WHERE expires_at<=?",
		"DELETE FROM auth_codes WHERE expires_at<=?",
		"DELETE FROM access_tokens WHERE expires_at<=?",
		"DELETE FROM bootstrap_tokens WHERE expires_at<=? OR consumed_at IS NOT NULL",
		"DELETE FROM pairing_tickets WHERE expires_at<=? OR consumed_at IS NOT NULL",
		"DELETE FROM owner_enrollment_tokens WHERE expires_at<=? OR consumed_at IS NOT NULL",
		"DELETE FROM used_refresh_tokens WHERE expires_at<=?",
		"DELETE FROM used_auth_codes WHERE expires_at<=?",
		"DELETE FROM revoked_device_ids WHERE expires_at<=?",
	}
	for _, statement := range statements {
		if _, err := tx.ExecContext(ctx, statement, now.Unix()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func NewToken(bytes int) (string, error) {
	raw := make([]byte, bytes)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("read secure random: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func NewID() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("read secure random: %w", err)
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	encoded := hex.EncodeToString(raw)
	return encoded[:8] + "-" + encoded[8:12] + "-" + encoded[12:16] + "-" + encoded[16:20] + "-" + encoded[20:], nil
}

func HashToken(token string) []byte {
	hash := sha256.Sum256([]byte(token))
	return hash[:]
}

func (s *Store) CreateBootstrapToken(ctx context.Context, token string, expiresAt time.Time) error {
	var ownerCount int
	if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM owners").Scan(&ownerCount); err != nil {
		return err
	}
	if ownerCount != 0 {
		return ErrOwnerExists
	}
	_, err := s.db.ExecContext(ctx, "INSERT INTO bootstrap_tokens(token_hash, expires_at) VALUES (?, ?)", HashToken(token), expiresAt.Unix())
	return err
}

func (s *Store) ConsumeBootstrapToken(ctx context.Context, tx *sql.Tx, token string, now time.Time) error {
	return s.consumeBootstrapHash(ctx, tx, HashToken(token), now)
}

func (s *Store) consumeBootstrapHash(ctx context.Context, tx *sql.Tx, hash []byte, now time.Time) error {
	result, err := tx.ExecContext(ctx, "UPDATE bootstrap_tokens SET consumed_at=? WHERE token_hash=? AND consumed_at IS NULL AND expires_at>?", now.Unix(), hash, now.Unix())
	if err != nil {
		return err
	}
	if affected, _ := result.RowsAffected(); affected != 1 {
		return ErrUnauthorized
	}
	return nil
}

func (s *Store) ValidateBootstrapToken(ctx context.Context, token string, now time.Time) error {
	var expires int64
	var consumed sql.NullInt64
	err := s.db.QueryRowContext(ctx, "SELECT expires_at, consumed_at FROM bootstrap_tokens WHERE token_hash=?", HashToken(token)).Scan(&expires, &consumed)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrUnauthorized
	}
	if err != nil {
		return err
	}
	if consumed.Valid || expires <= now.Unix() {
		return ErrUnauthorized
	}
	return nil
}

func (s *Store) CreateOwnerEnrollmentToken(ctx context.Context, token, purpose string, expires time.Time) error {
	if purpose != "add" && purpose != "recover" {
		return ErrUnauthorized
	}
	owner, err := s.Owner(ctx)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, "INSERT INTO owner_enrollment_tokens(token_hash,owner_id,purpose,expires_at) VALUES(?,?,?,?)", HashToken(token), owner.ID, purpose, expires.Unix())
	return err
}
func (s *Store) OwnerEnrollmentPurpose(ctx context.Context, token string, now time.Time) (string, error) {
	var purpose string
	var expires int64
	var consumed sql.NullInt64
	err := s.db.QueryRowContext(ctx, "SELECT purpose,expires_at,consumed_at FROM owner_enrollment_tokens WHERE token_hash=?", HashToken(token)).Scan(&purpose, &expires, &consumed)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrUnauthorized
	}
	if err != nil {
		return "", err
	}
	if consumed.Valid || expires <= now.Unix() {
		return "", ErrUnauthorized
	}
	return purpose, nil
}

func (s *Store) AddOrRecoverCredential(ctx context.Context, ownerID, purpose string, credential CredentialRecord, tokenHash []byte, now time.Time) ([]string, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, "UPDATE owner_enrollment_tokens SET consumed_at=? WHERE token_hash=? AND owner_id=? AND purpose=? AND consumed_at IS NULL AND expires_at>?", now.Unix(), tokenHash, ownerID, purpose, now.Unix())
	if err != nil {
		return nil, err
	}
	affected, err := result.RowsAffected()
	if err != nil || affected != 1 {
		if err != nil {
			return nil, err
		}
		return nil, ErrUnauthorized
	}
	var revoked []string
	if purpose == "recover" {
		rows, err := tx.QueryContext(ctx, "SELECT id FROM devices WHERE owner_id=? AND revoked_at IS NULL", ownerID)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return nil, err
			}
			revoked = append(revoked, id)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return nil, err
		}
		if err := rows.Close(); err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM credentials WHERE owner_id=?", ownerID); err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, "UPDATE devices SET revoked_at=?,updated_at=? WHERE owner_id=? AND revoked_at IS NULL", now.Unix(), now.Unix(), ownerID); err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM access_tokens WHERE device_id IN (SELECT id FROM devices WHERE owner_id=?)", ownerID); err != nil {
			return nil, err
		}
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO credentials(credential_id,owner_id,credential_json,created_at,updated_at) VALUES(?,?,?,?,?)", credential.ID, ownerID, credential.JSON, now.Unix(), now.Unix()); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return revoked, nil
}

func (s *Store) Owner(ctx context.Context) (Owner, error) {
	var owner Owner
	err := s.db.QueryRowContext(ctx, "SELECT id, webauthn_id, name, display_name FROM owners LIMIT 1").Scan(&owner.ID, &owner.WebAuthnID, &owner.Name, &owner.DisplayName)
	if errors.Is(err, sql.ErrNoRows) {
		return Owner{}, ErrOwnerMissing
	}
	return owner, err
}

func (s *Store) OwnerWithCredentials(ctx context.Context) (Owner, []CredentialRecord, error) {
	owner, err := s.Owner(ctx)
	if err != nil {
		return Owner{}, nil, err
	}
	rows, err := s.db.QueryContext(ctx, "SELECT credential_id, credential_json FROM credentials WHERE owner_id=?", owner.ID)
	if err != nil {
		return Owner{}, nil, err
	}
	defer rows.Close()
	var credentials []CredentialRecord
	for rows.Next() {
		var credential CredentialRecord
		if err := rows.Scan(&credential.ID, &credential.JSON); err != nil {
			return Owner{}, nil, err
		}
		credentials = append(credentials, credential)
	}
	return owner, credentials, rows.Err()
}

func (s *Store) CreateOwnerCredential(ctx context.Context, owner Owner, credential CredentialRecord, bootstrapToken string, now time.Time) error {
	return s.CreateOwnerCredentialHash(ctx, owner, credential, HashToken(bootstrapToken), now)
}

func (s *Store) CreateOwnerCredentialHash(ctx context.Context, owner Owner, credential CredentialRecord, bootstrapHash []byte, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var count int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM owners").Scan(&count); err != nil {
		return err
	}
	if count != 0 {
		return ErrOwnerExists
	}
	if err := s.consumeBootstrapHash(ctx, tx, bootstrapHash, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO owners(id, webauthn_id, name, display_name, created_at) VALUES (?, ?, ?, ?, ?)", owner.ID, owner.WebAuthnID, owner.Name, owner.DisplayName, now.Unix()); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO credentials(credential_id, owner_id, credential_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?)", credential.ID, owner.ID, credential.JSON, now.Unix(), now.Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) UpdateCredential(ctx context.Context, ownerID string, credential CredentialRecord, now time.Time) error {
	result, err := s.db.ExecContext(ctx, "UPDATE credentials SET credential_json=?, updated_at=? WHERE credential_id=? AND owner_id=?", credential.JSON, now.Unix(), credential.ID, ownerID)
	if err != nil {
		return err
	}
	if affected, _ := result.RowsAffected(); affected != 1 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) SaveCeremony(ctx context.Context, id string, ceremony Ceremony, expiresAt time.Time) error {
	oauthJSON, err := json.Marshal(ceremony.OAuth)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, "INSERT INTO ceremonies(id_hash, kind, session_json, oauth_json, expires_at) VALUES (?, ?, ?, ?, ?)", HashToken(id), ceremony.Kind, ceremony.SessionJSON, oauthJSON, expiresAt.Unix())
	return err
}

func (s *Store) TakeCeremony(ctx context.Context, id, kind string, now time.Time) (Ceremony, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Ceremony{}, err
	}
	defer tx.Rollback()
	var ceremony Ceremony
	var oauthJSON []byte
	var expires int64
	err = tx.QueryRowContext(ctx, "SELECT kind, session_json, oauth_json, expires_at FROM ceremonies WHERE id_hash=?", HashToken(id)).Scan(&ceremony.Kind, &ceremony.SessionJSON, &oauthJSON, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return Ceremony{}, ErrNotFound
	}
	if err != nil {
		return Ceremony{}, err
	}
	if ceremony.Kind != kind {
		return Ceremony{}, ErrUnauthorized
	}
	if expires <= now.Unix() {
		return Ceremony{}, ErrExpired
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM ceremonies WHERE id_hash=?", HashToken(id)); err != nil {
		return Ceremony{}, err
	}
	if err := json.Unmarshal(oauthJSON, &ceremony.OAuth); err != nil {
		return Ceremony{}, err
	}
	if err := tx.Commit(); err != nil {
		return Ceremony{}, err
	}
	return ceremony, nil
}

func (s *Store) SaveAuthCode(ctx context.Context, code, ownerID string, oauth OAuthContext, expiresAt time.Time) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO auth_codes(code_hash, owner_id, redirect_uri, code_challenge, device_name, device_kind, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, HashToken(code), ownerID, oauth.RedirectURI, oauth.CodeChallenge, oauth.DeviceName, oauth.DeviceKind, expiresAt.Unix())
	return err
}

func (s *Store) ExchangeAuthCode(ctx context.Context, code, redirectURI, challenge string, now time.Time) (Device, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Device{}, err
	}
	defer tx.Rollback()
	var device Device
	var storedRedirect, storedChallenge string
	var expires int64
	var consumed sql.NullInt64
	err = tx.QueryRowContext(ctx, "SELECT owner_id, redirect_uri, code_challenge, device_name, device_kind, expires_at, consumed_at FROM auth_codes WHERE code_hash=?", HashToken(code)).Scan(&device.OwnerID, &storedRedirect, &storedChallenge, &device.Name, &device.Kind, &expires, &consumed)
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, ErrUnauthorized
	}
	if err != nil {
		return Device{}, err
	}
	if storedRedirect != redirectURI || storedChallenge != challenge {
		return Device{}, ErrUnauthorized
	}
	if consumed.Valid {
		var replayedDeviceID string
		historyErr := tx.QueryRowContext(ctx, "SELECT device_id FROM used_auth_codes WHERE code_hash=?", HashToken(code)).Scan(&replayedDeviceID)
		if errors.Is(historyErr, sql.ErrNoRows) {
			return Device{}, ErrConsumed
		}
		if historyErr != nil {
			return Device{}, historyErr
		}
		if _, historyErr = tx.ExecContext(ctx, "UPDATE devices SET revoked_at=?,updated_at=? WHERE id=? AND revoked_at IS NULL", now.Unix(), now.Unix(), replayedDeviceID); historyErr != nil {
			return Device{}, historyErr
		}
		if _, historyErr = tx.ExecContext(ctx, "DELETE FROM access_tokens WHERE device_id=?", replayedDeviceID); historyErr != nil {
			return Device{}, historyErr
		}
		markerExpiry:=expires;if markerExpiry<=now.Unix(){markerExpiry=now.Add(5*time.Minute).Unix()}
		if _, historyErr = tx.ExecContext(ctx, "INSERT OR IGNORE INTO revoked_device_ids(device_id,expires_at) VALUES(?,?)", replayedDeviceID, markerExpiry); historyErr != nil {
			return Device{}, historyErr
		}
		if historyErr = tx.Commit(); historyErr != nil {
			return Device{}, historyErr
		}
		return Device{ID: replayedDeviceID}, ErrConsumed
	}
	if expires <= now.Unix() {
		return Device{}, ErrExpired
	}
	if _, err := tx.ExecContext(ctx, "UPDATE auth_codes SET consumed_at=? WHERE code_hash=? AND consumed_at IS NULL", now.Unix(), HashToken(code)); err != nil {
		return Device{}, err
	}
	device.ID, err = NewID()
	if err != nil {
		return Device{}, err
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO used_auth_codes(code_hash,device_id,expires_at) VALUES(?,?,?)", HashToken(code), device.ID, expires); err != nil {
		return Device{}, err
	}
	if err := tx.Commit(); err != nil {
		return Device{}, err
	}
	return device, nil
}

func (s *Store) CreateDeviceTokens(ctx context.Context, device Device, access, refresh string, accessExpiry, refreshExpiry, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var revokedMarker int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM revoked_device_ids WHERE device_id=? AND expires_at>?", device.ID, now.Unix()).Scan(&revokedMarker); err != nil {
		return err
	}
	if revokedMarker != 0 {
		return ErrUnauthorized
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO devices(id, owner_id, kind, name, refresh_hash, refresh_expires_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", device.ID, device.OwnerID, device.Kind, device.Name, HashToken(refresh), refreshExpiry.Unix(), now.Unix(), now.Unix()); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO access_tokens(token_hash, device_id, expires_at, created_at) VALUES (?, ?, ?, ?)", HashToken(access), device.ID, accessExpiry.Unix(), now.Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) AuthenticateAccess(ctx context.Context, access string, now time.Time) (Device, error) {
	var device Device
	var revoked sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT d.id, d.owner_id, d.kind, d.name, a.expires_at, d.revoked_at
		FROM access_tokens a JOIN devices d ON d.id=a.device_id WHERE a.token_hash=?`, HashToken(access)).Scan(&device.ID, &device.OwnerID, &device.Kind, &device.Name, &device.AccessExpiresAt, &revoked)
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, ErrUnauthorized
	}
	if err != nil {
		return Device{}, err
	}
	if revoked.Valid || device.AccessExpiresAt <= now.Unix() {
		return Device{}, ErrUnauthorized
	}
	return device, nil
}

func (s *Store) RotateRefresh(ctx context.Context, oldRefresh, newRefresh, access string, accessExpiry, refreshExpiry, now time.Time) (Device, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Device{}, err
	}
	defer tx.Rollback()
	var device Device
	var expires int64
	var revoked sql.NullInt64
	err = tx.QueryRowContext(ctx, "SELECT id, owner_id, kind, name, refresh_expires_at, revoked_at FROM devices WHERE refresh_hash=?", HashToken(oldRefresh)).Scan(&device.ID, &device.OwnerID, &device.Kind, &device.Name, &expires, &revoked)
	if errors.Is(err, sql.ErrNoRows) {
		var replayedDeviceID string
		historyErr := tx.QueryRowContext(ctx, "SELECT device_id FROM used_refresh_tokens WHERE token_hash=? AND expires_at>?", HashToken(oldRefresh), now.Unix()).Scan(&replayedDeviceID)
		if errors.Is(historyErr, sql.ErrNoRows) {
			return Device{}, ErrUnauthorized
		}
		if historyErr != nil {
			return Device{}, historyErr
		}
		if _, historyErr = tx.ExecContext(ctx, "UPDATE devices SET revoked_at=?,updated_at=? WHERE id=? AND revoked_at IS NULL", now.Unix(), now.Unix(), replayedDeviceID); historyErr != nil {
			return Device{}, historyErr
		}
		if _, historyErr = tx.ExecContext(ctx, "DELETE FROM access_tokens WHERE device_id=?", replayedDeviceID); historyErr != nil {
			return Device{}, historyErr
		}
		if historyErr = tx.Commit(); historyErr != nil {
			return Device{}, historyErr
		}
		return Device{ID: replayedDeviceID}, ErrUnauthorized
	}
	if err != nil {
		return Device{}, err
	}
	if revoked.Valid || expires <= now.Unix() {
		return Device{}, ErrUnauthorized
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO used_refresh_tokens(token_hash,device_id,expires_at) VALUES(?,?,?)", HashToken(oldRefresh), device.ID, expires); err != nil {
		return Device{}, err
	}
	result, err := tx.ExecContext(ctx, "UPDATE devices SET refresh_hash=?, refresh_expires_at=?, updated_at=? WHERE id=? AND refresh_hash=?", HashToken(newRefresh), refreshExpiry.Unix(), now.Unix(), device.ID, HashToken(oldRefresh))
	if err != nil {
		return Device{}, err
	}
	if affected, _ := result.RowsAffected(); affected != 1 {
		return Device{}, ErrUnauthorized
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM access_tokens WHERE device_id=?", device.ID); err != nil {
		return Device{}, err
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO access_tokens(token_hash, device_id, expires_at, created_at) VALUES (?, ?, ?, ?)", HashToken(access), device.ID, accessExpiry.Unix(), now.Unix()); err != nil {
		return Device{}, err
	}
	if err := tx.Commit(); err != nil {
		return Device{}, err
	}
	return device, nil
}

func (s *Store) RevokeToken(ctx context.Context, token string, now time.Time) (string, error) {
	hash := HashToken(token)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var deviceID string
	err = tx.QueryRowContext(ctx, `SELECT id FROM devices WHERE id=(
		SELECT device_id FROM access_tokens WHERE token_hash=?) OR refresh_hash=? LIMIT 1`, hash, hash).Scan(&deviceID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if _, err := tx.ExecContext(ctx, "UPDATE devices SET revoked_at=?, updated_at=? WHERE id=?", now.Unix(), now.Unix(), deviceID); err != nil {
		return "", err
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return deviceID, nil
}

func (s *Store) ListDevices(ctx context.Context, ownerID string) ([]DeviceSummary, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id,kind,name,created_at,revoked_at FROM devices WHERE owner_id=? ORDER BY created_at,id", ownerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []DeviceSummary
	for rows.Next() {
		var d DeviceSummary
		var revoked sql.NullInt64
		if err := rows.Scan(&d.ID, &d.Kind, &d.Name, &d.CreatedAt, &revoked); err != nil {
			return nil, err
		}
		if revoked.Valid {
			value := revoked.Int64
			d.RevokedAt = &value
		}
		result = append(result, d)
	}
	return result, rows.Err()
}
func (s *Store) RevokeDevice(ctx context.Context, ownerID, deviceID string, now time.Time) error {
	result, err := s.db.ExecContext(ctx, "UPDATE devices SET revoked_at=?,updated_at=? WHERE id=? AND owner_id=? AND revoked_at IS NULL", now.Unix(), now.Unix(), deviceID, ownerID)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected != 1 {
		return ErrNotFound
	}
	if _, err := s.db.ExecContext(ctx, "DELETE FROM access_tokens WHERE device_id=?", deviceID); err != nil {
		return err
	}
	return nil
}

func (s *Store) ListHosts(ctx context.Context, ownerID string) ([]Host, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id, owner_id, device_id, name, public_key FROM hosts WHERE owner_id=? ORDER BY name, id", ownerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var hosts []Host
	for rows.Next() {
		var host Host
		var key []byte
		if err := rows.Scan(&host.ID, &host.OwnerID, &host.DeviceID, &host.Name, &key); err != nil {
			return nil, err
		}
		host.PublicKey = base64.RawURLEncoding.EncodeToString(key)
		hosts = append(hosts, host)
	}
	return hosts, rows.Err()
}

func (s *Store) UpsertHost(ctx context.Context, host Host, publicKey []byte, now time.Time) (Host, error) {
	result, err := s.db.ExecContext(ctx, `INSERT INTO hosts(id, owner_id, device_id, name, public_key, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET device_id=excluded.device_id, name=excluded.name, public_key=excluded.public_key, updated_at=excluded.updated_at
		WHERE hosts.owner_id=excluded.owner_id`, host.ID, host.OwnerID, host.DeviceID, host.Name, publicKey, now.Unix(), now.Unix())
	if err != nil {
		return Host{}, err
	}
	if affected, _ := result.RowsAffected(); affected != 1 {
		return Host{}, ErrConflict
	}
	host.PublicKey = base64.RawURLEncoding.EncodeToString(publicKey)
	return host, nil
}

func (s *Store) HostForDevice(ctx context.Context, ownerID, hostID, deviceID string) (Host, error) {
	var host Host
	var key []byte
	err := s.db.QueryRowContext(ctx, "SELECT id, owner_id, device_id, name, public_key FROM hosts WHERE id=? AND owner_id=? AND device_id=?", hostID, ownerID, deviceID).Scan(&host.ID, &host.OwnerID, &host.DeviceID, &host.Name, &key)
	if errors.Is(err, sql.ErrNoRows) {
		return Host{}, ErrNotFound
	}
	host.PublicKey = base64.RawURLEncoding.EncodeToString(key)
	return host, err
}

func (s *Store) HostForOwner(ctx context.Context, ownerID, hostID string) (Host, error) {
	var host Host
	var key []byte
	err := s.db.QueryRowContext(ctx, "SELECT id, owner_id, device_id, name, public_key FROM hosts WHERE id=? AND owner_id=?", hostID, ownerID).Scan(&host.ID, &host.OwnerID, &host.DeviceID, &host.Name, &key)
	if errors.Is(err, sql.ErrNoRows) {
		return Host{}, ErrNotFound
	}
	host.PublicKey = base64.RawURLEncoding.EncodeToString(key)
	return host, err
}

func (s *Store) DeleteHost(ctx context.Context, ownerID, hostID string) error {
	result, err := s.db.ExecContext(ctx, "DELETE FROM hosts WHERE id=? AND owner_id=?", hostID, ownerID)
	if err != nil {
		return err
	}
	if affected, _ := result.RowsAffected(); affected != 1 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) CreatePairingTicket(ctx context.Context, ownerID, hostID, ticketID string, envelope []byte, expiresAt, now time.Time) error {
	_, err := s.db.ExecContext(ctx, "INSERT INTO pairing_tickets(ticket_id, owner_id, host_id, encrypted_envelope, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?)", ticketID, ownerID, hostID, envelope, expiresAt.Unix(), now.Unix())
	if err != nil {
		var count int
		if lookupErr := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM pairing_tickets WHERE ticket_id=?", ticketID).Scan(&count); lookupErr == nil && count != 0 {
			return ErrConflict
		}
	}
	return err
}

func (s *Store) TakePairingTicket(ctx context.Context, ownerID, ticketID string, now time.Time) (PairingTicket, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return PairingTicket{}, err
	}
	defer tx.Rollback()
	var ticket PairingTicket
	var envelope, key []byte
	var consumed sql.NullInt64
	err = tx.QueryRowContext(ctx, `SELECT p.ticket_id, p.host_id, h.name, h.public_key, p.encrypted_envelope, p.expires_at, p.consumed_at
		FROM pairing_tickets p JOIN hosts h ON h.id=p.host_id WHERE p.ticket_id=? AND p.owner_id=?`, ticketID, ownerID).Scan(&ticket.TicketID, &ticket.HostID, &ticket.HostName, &key, &envelope, &ticket.ExpiresAt, &consumed)
	if errors.Is(err, sql.ErrNoRows) {
		return PairingTicket{}, ErrNotFound
	}
	if err != nil {
		return PairingTicket{}, err
	}
	if consumed.Valid {
		return PairingTicket{}, ErrConsumed
	}
	if ticket.ExpiresAt <= now.Unix() {
		return PairingTicket{}, ErrExpired
	}
	result, err := tx.ExecContext(ctx, "UPDATE pairing_tickets SET consumed_at=?, encrypted_envelope=X'' WHERE ticket_id=? AND consumed_at IS NULL", now.Unix(), ticketID)
	if err != nil {
		return PairingTicket{}, err
	}
	if affected, _ := result.RowsAffected(); affected != 1 {
		return PairingTicket{}, ErrConsumed
	}
	ticket.HostPublicKey = base64.RawURLEncoding.EncodeToString(key)
	ticket.EncryptedEnvelope = base64.RawURLEncoding.EncodeToString(envelope)
	if err := tx.Commit(); err != nil {
		return PairingTicket{}, err
	}
	return ticket, nil
}
