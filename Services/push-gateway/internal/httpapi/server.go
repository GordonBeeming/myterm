package httpapi

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"golang.org/x/time/rate"

	"github.com/gordonbeeming/myterm/push-gateway/internal/apns"
	"github.com/gordonbeeming/myterm/push-gateway/internal/attest"
	"github.com/gordonbeeming/myterm/push-gateway/internal/config"
	"github.com/gordonbeeming/myterm/push-gateway/internal/store"
)

type attestationVerifier interface {
	VerifyAttestation([]byte, []byte, string) (attest.Attestation, error)
	VerifyAssertion([]byte, []byte, []byte, uint32) (uint32, error)
}
type Server struct {
	cfg                                config.Config
	store                              *store.Store
	attest                             attestationVerifier
	apns                               apns.Sender
	now                                func() time.Time
	enrollmentLimit, notificationLimit *ipLimiter
}
type contextKey int

const deviceKey contextKey = 0

type deviceRequest struct {
	device store.Device
	body   []byte
}

func New(cfg config.Config, storage *store.Store, sender apns.Sender) (*Server, error) {
	verifier, err := attest.New(cfg.TeamID, cfg.BundleID, cfg.AppAttestEnvironment)
	if err != nil {
		return nil, err
	}
	return newServer(cfg, storage, sender, verifier), nil
}
func newServer(cfg config.Config, storage *store.Store, sender apns.Sender, verifier attestationVerifier) *Server {
	now := time.Now
	return &Server{cfg: cfg, store: storage, apns: sender, attest: verifier, now: now, enrollmentLimit: newIPLimiter(rate.Every(6*time.Second), 10, now), notificationLimit: newIPLimiter(rate.Every(time.Second), 20, now)}
}

func (s *Server) Handler() http.Handler {
	r := chi.NewRouter()
	r.Use(securityHeaders)
	r.Get("/livez", func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) })
	r.Get("/readyz", func(w http.ResponseWriter, r *http.Request) {
		if err := s.store.Ping(r.Context()); err != nil {
			writeError(w, http.StatusServiceUnavailable, "not_ready", "Storage is unavailable.")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
	})
	r.With(s.limit(s.enrollmentLimit)).Post("/v1/enrollments", s.createEnrollment)
	r.With(s.limit(s.enrollmentLimit)).Post("/v1/enrollments/{id}/attest", s.attestEnrollment)
	r.With(s.limit(s.enrollmentLimit)).Post("/v1/enrollments/{id}/activate", s.activateEnrollment)
	r.Group(func(d chi.Router) {
		d.Use(s.authenticateDevice)
		d.Post("/v1/recipient-grants", s.createGrant)
		d.Post("/v1/recipient-grants/{id}/rotate-token", s.rotateGrant)
		d.Delete("/v1/recipient-grants/{id}", s.revokeGrant)
		d.Post("/v1/apns-token-challenges", s.createTokenChallenge)
		d.Post("/v1/apns-token-challenges/{id}/confirm", s.confirmTokenChallenge)
	})
	r.With(s.limit(s.notificationLimit)).Post("/v1/notifications", s.notify)
	return r
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) createEnrollment(w http.ResponseWriter, r *http.Request) {
	var empty struct{}
	if !decodeStrict(w, r, 1024, &empty) {
		return
	}
	challenge, err := store.Random(32)
	if err != nil {
		internalError(w, err)
		return
	}
	id := uuid.NewString()
	expires := s.now().Add(s.cfg.ChallengeTTL)
	if err = s.store.CreateEnrollment(r.Context(), store.Enrollment{ID: id, Challenge: challenge, ExpiresAt: expires.Unix()}); err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, 201, map[string]any{"enrollment_id": id, "challenge": base64.RawURLEncoding.EncodeToString(challenge), "expires_at": expires.Unix()})
}

func (s *Server) attestEnrollment(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if _, err := uuid.Parse(id); err != nil {
		bad(w, "invalid_enrollment", "Enrollment identifier is invalid.")
		return
	}
	var req struct {
		KeyID             string `json:"key_id"`
		AttestationObject string `json:"attestation_object"`
		DevicePublicKey   string `json:"device_public_key"`
		APNSToken         string `json:"apns_token"`
	}
	if !decodeStrict(w, r, 256<<10, &req) {
		return
	}
	object, err := base64.RawURLEncoding.DecodeString(req.AttestationObject)
	if err != nil {
		bad(w, "invalid_attestation", "Attestation is not base64url.")
		return
	}
	deviceKey, err := parseP256(req.DevicePublicKey)
	if err != nil {
		bad(w, "invalid_device_key", err.Error())
		return
	}
	if !validAPNSToken(req.APNSToken) {
		bad(w, "invalid_apns_token", "APNs token must be lowercase hexadecimal.")
		return
	}
	enrollment, err := s.store.Enrollment(r.Context(), id, s.now())
	if err != nil {
		authError(w, err)
		return
	}
	verified, err := s.attest.VerifyAttestation(object, enrollment.Challenge, req.KeyID)
	if err != nil {
		writeError(w, 401, "invalid_app_attest", "App Attest verification failed.")
		return
	}
	ownership, err := store.Random(32)
	if err != nil {
		internalError(w, err)
		return
	}
	now := s.now()
	if err = s.store.CompleteAttestation(r.Context(), id, req.KeyID, verified.PublicKey, verified.Receipt, deviceKey, req.APNSToken, ownership, now); err != nil {
		authError(w, err)
		return
	}
	payload, err := json.Marshal(map[string]any{"aps": map[string]any{"alert": map[string]string{"title": "MyTerm", "body": "MyTerm needs attention"}, "mutable-content": 1}, "enrollment": map[string]string{"id": id, "challenge": base64.RawURLEncoding.EncodeToString(ownership)}})
	if err != nil {
		internalError(w, err)
		return
	}
	if _, err = s.apns.Send(r.Context(), req.APNSToken, payload, "enroll-"+id); err != nil {
		logCleanup(s.store.DeleteEnrollment(r.Context(), id))
		apnsError(w, err)
		return
	}
	writeJSON(w, 202, map[string]string{"enrollment_id": id, "status": "awaiting_apns_confirmation"})
}

func (s *Server) activateEnrollment(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var req struct {
		Assertion string `json:"assertion"`
	}
	if !decodeStrict(w, r, 64<<10, &req) {
		return
	}
	encoded, err := base64.RawURLEncoding.DecodeString(req.Assertion)
	if err != nil {
		bad(w, "invalid_assertion", "Assertion is not base64url.")
		return
	}
	e, err := s.store.PendingActivation(r.Context(), id, s.now())
	if err != nil {
		authError(w, err)
		return
	}
	clientData := activationData(id, e.APNSChallenge)
	counter, err := s.attest.VerifyAssertion(encoded, clientData, e.AppAttestPublicKey, e.Counter)
	if err != nil {
		writeError(w, 401, "invalid_assertion", "App Attest assertion verification failed.")
		return
	}
	recipientValue, err := uuid.NewRandom()
	if err != nil {
		internalError(w, err)
		return
	}
	recipient := recipientValue.String()
	session, err := store.Token(48)
	if err != nil {
		internalError(w, err)
		return
	}
	now := s.now()
	if err = s.store.Activate(r.Context(), id, e, counter, recipient, session, now.Add(s.cfg.DeviceSessionTTL), now); err != nil {
		authError(w, err)
		return
	}
	writeJSON(w, 201, map[string]string{"recipient_id": recipient, "device_session_token": session, "token_type": "Device"})
}

func activationData(id string, challenge []byte) []byte {
	return []byte("myterm-app-attest-v1\nenrollment-activate\n" + id + "\n" + base64.RawURLEncoding.EncodeToString(challenge))
}

func (s *Server) authenticateDevice(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if hasCredentialQuery(r.URL.Query()) {
			bad(w, "token_in_url", "Tokens are accepted only in Authorization.")
			return
		}
		authHeader := r.Header.Get("Authorization")
		if !strings.HasPrefix(authHeader, "Device ") || strings.ContainsAny(strings.TrimPrefix(authHeader, "Device "), " \t\r\n") {
			writeError(w, 401, "unauthorized", "Device authentication is required.")
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 128<<10))
		if err != nil {
			bad(w, "invalid_body", "Request body is too large.")
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		device, err := s.store.AuthenticateDevice(r.Context(), strings.TrimPrefix(authHeader, "Device "), s.now())
		if err != nil {
			if errors.Is(err, store.ErrUnauthorized) {
				writeError(w, 401, "unauthorized", "Device session is invalid or expired.")
			} else {
				internalError(w, err)
			}
			return
		}
		timestamp, err := strconv.ParseInt(r.Header.Get("X-MyTerm-Timestamp"), 10, 64)
		if err != nil || abs(s.now().Unix()-timestamp) > 300 {
			writeError(w, 401, "invalid_signature", "Request timestamp is outside the allowed window.")
			return
		}
		nonce := r.Header.Get("X-MyTerm-Nonce")
		nonceBytes, err := base64.RawURLEncoding.DecodeString(nonce)
		if err != nil || len(nonceBytes) < 16 || len(nonceBytes) > 32 {
			writeError(w, 401, "invalid_signature", "Request nonce is invalid.")
			return
		}
		signature, err := base64.RawURLEncoding.DecodeString(r.Header.Get("X-MyTerm-Signature"))
		if err != nil {
			writeError(w, 401, "invalid_signature", "Request signature is invalid.")
			return
		}
		canonical := deviceCanonical(r.Method, r.URL.EscapedPath(), timestamp, nonce, body)
		if !verifyP256(device.DevicePublicKey, canonical, signature) {
			writeError(w, 401, "invalid_signature", "Request signature is invalid.")
			return
		}
		if err = s.store.ConsumeNonce(r.Context(), device.RecipientID, nonce, s.now().Add(10*time.Minute)); err != nil {
			writeError(w, 409, "replayed_request", "Request nonce was already used.")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), deviceKey, deviceRequest{device: device, body: body})))
	})
}

func deviceCanonical(method, path string, timestamp int64, nonce string, body []byte) []byte {
	hash := sha256.Sum256(body)
	return []byte(fmt.Sprintf("myterm-device-v1\n%s\n%s\n%d\n%s\n%s", strings.ToUpper(method), path, timestamp, nonce, base64.RawURLEncoding.EncodeToString(hash[:])))
}

func (s *Server) createGrant(w http.ResponseWriter, r *http.Request) {
	d := r.Context().Value(deviceKey).(deviceRequest).device
	var req struct {
		RelayOrigin   string `json:"relay_origin"`
		HostID        string `json:"host_id"`
		HostPublicKey string `json:"host_public_key"`
	}
	if !decodeBody(w, r, &req) {
		return
	}
	origin, err := url.Parse(req.RelayOrigin)
	if err != nil || origin.Scheme != "https" || origin.Host == "" || origin.User != nil || origin.Path != "" || origin.RawQuery != "" || origin.Fragment != "" {
		bad(w, "invalid_relay_origin", "Relay origin must be an HTTPS origin without a path.")
		return
	}
	if _, err = uuid.Parse(req.HostID); err != nil {
		bad(w, "invalid_host_id", "Host identifier must be a UUID.")
		return
	}
	hostKey, err := parseP256(req.HostPublicKey)
	if err != nil {
		bad(w, "invalid_host_key", err.Error())
		return
	}
	token, err := store.Token(48)
	if err != nil {
		internalError(w, err)
		return
	}
	g := store.Grant{ID: uuid.NewString(), RecipientID: d.RecipientID, RelayOrigin: origin.String(), HostID: req.HostID, HostPublicKey: hostKey}
	if err = s.store.CreateGrant(r.Context(), g, token, s.now()); err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, 201, map[string]string{"grant_id": g.ID, "grant_token": token, "token_type": "Grant"})
}
func (s *Server) rotateGrant(w http.ResponseWriter, r *http.Request) {
	d := r.Context().Value(deviceKey).(deviceRequest).device
	token, err := store.Token(48)
	if err != nil {
		internalError(w, err)
		return
	}
	if err := s.store.RotateGrant(r.Context(), d.RecipientID, chi.URLParam(r, "id"), token, s.now()); err != nil {
		authError(w, err)
		return
	}
	writeJSON(w, 200, map[string]string{"grant_id": chi.URLParam(r, "id"), "grant_token": token, "token_type": "Grant"})
}
func (s *Server) revokeGrant(w http.ResponseWriter, r *http.Request) {
	d := r.Context().Value(deviceKey).(deviceRequest).device
	if err := s.store.RevokeGrant(r.Context(), d.RecipientID, chi.URLParam(r, "id"), s.now()); err != nil {
		authError(w, err)
		return
	}
	w.WriteHeader(204)
}

func (s *Server) createTokenChallenge(w http.ResponseWriter, r *http.Request) {
	d := r.Context().Value(deviceKey).(deviceRequest).device
	var req struct {
		APNSToken string `json:"apns_token"`
	}
	if !decodeBody(w, r, &req) {
		return
	}
	if !validAPNSToken(req.APNSToken) {
		bad(w, "invalid_apns_token", "APNs token must be lowercase hexadecimal.")
		return
	}
	challenge, err := store.Random(32)
	if err != nil {
		internalError(w, err)
		return
	}
	c := store.APNSTokenChallenge{ID: uuid.NewString(), RecipientID: d.RecipientID, PendingToken: req.APNSToken, Challenge: challenge, ExpiresAt: s.now().Add(s.cfg.ChallengeTTL).Unix()}
	if err := s.store.CreateAPNSTokenChallenge(r.Context(), c); err != nil {
		internalError(w, err)
		return
	}
	payload, err := json.Marshal(map[string]any{"aps": map[string]any{"alert": map[string]string{"title": "MyTerm", "body": "MyTerm needs attention"}, "mutable-content": 1}, "token_update": map[string]string{"challenge_id": c.ID, "challenge": base64.RawURLEncoding.EncodeToString(challenge)}})
	if err != nil {
		internalError(w, err)
		return
	}
	if _, err := s.apns.Send(r.Context(), req.APNSToken, payload, "token-"+c.ID); err != nil {
		logCleanup(s.store.DeleteAPNSTokenChallenge(r.Context(), d.RecipientID, c.ID))
		apnsError(w, err)
		return
	}
	writeJSON(w, 202, map[string]string{"challenge_id": c.ID, "status": "awaiting_apns_confirmation"})
}
func (s *Server) confirmTokenChallenge(w http.ResponseWriter, r *http.Request) {
	d := r.Context().Value(deviceKey).(deviceRequest).device
	var req struct {
		Challenge string `json:"challenge"`
	}
	if !decodeBody(w, r, &req) {
		return
	}
	challenge, err := base64.RawURLEncoding.DecodeString(req.Challenge)
	if err != nil {
		bad(w, "invalid_challenge", "Challenge is invalid.")
		return
	}
	if err = s.store.ConfirmAPNSToken(r.Context(), d.RecipientID, chi.URLParam(r, "id"), challenge, s.now()); err != nil {
		authError(w, err)
		return
	}
	w.WriteHeader(204)
}

func (s *Server) notify(w http.ResponseWriter, r *http.Request) {
	if hasCredentialQuery(r.URL.Query()) {
		bad(w, "token_in_url", "Tokens are accepted only in Authorization.")
		return
	}
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Grant ") || strings.ContainsAny(strings.TrimPrefix(header, "Grant "), " \t\r\n") {
		writeError(w, 401, "unauthorized", "Grant authentication is required.")
		return
	}
	g, err := s.store.GrantByToken(r.Context(), strings.TrimPrefix(header, "Grant "))
	if err != nil {
		authError(w, err)
		return
	}
	var req struct {
		EventID       string `json:"event_id"`
		Timestamp     int64  `json:"timestamp"`
		Ciphertext    string `json:"ciphertext"`
		HostSignature string `json:"host_signature"`
	}
	if !decodeStrict(w, r, 8<<10, &req) {
		return
	}
	if _, err = uuid.Parse(req.EventID); err != nil || abs(s.now().Unix()-req.Timestamp) > 300 {
		bad(w, "invalid_event", "Event identifier or timestamp is invalid.")
		return
	}
	ciphertext, err := base64.RawURLEncoding.DecodeString(req.Ciphertext)
	if err != nil || len(ciphertext) < 16 {
		bad(w, "invalid_ciphertext", "Ciphertext is invalid.")
		return
	}
	signature, err := base64.RawURLEncoding.DecodeString(req.HostSignature)
	if err != nil || !verifyP256(g.HostPublicKey, hostCanonical(g, req.EventID, req.Timestamp, ciphertext), signature) {
		writeError(w, 401, "invalid_host_signature", "Host event signature is invalid.")
		return
	}
	if err = s.store.ConsumeEvent(r.Context(), g.ID, req.EventID, s.now()); err != nil {
		writeError(w, 409, "replayed_event", "Event identifier was already used.")
		return
	}
	deviceToken, active, err := s.store.DeviceToken(r.Context(), g.RecipientID)
	if err != nil {
		logCleanup(s.store.DeleteEvent(r.Context(), g.ID, req.EventID))
		internalError(w, err)
		return
	}
	if !active {
		logCleanup(s.store.DeleteEvent(r.Context(), g.ID, req.EventID))
		writeError(w, 409, "recipient_not_available", "Recipient is not available.")
		return
	}
	payload, err := notificationPayload(g.ID, g.RecipientID, req.EventID, req.Timestamp, req.Ciphertext)
	if err != nil {
		logCleanup(s.store.DeleteEvent(r.Context(), g.ID, req.EventID))
		bad(w, "payload_too_large", err.Error())
		return
	}
	apnsID, err := s.apns.Send(r.Context(), deviceToken, payload, req.EventID)
	if err != nil {
		logCleanup(s.store.DeleteEvent(r.Context(), g.ID, req.EventID))
		var apnsErr *apns.Error
		if errors.As(err, &apnsErr) && apnsErr.Unregistered {
			s.store.DisableDevice(r.Context(), g.RecipientID, s.now())
		}
		apnsError(w, err)
		return
	}
	writeJSON(w, 202, map[string]string{"event_id": req.EventID, "apns_id": apnsID})
}
func hostCanonical(g store.Grant, eventID string, timestamp int64, ciphertext []byte) []byte {
	h := sha256.Sum256(ciphertext)
	return []byte(fmt.Sprintf("myterm-host-event-v1\n%s\n%s\n%s\n%d\n%s", g.ID, g.RecipientID, eventID, timestamp, base64.RawURLEncoding.EncodeToString(h[:])))
}
func notificationPayload(grant, recipient, event string, timestamp int64, ciphertext string) ([]byte, error) {
	payload, err := json.Marshal(map[string]any{"aps": map[string]any{"alert": map[string]string{"title": "MyTerm", "body": "MyTerm needs attention"}, "mutable-content": 1}, "event": map[string]any{"version": 1, "grant_id": grant, "recipient_id": recipient, "event_id": event, "timestamp": timestamp, "ciphertext": ciphertext}})
	if err != nil {
		return nil, err
	}
	if len(payload) > apns.MaxPayloadBytes {
		return nil, errors.New("encrypted event does not fit the 4096-byte APNs payload")
	}
	return payload, nil
}

func parseP256(encoded string) ([]byte, error) {
	b, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(b) != 65 {
		return nil, errors.New("key must be a 65-byte uncompressed P-256 point")
	}
	x, _ := elliptic.Unmarshal(elliptic.P256(), b)
	if x == nil {
		return nil, errors.New("key is not on P-256")
	}
	return b, nil
}
func verifyP256(encoded, canonical, signature []byte) bool {
	x, y := elliptic.Unmarshal(elliptic.P256(), encoded)
	if x == nil {
		return false
	}
	h := sha256.Sum256(canonical)
	return ecdsa.VerifyASN1(&ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, h[:], signature)
}
func validAPNSToken(token string) bool {
	if len(token) < 64 || len(token) > 200 || strings.ToLower(token) != token {
		return false
	}
	_, err := hex.DecodeString(token)
	return err == nil
}
func decodeBody(w http.ResponseWriter, r *http.Request, d any) bool {
	value := r.Context().Value(deviceKey).(deviceRequest)
	dec := json.NewDecoder(bytes.NewReader(value.body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(d); err != nil {
		bad(w, "invalid_json", "JSON body is invalid.")
		return false
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		bad(w, "invalid_json", "Body must contain one JSON object.")
		return false
	}
	return true
}
func decodeStrict(w http.ResponseWriter, r *http.Request, limit int64, d any) bool {
	if !strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
		writeError(w, 415, "json_required", "Content-Type must be application/json.")
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(d); err != nil {
		bad(w, "invalid_json", "JSON body is invalid.")
		return false
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		bad(w, "invalid_json", "Body must contain one JSON object.")
		return false
	}
	return true
}
func authError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrUnauthorized):
		writeError(w, 401, "unauthorized", "Authentication failed.")
	case errors.Is(err, store.ErrNotFound):
		writeError(w, 404, "not_found", "The requested record was not found.")
	case errors.Is(err, store.ErrExpired):
		writeError(w, 410, "expired", "The challenge expired.")
	case errors.Is(err, store.ErrConflict):
		writeError(w, 409, "replayed_request", "The request was already used.")
	default:
		internalError(w, err)
	}
}
func apnsError(w http.ResponseWriter, err error) {
	var e *apns.Error
	if errors.As(err, &e) && e.Unregistered {
		writeError(w, 409, "recipient_not_available", "APNs reports that the recipient is no longer registered.")
		return
	}
	writeError(w, 503, "apns_unavailable", "APNs did not accept the notification.")
}
func bad(w http.ResponseWriter, code, msg string) { writeError(w, 400, code, msg) }
func internalError(w http.ResponseWriter, err error) {
	slog.Error("push gateway request failed", "error_type", fmt.Sprintf("%T", err))
	writeError(w, 500, "internal_error", "The gateway could not complete the request.")
}
func logCleanup(err error) {
	if err != nil {
		slog.Error("push gateway cleanup failed", "error_type", fmt.Sprintf("%T", err))
	}
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": msg}})
}
func abs(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}
func hasCredentialQuery(values url.Values) bool {
	for _, name := range []string{"token", "access_token", "grant_token", "device_session_token"} {
		if values.Has(name) {
			return true
		}
	}
	return false
}

type ipLimiter struct {
	mu      sync.Mutex
	entries map[string]*limiterEntry
	rate    rate.Limit
	burst   int
	now     func() time.Time
}
type limiterEntry struct {
	limiter  *rate.Limiter
	lastSeen time.Time
}

const maximumLimiterEntries = 4096

func newIPLimiter(r rate.Limit, b int, n func() time.Time) *ipLimiter {
	return &ipLimiter{entries: map[string]*limiterEntry{}, rate: r, burst: b, now: n}
}
func (l *ipLimiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	entry := l.entries[ip]
	if entry == nil {
		if len(l.entries) >= maximumLimiterEntries {
			for key, candidate := range l.entries {
				if now.Sub(candidate.lastSeen) > time.Hour {
					delete(l.entries, key)
				}
			}
		}
		if len(l.entries) >= maximumLimiterEntries {
			return false
		}
		entry = &limiterEntry{limiter: rate.NewLimiter(l.rate, l.burst)}
		l.entries[ip] = entry
	}
	entry.lastSeen = now
	return entry.limiter.AllowN(now, 1)
}
func (s *Server) limit(l *ipLimiter) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			host, _, err := net.SplitHostPort(r.RemoteAddr)
			if err != nil {
				host = r.RemoteAddr
			}
			if !l.allow(host) {
				writeError(w, 429, "rate_limited", "Too many requests.")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
