package httpapi

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"golang.org/x/time/rate"

	"github.com/gordonbeeming/myterm/push-gateway/internal/apns"
	"github.com/gordonbeeming/myterm/push-gateway/internal/attest"
	"github.com/gordonbeeming/myterm/push-gateway/internal/config"
	"github.com/gordonbeeming/myterm/push-gateway/internal/store"
)

type captureAPNS struct {
	payloads    [][]byte
	resultError error
}
type activationVerifier struct{}

func (activationVerifier) VerifyAttestation([]byte, []byte, string) (attest.Attestation, error) {
	return attest.Attestation{}, nil
}
func (activationVerifier) VerifyAssertion([]byte, []byte, []byte, uint32) (uint32, error) {
	return 1, nil
}

func TestActivationResponseUsesPublicUUIDRecipientID(t *testing.T) {
	storage, err := store.Open(context.Background(), ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	now := time.Unix(1789470900, 0)
	id := uuid.NewString()
	if err := storage.CreateEnrollment(context.Background(), store.Enrollment{ID: id, Challenge: []byte("challenge"), ExpiresAt: now.Add(time.Minute).Unix()}); err != nil {
		t.Fatal(err)
	}
	if err := storage.CompleteAttestation(context.Background(), id, "key", bytes.Repeat([]byte{1}, 65), []byte("receipt"), bytes.Repeat([]byte{2}, 65), strings.Repeat("a", 64), []byte("push"), now); err != nil {
		t.Fatal(err)
	}
	publicURL, _ := url.Parse("https://push.example.com")
	server := newServer(config.Config{PublicURL: publicURL, DeviceSessionTTL: time.Hour}, storage, &captureAPNS{}, activationVerifier{})
	server.now = func() time.Time { return now }
	server.enrollmentLimit.now = server.now
	httpServer := httptest.NewServer(server.Handler())
	defer httpServer.Close()
	response := requestRaw(t, httpServer, http.MethodPost, "/v1/enrollments/"+id+"/activate", []byte(`{"assertion":"AQ"}`), "")
	if response.StatusCode != 201 {
		t.Fatalf("activate %d: %s", response.StatusCode, read(t, response))
	}
	var value struct {
		RecipientID        string `json:"recipient_id"`
		DeviceSessionToken string `json:"device_session_token"`
		TokenType          string `json:"token_type"`
	}
	decodeResponse(t, response, &value)
	if _, err := uuid.Parse(value.RecipientID); err != nil {
		t.Fatalf("recipient_id %q is not UUID", value.RecipientID)
	}
	if value.DeviceSessionToken == "" || value.TokenType != "Device" {
		t.Fatalf("SDK activation fixture mismatch: %+v", value)
	}
}

func (c *captureAPNS) Send(_ context.Context, _ string, payload []byte, _ string) (string, error) {
	c.payloads = append(c.payloads, append([]byte(nil), payload...))
	return "apns-id", c.resultError
}

func TestSignedGrantNotificationRotationCrossRecipientAndRevocation(t *testing.T) {
	storage, err := store.Open(context.Background(), ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	now := time.Unix(1789470900, 0)
	deviceKey, session, recipient := seedHTTPDevice(t, storage, "first", now)
	otherKey, otherSession, _ := seedHTTPDevice(t, storage, "second", now)
	sender := &captureAPNS{}
	publicURL, _ := url.Parse("https://push.example.com")
	cfg := config.Config{PublicURL: publicURL, ChallengeTTL: time.Minute, DeviceSessionTTL: time.Hour}
	server := newServer(cfg, storage, sender, nil)
	server.now = func() time.Time { return now }
	server.enrollmentLimit.now = server.now
	server.notificationLimit.now = server.now
	httpServer := httptest.NewServer(server.Handler())
	defer httpServer.Close()
	hostKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	hostPublic := elliptic.Marshal(elliptic.P256(), hostKey.X, hostKey.Y)
	grantBody := marshal(t, map[string]any{"relay_origin": "https://relay.example.com", "host_id": uuid.NewString(), "host_public_key": base64.RawURLEncoding.EncodeToString(hostPublic)})
	response := signedDeviceRequest(t, httpServer, http.MethodPost, "/v1/recipient-grants", session, deviceKey, now, grantBody)
	if response.StatusCode != 201 {
		t.Fatalf("create grant %d: %s", response.StatusCode, read(t, response))
	}
	var grant struct {
		GrantID    string `json:"grant_id"`
		GrantToken string `json:"grant_token"`
	}
	decodeResponse(t, response, &grant)
	eventID := uuid.NewString()
	ciphertext := bytes.Repeat([]byte{9}, 64)
	eventBody := signedEventBody(t, hostKey, grant.GrantID, recipient, eventID, now.Unix(), ciphertext)
	response = grantRequest(t, httpServer, grant.GrantToken, eventBody)
	if response.StatusCode != 202 {
		t.Fatalf("notification %d: %s", response.StatusCode, read(t, response))
	}
	response.Body.Close()
	if len(sender.payloads) != 1 || len(sender.payloads[0]) > 4096 {
		t.Fatalf("APNs payload count/size %d/%d", len(sender.payloads), len(sender.payloads[0]))
	}
	text := string(sender.payloads[0])
	for _, forbidden := range []string{"relay.example.com", "workspace", "command", "terminal title"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("APNs payload leaked %q: %s", forbidden, text)
		}
	}
	if !strings.Contains(text, "MyTerm needs attention") || !strings.Contains(text, `"mutable-content":1`) {
		t.Fatalf("missing generic alert: %s", text)
	}
	rotate := signedDeviceRequest(t, httpServer, http.MethodPost, "/v1/recipient-grants/"+grant.GrantID+"/rotate-token", session, deviceKey, now.Add(time.Second), []byte(`{}`))
	if rotate.StatusCode != 200 {
		t.Fatalf("rotate %d: %s", rotate.StatusCode, read(t, rotate))
	}
	var rotated struct {
		GrantToken string `json:"grant_token"`
	}
	decodeResponse(t, rotate, &rotated)
	response = grantRequest(t, httpServer, grant.GrantToken, signedEventBody(t, hostKey, grant.GrantID, recipient, uuid.NewString(), now.Unix(), ciphertext))
	if response.StatusCode != 401 {
		t.Fatalf("old grant token status %d", response.StatusCode)
	}
	response.Body.Close()
	response = signedDeviceRequest(t, httpServer, http.MethodDelete, "/v1/recipient-grants/"+grant.GrantID, otherSession, otherKey, now.Add(2*time.Second), nil)
	if response.StatusCode != 404 {
		t.Fatalf("cross recipient revoke status %d", response.StatusCode)
	}
	response.Body.Close()
	response = signedDeviceRequest(t, httpServer, http.MethodDelete, "/v1/recipient-grants/"+grant.GrantID, session, deviceKey, now.Add(3*time.Second), nil)
	if response.StatusCode != 204 {
		t.Fatalf("revoke status %d: %s", response.StatusCode, read(t, response))
	}
	response.Body.Close()
	response = grantRequest(t, httpServer, rotated.GrantToken, signedEventBody(t, hostKey, grant.GrantID, recipient, uuid.NewString(), now.Unix(), ciphertext))
	if response.StatusCode != 401 {
		t.Fatalf("revoked grant status %d", response.StatusCode)
	}
	response.Body.Close()
}

func TestAPNS410DisablesRecipient(t *testing.T) {
	storage, err := store.Open(context.Background(), ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	now := time.Unix(1789470900, 0)
	_, _, recipient := seedHTTPDevice(t, storage, "gone", now)
	hostKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	grant := store.Grant{ID: uuid.NewString(), RecipientID: recipient, RelayOrigin: "https://relay.example.com", HostID: uuid.NewString(), HostPublicKey: elliptic.Marshal(elliptic.P256(), hostKey.X, hostKey.Y)}
	if err := storage.CreateGrant(context.Background(), grant, "grant", now); err != nil {
		t.Fatal(err)
	}
	sender := &captureAPNS{resultError: &apns.Error{Status: 410, Reason: "Unregistered", Unregistered: true}}
	publicURL, _ := url.Parse("https://push.example.com")
	server := newServer(config.Config{PublicURL: publicURL}, storage, sender, nil)
	server.now = func() time.Time { return now }
	server.notificationLimit.now = server.now
	httpServer := httptest.NewServer(server.Handler())
	defer httpServer.Close()
	body := signedEventBody(t, hostKey, grant.ID, recipient, uuid.NewString(), now.Unix(), bytes.Repeat([]byte{1}, 32))
	response := grantRequest(t, httpServer, "grant", body)
	if response.StatusCode != 409 {
		t.Fatalf("410 mapping status %d: %s", response.StatusCode, read(t, response))
	}
	response.Body.Close()
	_, active, err := storage.DeviceToken(context.Background(), recipient)
	if err != nil || active {
		t.Fatalf("recipient active=%v err=%v", active, err)
	}
}

func TestIPLimiterBoundsAndPrunesSourceEntries(t *testing.T) {
	now := time.Unix(1789470900, 0)
	limiter := newIPLimiter(rate.Every(time.Second), 1, func() time.Time { return now })
	for index := 0; index < maximumLimiterEntries; index++ {
		if !limiter.allow(fmt.Sprintf("192.0.2.%d", index)) {
			t.Fatalf("entry %d rejected", index)
		}
	}
	if limiter.allow("overflow") {
		t.Fatal("limiter exceeded source cap")
	}
	now = now.Add(2 * time.Hour)
	if !limiter.allow("after-prune") {
		t.Fatal("stale entries were not pruned")
	}
	if len(limiter.entries) > maximumLimiterEntries {
		t.Fatalf("limiter retained %d entries", len(limiter.entries))
	}
}

func seedHTTPDevice(t *testing.T, s *store.Store, suffix string, now time.Time) (*ecdsa.PrivateKey, string, string) {
	t.Helper()
	private, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	public := elliptic.Marshal(elliptic.P256(), private.X, private.Y)
	id := uuid.NewString()
	challenge := []byte("challenge")
	if err := s.CreateEnrollment(context.Background(), store.Enrollment{ID: id, Challenge: challenge, ExpiresAt: now.Add(time.Minute).Unix()}); err != nil {
		t.Fatal(err)
	}
	e := store.Enrollment{ID: id, KeyID: "key-" + suffix, AppAttestPublicKey: public, Receipt: []byte("receipt"), DevicePublicKey: public, PendingAPNSToken: strings.Repeat("a", 64), APNSChallenge: []byte("push"), ExpiresAt: now.Add(time.Minute).Unix()}
	if err := s.CompleteAttestation(context.Background(), id, e.KeyID, e.AppAttestPublicKey, e.Receipt, e.DevicePublicKey, e.PendingAPNSToken, e.APNSChallenge, now); err != nil {
		t.Fatal(err)
	}
	session := "session-" + suffix
	recipient := "recipient-" + suffix
	if err := s.Activate(context.Background(), id, e, 1, recipient, session, now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}
	return private, session, recipient
}
func signedDeviceRequest(t *testing.T, server *httptest.Server, method, path, session string, key *ecdsa.PrivateKey, now time.Time, body []byte) *http.Response {
	t.Helper()
	if body == nil {
		body = []byte{}
	}
	nonceRaw := make([]byte, 16)
	rand.Read(nonceRaw)
	nonce := base64.RawURLEncoding.EncodeToString(nonceRaw)
	canonical := deviceCanonical(method, path, now.Unix(), nonce, body)
	digest := sha256.Sum256(canonical)
	signature, _ := ecdsa.SignASN1(rand.Reader, key, digest[:])
	request, _ := http.NewRequest(method, server.URL+path, bytes.NewReader(body))
	request.Header.Set("Authorization", "Device "+session)
	request.Header.Set("X-MyTerm-Timestamp", strconv.FormatInt(now.Unix(), 10))
	request.Header.Set("X-MyTerm-Nonce", nonce)
	request.Header.Set("X-MyTerm-Signature", base64.RawURLEncoding.EncodeToString(signature))
	request.Header.Set("Content-Type", "application/json")
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}
func signedEventBody(t *testing.T, key *ecdsa.PrivateKey, grantID, recipient, eventID string, timestamp int64, ciphertext []byte) []byte {
	t.Helper()
	g := store.Grant{ID: grantID, RecipientID: recipient}
	canonical := hostCanonical(g, eventID, timestamp, ciphertext)
	digest := sha256.Sum256(canonical)
	signature, _ := ecdsa.SignASN1(rand.Reader, key, digest[:])
	return marshal(t, map[string]any{"event_id": eventID, "timestamp": timestamp, "ciphertext": base64.RawURLEncoding.EncodeToString(ciphertext), "host_signature": base64.RawURLEncoding.EncodeToString(signature)})
}
func grantRequest(t *testing.T, server *httptest.Server, token string, body []byte) *http.Response {
	t.Helper()
	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/notifications", bytes.NewReader(body))
	request.Header.Set("Authorization", "Grant "+token)
	request.Header.Set("Content-Type", "application/json")
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}
func requestRaw(t *testing.T, server *httptest.Server, method, path string, body []byte, authorization string) *http.Response {
	t.Helper()
	request, _ := http.NewRequest(method, server.URL+path, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	if authorization != "" {
		request.Header.Set("Authorization", authorization)
	}
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}
func marshal(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
func decodeResponse(t *testing.T, r *http.Response, v any) {
	t.Helper()
	defer r.Body.Close()
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		t.Fatal(err)
	}
}
func read(t *testing.T, r *http.Response) string {
	t.Helper()
	defer r.Body.Close()
	b, _ := io.ReadAll(r.Body)
	return string(b)
}
