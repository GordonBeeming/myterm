package auth

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/fxamacker/cbor/v2"
	"github.com/go-webauthn/webauthn/protocol"
	"github.com/google/uuid"

	"github.com/gordonbeeming/myterm/relay/internal/config"
	"github.com/gordonbeeming/myterm/relay/internal/store"
)

type testAuthenticator struct {
	privateKey   *ecdsa.PrivateKey
	credentialID []byte
	rpID         string
	origin       string
	userHandle   []byte
}

func TestWebAuthnRegistrationAndLoginUseRealVerifier(t *testing.T) {
	manager, storage, oauth, bootstrap := newAuthTest(t)
	authenticator := newTestAuthenticator(t, "relay.example.com", "https://relay.example.com")

	options, ceremonyID, err := manager.BeginRegistration(context.Background(), oauth, bootstrap, "owner", "Relay owner")
	if err != nil {
		t.Fatal(err)
	}
	creation := options.(*protocol.CredentialCreation)
	registerBody := authenticator.registrationResponse(t, creation.Response.Challenge.String(), true)
	request := httptest.NewRequest("POST", "/v1/webauthn/register/finish", bytes.NewReader(registerBody))
	request.Header.Set("Content-Type", "application/json")
	if _, err := manager.FinishRegistration(context.Background(), ceremonyID, request); err != nil {
		t.Fatalf("finish registration: %v", err)
	}

	owner, err := storage.Owner(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	authenticator.userHandle = owner.WebAuthnID
	loginOptions, loginCeremony, err := manager.BeginLogin(context.Background(), oauth)
	if err != nil {
		t.Fatal(err)
	}
	assertion := loginOptions.(*protocol.CredentialAssertion)
	loginBody := authenticator.loginResponse(t, assertion.Response.Challenge.String(), true)
	loginRequest := httptest.NewRequest("POST", "/v1/webauthn/login/finish", bytes.NewReader(loginBody))
	loginRequest.Header.Set("Content-Type", "application/json")
	if _, _, err := manager.FinishLogin(context.Background(), loginCeremony, loginRequest); err != nil {
		t.Fatalf("finish login: %v", err)
	}
}

func TestWebAuthnRejectsInvalidCeremonyEvidence(t *testing.T) {
	tests := []struct {
		name     string
		mutate   func(*testAuthenticator, string) string
		verified bool
	}{
		{name: "wrong challenge", mutate: func(_ *testAuthenticator, _ string) string {
			return base64.RawURLEncoding.EncodeToString([]byte("different challenge"))
		}, verified: true},
		{name: "wrong origin", mutate: func(a *testAuthenticator, challenge string) string {
			a.origin = "https://attacker.example"
			return challenge
		}, verified: true},
		{name: "wrong RP", mutate: func(a *testAuthenticator, challenge string) string { a.rpID = "attacker.example"; return challenge }, verified: true},
		{name: "missing user verification", mutate: func(_ *testAuthenticator, challenge string) string { return challenge }, verified: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			manager, _, oauth, bootstrap := newAuthTest(t)
			authenticator := newTestAuthenticator(t, "relay.example.com", "https://relay.example.com")
			options, ceremonyID, err := manager.BeginRegistration(context.Background(), oauth, bootstrap, "owner", "Relay owner")
			if err != nil {
				t.Fatal(err)
			}
			challenge := options.(*protocol.CredentialCreation).Response.Challenge.String()
			challenge = test.mutate(authenticator, challenge)
			body := authenticator.registrationResponse(t, challenge, test.verified)
			request := httptest.NewRequest("POST", "/finish", bytes.NewReader(body))
			request.Header.Set("Content-Type", "application/json")
			if _, err := manager.FinishRegistration(context.Background(), ceremonyID, request); err == nil {
				t.Fatal("expected WebAuthn verification failure")
			}
		})
	}
}

func TestAddPasskeyAndRecoveryArePurposeBoundAndTransactional(t *testing.T) {
	manager, storage, oauth, bootstrap := newAuthTest(t)
	first := newTestAuthenticator(t, "relay.example.com", "https://relay.example.com")
	completeRegistration(t, manager, oauth, bootstrap, first)
	owner, records, err := storage.OwnerWithCredentials(context.Background())
	if err != nil || len(records) != 1 {
		t.Fatalf("initial credentials=%d err=%v", len(records), err)
	}
	addToken, _ := store.NewToken(32)
	if err := storage.CreateOwnerEnrollmentToken(context.Background(), addToken, "add", time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	second := newTestAuthenticator(t, "relay.example.com", "https://relay.example.com")
	result := completeRegistration(t, manager, oauth, addToken, second)
	if len(result.RevokedDeviceIDs) != 0 {
		t.Fatal("add passkey revoked devices")
	}
	_, records, err = storage.OwnerWithCredentials(context.Background())
	if err != nil || len(records) != 2 {
		t.Fatalf("add credentials=%d err=%v", len(records), err)
	}
	first.userHandle = owner.WebAuthnID
	loginOptions, loginCeremony, err := manager.BeginLogin(context.Background(), oauth)
	if err != nil {
		t.Fatal(err)
	}
	loginBody := first.loginResponse(t, loginOptions.(*protocol.CredentialAssertion).Response.Challenge.String(), true)
	loginRequest := httptest.NewRequest("POST", "/login", bytes.NewReader(loginBody))
	loginRequest.Header.Set("Content-Type", "application/json")
	if _, _, err := manager.FinishLogin(context.Background(), loginCeremony, loginRequest); err != nil {
		t.Fatalf("original credential failed after add: %v", err)
	}
	if _, _, err := manager.BeginRegistration(context.Background(), oauth, addToken, "", ""); err == nil {
		t.Fatal("consumed add token replayed")
	}
	expired, _ := store.NewToken(32)
	if err := storage.CreateOwnerEnrollmentToken(context.Background(), expired, "add", time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := manager.BeginRegistration(context.Background(), oauth, expired, "", ""); err == nil {
		t.Fatal("expired add token accepted")
	}
	device := store.Device{ID: uuid.NewString(), OwnerID: owner.ID, Kind: "client", Name: "Phone"}
	if err := storage.CreateDeviceTokens(context.Background(), device, "old-access", "old-refresh", time.Now().Add(time.Hour), time.Now().Add(time.Hour), time.Now()); err != nil {
		t.Fatal(err)
	}
	recovery, _ := store.NewToken(32)
	if err := storage.CreateOwnerEnrollmentToken(context.Background(), recovery, "recover", time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	third := newTestAuthenticator(t, "relay.example.com", "https://relay.example.com")
	options, ceremony, err := manager.BeginRegistration(context.Background(), oauth, recovery, "MyTerm Dev", "MyTerm Dev")
	if err != nil {
		t.Fatal(err)
	}
	creation := options.(*protocol.CredentialCreation)
	if creation.Response.User.Name != "MyTerm Dev" || creation.Response.User.DisplayName != "MyTerm Dev" {
		t.Fatal("recovery ignored the requested passkey label")
	}
	replayOptions, replayCeremony, err := manager.BeginRegistration(context.Background(), oauth, recovery, "", "")
	if err != nil {
		t.Fatal(err)
	}
	finish := func(options any, id string, a *testAuthenticator) (RegistrationResult, error) {
		body := a.registrationResponse(t, options.(*protocol.CredentialCreation).Response.Challenge.String(), true)
		request := httptest.NewRequest("POST", "/finish", bytes.NewReader(body))
		request.Header.Set("Content-Type", "application/json")
		return manager.FinishRegistration(context.Background(), id, request)
	}
	recovered, err := finish(options, ceremony, third)
	if err != nil {
		t.Fatal(err)
	}
	ownerAfterRecovery, err := storage.Owner(context.Background())
	if err != nil || ownerAfterRecovery.ID != owner.ID || !bytes.Equal(ownerAfterRecovery.WebAuthnID, owner.WebAuthnID) || ownerAfterRecovery.Name != owner.Name || ownerAfterRecovery.DisplayName != owner.DisplayName {
		t.Fatal("passkey relabel changed the stored owner identity or labels")
	}
	if len(recovered.RevokedDeviceIDs) != 1 || recovered.RevokedDeviceIDs[0] != device.ID {
		t.Fatalf("revoked devices %+v", recovered.RevokedDeviceIDs)
	}
	if _, err := storage.AuthenticateAccess(context.Background(), "old-access", time.Now()); !errors.Is(err, store.ErrUnauthorized) {
		t.Fatalf("old device survived recovery: %v", err)
	}
	_, records, err = storage.OwnerWithCredentials(context.Background())
	if err != nil || len(records) != 1 || !bytes.Equal(records[0].ID, third.credentialID) {
		t.Fatalf("recovery credentials=%+v err=%v", records, err)
	}
	fourth := newTestAuthenticator(t, "relay.example.com", "https://relay.example.com")
	if _, err := finish(replayOptions, replayCeremony, fourth); err == nil {
		t.Fatal("parallel recovery token replay completed")
	}
	_, records, _ = storage.OwnerWithCredentials(context.Background())
	if len(records) != 1 || !bytes.Equal(records[0].ID, third.credentialID) {
		t.Fatal("failed replay changed recovered credential")
	}
	oldLoginOptions, oldLoginCeremony, err := manager.BeginLogin(context.Background(), oauth)
	if err != nil {
		t.Fatal(err)
	}
	oldLoginBody := first.loginResponse(t, oldLoginOptions.(*protocol.CredentialAssertion).Response.Challenge.String(), true)
	oldLoginRequest := httptest.NewRequest("POST", "/login", bytes.NewReader(oldLoginBody))
	oldLoginRequest.Header.Set("Content-Type", "application/json")
	if _, _, err := manager.FinishLogin(context.Background(), oldLoginCeremony, oldLoginRequest); err == nil {
		t.Fatal("recovery left original credential usable")
	}
}

func completeRegistration(t *testing.T, manager *Manager, oauth store.OAuthContext, token string, a *testAuthenticator) RegistrationResult {
	t.Helper()
	options, ceremony, err := manager.BeginRegistration(context.Background(), oauth, token, "owner", "Relay owner")
	if err != nil {
		t.Fatal(err)
	}
	body := a.registrationResponse(t, options.(*protocol.CredentialCreation).Response.Challenge.String(), true)
	request := httptest.NewRequest("POST", "/finish", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	result, err := manager.FinishRegistration(context.Background(), ceremony, request)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func newAuthTest(t *testing.T) (*Manager, *store.Store, store.OAuthContext, string) {
	t.Helper()
	publicURL, _ := url.Parse("https://relay.example.com")
	cfg := config.Config{PublicURL: publicURL, RPID: "relay.example.com", RPDisplayName: "MyTerm Relay", CeremonyTTL: 5 * time.Minute, AuthCodeTTL: 2 * time.Minute}
	storage, err := store.Open(context.Background(), "file:"+t.Name()+"?mode=memory&cache=shared")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { storage.Close() })
	bootstrap, err := store.NewToken(32)
	if err != nil {
		t.Fatal(err)
	}
	if err := storage.CreateBootstrapToken(context.Background(), bootstrap, time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	manager, err := New(cfg, storage)
	if err != nil {
		t.Fatal(err)
	}
	oauth := store.OAuthContext{RedirectURI: "myterm-companion://auth/callback", State: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{'s'}, 32)), CodeChallenge: strings.Repeat("c", 43), DeviceName: "Test device", DeviceKind: "client"}
	return manager, storage, oauth, bootstrap
}

func newTestAuthenticator(t *testing.T, rpID, origin string) *testAuthenticator {
	t.Helper()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	credentialID := make([]byte, 32)
	if _, err := rand.Read(credentialID); err != nil {
		t.Fatal(err)
	}
	return &testAuthenticator{privateKey: privateKey, credentialID: credentialID, rpID: rpID, origin: origin}
}

func (a *testAuthenticator) registrationResponse(t *testing.T, challenge string, verified bool) []byte {
	t.Helper()
	clientData := marshalTestJSON(t, map[string]any{"type": "webauthn.create", "challenge": challenge, "origin": a.origin, "crossOrigin": false})
	rpHash := sha256.Sum256([]byte(a.rpID))
	flags := byte(0x41)
	if verified {
		flags |= 0x04
	}
	authData := append([]byte(nil), rpHash[:]...)
	authData = append(authData, flags, 0, 0, 0, 0)
	authData = append(authData, make([]byte, 16)...)
	credentialLength := make([]byte, 2)
	binary.BigEndian.PutUint16(credentialLength, uint16(len(a.credentialID)))
	authData = append(authData, credentialLength...)
	authData = append(authData, a.credentialID...)
	key := map[int]any{1: 2, 3: -7, -1: 1, -2: a.privateKey.PublicKey.X.Bytes(), -3: a.privateKey.PublicKey.Y.Bytes()}
	encodedKey, err := cbor.Marshal(key)
	if err != nil {
		t.Fatal(err)
	}
	authData = append(authData, encodedKey...)
	attestation, err := cbor.Marshal(map[string]any{"fmt": "none", "attStmt": map[string]any{}, "authData": authData})
	if err != nil {
		t.Fatal(err)
	}
	encodedID := base64.RawURLEncoding.EncodeToString(a.credentialID)
	return marshalTestJSON(t, map[string]any{
		"id": encodedID, "rawId": encodedID, "type": "public-key",
		"response":               map[string]any{"attestationObject": base64.RawURLEncoding.EncodeToString(attestation), "clientDataJSON": base64.RawURLEncoding.EncodeToString(clientData), "transports": []string{"internal"}},
		"clientExtensionResults": map[string]any{},
	})
}

func (a *testAuthenticator) loginResponse(t *testing.T, challenge string, verified bool) []byte {
	t.Helper()
	clientData := marshalTestJSON(t, map[string]any{"type": "webauthn.get", "challenge": challenge, "origin": a.origin, "crossOrigin": false})
	rpHash := sha256.Sum256([]byte(a.rpID))
	flags := byte(0x01)
	if verified {
		flags |= 0x04
	}
	authData := append([]byte(nil), rpHash[:]...)
	authData = append(authData, flags, 0, 0, 0, 1)
	clientHash := sha256.Sum256(clientData)
	signed := append(append([]byte(nil), authData...), clientHash[:]...)
	digest := sha256.Sum256(signed)
	signature, err := ecdsa.SignASN1(rand.Reader, a.privateKey, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	encodedID := base64.RawURLEncoding.EncodeToString(a.credentialID)
	return marshalTestJSON(t, map[string]any{
		"id": encodedID, "rawId": encodedID, "type": "public-key",
		"response":               map[string]any{"authenticatorData": base64.RawURLEncoding.EncodeToString(authData), "clientDataJSON": base64.RawURLEncoding.EncodeToString(clientData), "signature": base64.RawURLEncoding.EncodeToString(signature), "userHandle": base64.RawURLEncoding.EncodeToString(a.userHandle)},
		"clientExtensionResults": map[string]any{},
	})
}

func marshalTestJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestCompanionChannelRedirectsAreExact(t *testing.T) {
	values := url.Values{
		"state":                 {base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))},
		"code_challenge":        {base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32))},
		"code_challenge_method": {"S256"}, "device_name": {"Demo phone"}, "device_kind": {"client"},
	}
	for _, redirect := range []string{"myterm-companion://auth/callback", "myterm-companion-dev://auth/callback"} {
		values.Set("redirect_uri", redirect)
		got, err := ValidateOAuthContext(values)
		if err != nil || got.RedirectURI != redirect {
			t.Fatalf("valid channel callback rejected: %s: %v", redirect, err)
		}
	}
	for _, redirect := range []string{"myterm-companion://other/callback", "myterm-companion://auth/other", "myterm-companion://auth/callback?extra=1", "myterm-companion://auth/callback#fragment", "myterm-companion-dev://other/callback", "myterm-companion-dev://auth/other", "myterm-companion-dev://auth/callback?extra=1", "myterm-companion-dev://auth/callback#fragment"} {
		values.Set("redirect_uri", redirect)
		if _, err := ValidateOAuthContext(values); err == nil {
			t.Fatalf("accepted unregistered callback: %s", redirect)
		}
	}
}
