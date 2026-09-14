package auth

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/gordonbeeming/myterm/relay/internal/config"
	"github.com/gordonbeeming/myterm/relay/internal/store"
)

var AllowedRedirects = map[string]struct{}{
	"myterm-companion://auth/callback":     {},
	"myterm://companion-auth/callback":     {},
	"myterm-dev://companion-auth/callback": {},
}

type Manager struct {
	webAuthn *webauthn.WebAuthn
	store    *store.Store
	config   config.Config
	now      func() time.Time
}

type User struct {
	owner       store.Owner
	credentials []webauthn.Credential
}
type RegistrationResult struct {
	Code             string
	State            string
	RevokedDeviceIDs []string
}

func (u User) WebAuthnID() []byte                         { return u.owner.WebAuthnID }
func (u User) WebAuthnName() string                       { return u.owner.Name }
func (u User) WebAuthnDisplayName() string                { return u.owner.DisplayName }
func (u User) WebAuthnCredentials() []webauthn.Credential { return u.credentials }

func New(cfg config.Config, storage *store.Store) (*Manager, error) {
	wa, err := webauthn.New(&webauthn.Config{
		RPID:                  cfg.RPID,
		RPDisplayName:         cfg.RPDisplayName,
		RPOrigins:             []string{cfg.PublicURL.String()},
		AttestationPreference: protocol.PreferNoAttestation,
		AuthenticatorSelection: protocol.AuthenticatorSelection{
			ResidentKey:      protocol.ResidentKeyRequirementPreferred,
			UserVerification: protocol.VerificationRequired,
		},
	})
	if err != nil {
		return nil, fmt.Errorf("configure WebAuthn: %w", err)
	}
	return &Manager{webAuthn: wa, store: storage, config: cfg, now: time.Now}, nil
}

func ValidateOAuthContext(values url.Values) (store.OAuthContext, error) {
	ctx := store.OAuthContext{
		RedirectURI:   strings.TrimSpace(values.Get("redirect_uri")),
		State:         strings.TrimSpace(values.Get("state")),
		CodeChallenge: strings.TrimSpace(values.Get("code_challenge")),
		DeviceName:    strings.TrimSpace(values.Get("device_name")),
		DeviceKind:    strings.TrimSpace(values.Get("device_kind")),
	}
	if _, ok := AllowedRedirects[ctx.RedirectURI]; !ok {
		return store.OAuthContext{}, errors.New("redirect_uri is not allowed")
	}
	stateBytes, err := base64.RawURLEncoding.DecodeString(ctx.State)
	if err != nil || len(stateBytes) < 32 || len(stateBytes) > 64 {
		return store.OAuthContext{}, errors.New("state must be 32 through 64 random bytes encoded as unpadded base64url")
	}
	if values.Get("code_challenge_method") != "S256" {
		return store.OAuthContext{}, errors.New("code_challenge_method must be S256")
	}
	challengeBytes, err := base64.RawURLEncoding.DecodeString(ctx.CodeChallenge)
	if err != nil || len(challengeBytes) != 32 {
		return store.OAuthContext{}, errors.New("code_challenge must be a base64url SHA-256 digest")
	}
	if len(ctx.DeviceName) < 1 || len(ctx.DeviceName) > 100 {
		return store.OAuthContext{}, errors.New("device_name must contain 1 through 100 characters")
	}
	if ctx.DeviceKind != "host" && ctx.DeviceKind != "client" {
		return store.OAuthContext{}, errors.New("device_kind must be host or client")
	}
	return ctx, nil
}

func (m *Manager) BeginRegistration(ctx context.Context, oauth store.OAuthContext, bootstrapToken, ownerName, displayName string) (any, string, error) {
	now := m.now()
	var user User
	if err := m.store.ValidateBootstrapToken(ctx, bootstrapToken, now); err == nil {
		if _, err := m.store.Owner(ctx); err == nil {
			return nil, "", store.ErrOwnerExists
		} else if !errors.Is(err, store.ErrOwnerMissing) {
			return nil, "", err
		}
		ownerName = strings.TrimSpace(ownerName)
		displayName = strings.TrimSpace(displayName)
		if len(ownerName) < 1 || len(ownerName) > 100 || len(displayName) < 1 || len(displayName) > 100 {
			return nil, "", errors.New("owner_name and display_name must contain 1 through 100 characters")
		}
		ownerID, err := store.NewID()
		if err != nil {
			return nil, "", err
		}
		userHandle, err := store.NewToken(48)
		if err != nil {
			return nil, "", err
		}
		oauth.Purpose = "initial"
		oauth.OwnerID = ownerID
		oauth.WebAuthnID = []byte(userHandle)
		oauth.OwnerName = ownerName
		oauth.DisplayName = displayName
		user = User{owner: store.Owner{ID: ownerID, WebAuthnID: oauth.WebAuthnID, Name: ownerName, DisplayName: displayName}}
	} else {
		purpose, purposeErr := m.store.OwnerEnrollmentPurpose(ctx, bootstrapToken, now)
		if purposeErr != nil {
			return nil, "", purposeErr
		}
		oauth.Purpose = purpose
		var loadErr error
		user, loadErr = m.loadUser(ctx)
		if loadErr != nil {
			return nil, "", loadErr
		}
		oauth.OwnerID = user.owner.ID
		oauth.WebAuthnID = user.owner.WebAuthnID
		oauth.OwnerName = user.owner.Name
		oauth.DisplayName = user.owner.DisplayName
	}
	oauth.BootstrapHash = store.HashToken(bootstrapToken)
	descriptors := make([]protocol.CredentialDescriptor, 0, len(user.credentials))
	for _, credential := range user.credentials {
		descriptors = append(descriptors, protocol.CredentialDescriptor{Type: protocol.PublicKeyCredentialType, CredentialID: credential.ID})
	}
	creation, session, err := m.webAuthn.BeginRegistration(user, webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementPreferred), webauthn.WithExclusions(descriptors))
	if err != nil {
		return nil, "", err
	}
	sessionJSON, err := json.Marshal(session)
	if err != nil {
		return nil, "", err
	}
	ceremonyID, err := store.NewToken(32)
	if err != nil {
		return nil, "", err
	}
	if err := m.store.SaveCeremony(ctx, ceremonyID, store.Ceremony{Kind: "register", SessionJSON: sessionJSON, OAuth: oauth}, now.Add(m.config.CeremonyTTL)); err != nil {
		return nil, "", err
	}
	return creation, ceremonyID, nil
}

func (m *Manager) FinishRegistration(ctx context.Context, ceremonyID string, request *http.Request) (RegistrationResult, error) {
	now := m.now()
	ceremony, err := m.store.TakeCeremony(ctx, ceremonyID, "register", now)
	if err != nil {
		return RegistrationResult{}, err
	}
	var session webauthn.SessionData
	if err := json.Unmarshal(ceremony.SessionJSON, &session); err != nil {
		return RegistrationResult{}, err
	}
	user := User{owner: store.Owner{ID: ceremony.OAuth.OwnerID, WebAuthnID: ceremony.OAuth.WebAuthnID, Name: ceremony.OAuth.OwnerName, DisplayName: ceremony.OAuth.DisplayName}}
	credential, err := m.webAuthn.FinishRegistration(user, session, request)
	if err != nil {
		return RegistrationResult{}, fmt.Errorf("verify registration: %w", err)
	}
	credentialJSON, err := json.Marshal(credential)
	if err != nil {
		return RegistrationResult{}, err
	}
	owner := user.owner
	var revoked []string
	if ceremony.OAuth.Purpose == "initial" {
		if err := m.store.CreateOwnerCredentialHash(ctx, owner, store.CredentialRecord{ID: credential.ID, JSON: credentialJSON}, ceremony.OAuth.BootstrapHash, now); err != nil {
			return RegistrationResult{}, err
		}
	} else {
		revoked, err = m.store.AddOrRecoverCredential(ctx, owner.ID, ceremony.OAuth.Purpose, store.CredentialRecord{ID: credential.ID, JSON: credentialJSON}, ceremony.OAuth.BootstrapHash, now)
		if err != nil {
			return RegistrationResult{}, err
		}
	}
	code, err := m.issueAuthCode(ctx, owner.ID, ceremony.OAuth, now)
	return RegistrationResult{Code: code, State: ceremony.OAuth.State, RevokedDeviceIDs: revoked}, err
}

func (m *Manager) BeginLogin(ctx context.Context, oauth store.OAuthContext) (any, string, error) {
	user, err := m.loadUser(ctx)
	if err != nil {
		return nil, "", err
	}
	assertion, session, err := m.webAuthn.BeginLogin(user, webauthn.WithUserVerification(protocol.VerificationRequired))
	if err != nil {
		return nil, "", err
	}
	sessionJSON, err := json.Marshal(session)
	if err != nil {
		return nil, "", err
	}
	ceremonyID, err := store.NewToken(32)
	if err != nil {
		return nil, "", err
	}
	if err := m.store.SaveCeremony(ctx, ceremonyID, store.Ceremony{Kind: "login", SessionJSON: sessionJSON, OAuth: oauth}, m.now().Add(m.config.CeremonyTTL)); err != nil {
		return nil, "", err
	}
	return assertion, ceremonyID, nil
}

func (m *Manager) FinishLogin(ctx context.Context, ceremonyID string, request *http.Request) (string, string, error) {
	now := m.now()
	ceremony, err := m.store.TakeCeremony(ctx, ceremonyID, "login", now)
	if err != nil {
		return "", "", err
	}
	var session webauthn.SessionData
	if err := json.Unmarshal(ceremony.SessionJSON, &session); err != nil {
		return "", "", err
	}
	user, err := m.loadUser(ctx)
	if err != nil {
		return "", "", err
	}
	credential, err := m.webAuthn.FinishLogin(user, session, request)
	if err != nil {
		return "", "", fmt.Errorf("verify login: %w", err)
	}
	credentialJSON, err := json.Marshal(credential)
	if err != nil {
		return "", "", err
	}
	if err := m.store.UpdateCredential(ctx, user.owner.ID, store.CredentialRecord{ID: credential.ID, JSON: credentialJSON}, now); err != nil {
		return "", "", err
	}
	code, err := m.issueAuthCode(ctx, user.owner.ID, ceremony.OAuth, now)
	return code, ceremony.OAuth.State, err
}

func (m *Manager) issueAuthCode(ctx context.Context, ownerID string, oauth store.OAuthContext, now time.Time) (string, error) {
	code, err := store.NewToken(32)
	if err != nil {
		return "", err
	}
	if err := m.store.SaveAuthCode(ctx, code, ownerID, oauth, now.Add(m.config.AuthCodeTTL)); err != nil {
		return "", err
	}
	return code, nil
}

func (m *Manager) loadUser(ctx context.Context) (User, error) {
	owner, records, err := m.store.OwnerWithCredentials(ctx)
	if err != nil {
		return User{}, err
	}
	credentials := make([]webauthn.Credential, 0, len(records))
	for _, record := range records {
		var credential webauthn.Credential
		if err := json.Unmarshal(record.JSON, &credential); err != nil {
			return User{}, fmt.Errorf("decode credential: %w", err)
		}
		credentials = append(credentials, credential)
	}
	return User{owner: owner, credentials: credentials}, nil
}

func PKCES256(verifier string) (string, error) {
	if len(verifier) < 43 || len(verifier) > 128 {
		return "", errors.New("code_verifier must contain 43 through 128 characters")
	}
	for _, char := range verifier {
		if !(char >= 'a' && char <= 'z') && !(char >= 'A' && char <= 'Z') && !(char >= '0' && char <= '9') && !strings.ContainsRune("-._~", char) {
			return "", errors.New("code_verifier contains an invalid character")
		}
	}
	hash := sha256Sum([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(hash), nil
}

func ConstantTimeEqual(left, right string) bool {
	if len(left) != len(right) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

func sha256Sum(value []byte) []byte {
	h := sha256.New()
	h.Write(value)
	return h.Sum(nil)
}
