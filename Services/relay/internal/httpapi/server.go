package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/google/uuid"
	"golang.org/x/time/rate"

	"github.com/gordonbeeming/myterm/relay/internal/auth"
	"github.com/gordonbeeming/myterm/relay/internal/config"
	"github.com/gordonbeeming/myterm/relay/internal/store"
	"github.com/gordonbeeming/myterm/relay/internal/transport"
)

const ceremonyCookie = "__Host-myterm_relay_ceremony"

type Server struct {
	config      config.Config
	store       *store.Store
	auth        *auth.Manager
	hub         *transport.Hub
	now         func() time.Time
	authLimiter *ipLimiter
}

type contextKey int

const deviceContextKey contextKey = iota

type oauthBrowserRequest struct {
	RedirectURI         string `json:"redirect_uri"`
	State               string `json:"state"`
	CodeChallenge       string `json:"code_challenge"`
	CodeChallengeMethod string `json:"code_challenge_method"`
	DeviceName          string `json:"device_name"`
	DeviceKind          string `json:"device_kind"`
	BootstrapToken      string `json:"bootstrap_token,omitempty"`
	OwnerName           string `json:"owner_name,omitempty"`
	DisplayName         string `json:"display_name,omitempty"`
}

type tokenRequest struct {
	GrantType    string `json:"grant_type"`
	Code         string `json:"code"`
	CodeVerifier string `json:"code_verifier"`
	RedirectURI  string `json:"redirect_uri"`
	RefreshToken string `json:"refresh_token"`
}

type tokenResponse struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int64  `json:"expires_in"`
	RefreshToken string `json:"refresh_token"`
	DeviceID     string `json:"device_id"`
	AccountID    string `json:"account_id"`
}

type hostResponse struct {
	Host hostJSON `json:"host"`
}

type hostJSON struct {
	HostID          string `json:"host_id"`
	Name            string `json:"name"`
	PublicKey       string `json:"public_key"`
	TransportOnline bool   `json:"transport_online"`
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

func New(cfg config.Config, storage *store.Store, hub *transport.Hub) (*Server, error) {
	authManager, err := auth.New(cfg, storage)
	if err != nil {
		return nil, err
	}
	now := time.Now
	return &Server{
		config: cfg, store: storage, auth: authManager, hub: hub, now: now,
		authLimiter: newIPLimiter(rate.Every(6*time.Second), 10, now),
	}, nil
}

func (s *Server) Handler() http.Handler {
	router := chi.NewRouter()
	router.Use(middleware.RequestID)
	router.Use(s.securityHeaders)
	router.Use(s.recoverer)
	router.Get("/healthz", s.health)
	router.With(s.authRateLimit, s.requirePublicHost).Get("/auth/register", s.browserRegister)
	router.With(s.authRateLimit, s.requirePublicHost).Get("/auth/login", s.browserLogin)
	router.With(s.authRateLimit, s.requirePublicHost).Post("/v1/webauthn/register/options", s.registrationOptions)
	router.With(s.authRateLimit, s.requirePublicHost).Post("/v1/webauthn/register/finish", s.registrationFinish)
	router.With(s.authRateLimit, s.requirePublicHost).Post("/v1/webauthn/login/options", s.loginOptions)
	router.With(s.authRateLimit, s.requirePublicHost).Post("/v1/webauthn/login/finish", s.loginFinish)
	router.With(s.authRateLimit).Post("/v1/oauth/token", s.exchangeToken)
	router.With(s.authRateLimit).Post("/v1/oauth/revoke", s.revokeToken)
	router.Group(func(protected chi.Router) {
		protected.Use(s.authenticate)
		protected.Get("/v1/hosts", s.listHosts)
		protected.Put("/v1/hosts/{hostID}", s.putHost)
		protected.Delete("/v1/hosts/{hostID}", s.deleteHost)
		protected.Delete("/v1/hosts/{hostID}/connections/{connectionID}", s.disconnectClient)
		protected.Get("/v1/devices", s.listDevices)
		protected.Delete("/v1/devices/{deviceID}", s.deleteDevice)
		protected.Get("/v1/transport/ws", s.webSocket)
	})
	return router
}

func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Permissions-Policy", "publickey-credentials-create=(self), publickey-credentials-get=(self)")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) requirePublicHost(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.EqualFold(r.Host, s.config.PublicURL.Host) {
			writeError(w, http.StatusMisdirectedRequest, "wrong_origin", "Use the relay's configured public HTTPS origin for passkey authentication.")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recovered := recover(); recovered != nil {
				slog.Error("request handler panic", "request_id", middleware.GetReqID(r.Context()))
				writeError(w, http.StatusInternalServerError, "internal_error", "The relay could not complete the request.")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) browserRegister(w http.ResponseWriter, r *http.Request) {
	s.renderAuthPage(w, r, "register")
}

func (s *Server) browserLogin(w http.ResponseWriter, r *http.Request) {
	s.renderAuthPage(w, r, "login")
}

func (s *Server) renderAuthPage(w http.ResponseWriter, r *http.Request, mode string) {
	if _, err := auth.ValidateOAuthContext(r.URL.Query()); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	nonce, err := store.NewToken(18)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "Could not prepare the authentication page.")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'nonce-"+nonce+"'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	data := struct{ Nonce, Mode string }{Nonce: nonce, Mode: mode}
	if err := authPage.Execute(w, data); err != nil {
		slog.Error("render authentication page", "request_id", middleware.GetReqID(r.Context()))
	}
}

func (s *Server) registrationOptions(w http.ResponseWriter, r *http.Request) {
	var request oauthBrowserRequest
	if !decodeJSON(w, r, 16<<10, &request) {
		return
	}
	oauthContext, err := request.oauthContext()
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	if request.BootstrapToken == "" {
		writeError(w, http.StatusUnauthorized, "invalid_bootstrap", "The bootstrap token is missing or invalid.")
		return
	}
	options, ceremonyID, err := s.auth.BeginRegistration(r.Context(), oauthContext, request.BootstrapToken, request.OwnerName, request.DisplayName)
	if err != nil {
		s.authError(w, err)
		return
	}
	s.setCeremonyCookie(w, ceremonyID)
	writeJSON(w, http.StatusOK, options)
}

func (s *Server) registrationFinish(w http.ResponseWriter, r *http.Request) {
	s.finishCeremony(w, r, "register")
}

func (s *Server) loginOptions(w http.ResponseWriter, r *http.Request) {
	var request oauthBrowserRequest
	if !decodeJSON(w, r, 16<<10, &request) {
		return
	}
	oauthContext, err := request.oauthContext()
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	options, ceremonyID, err := s.auth.BeginLogin(r.Context(), oauthContext)
	if err != nil {
		s.authError(w, err)
		return
	}
	s.setCeremonyCookie(w, ceremonyID)
	writeJSON(w, http.StatusOK, options)
}

func (s *Server) loginFinish(w http.ResponseWriter, r *http.Request) {
	s.finishCeremony(w, r, "login")
}

func (s *Server) finishCeremony(w http.ResponseWriter, r *http.Request, kind string) {
	if !strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
		writeError(w, http.StatusUnsupportedMediaType, "json_required", "Content-Type must be application/json.")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 256<<10)
	cookie, err := r.Cookie(ceremonyCookie)
	if err != nil || cookie.Value == "" {
		writeError(w, http.StatusUnauthorized, "invalid_ceremony", "The authentication ceremony is missing or expired.")
		return
	}
	http.SetCookie(w, &http.Cookie{Name: ceremonyCookie, Value: "", Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: -1})
	var code, state string
	if kind == "register" {
		var result auth.RegistrationResult
		result, err = s.auth.FinishRegistration(r.Context(), cookie.Value, r)
		code, state = result.Code, result.State
		for _, deviceID := range result.RevokedDeviceIDs {
			s.hub.DisconnectDevice(deviceID)
		}
	} else {
		code, state, err = s.auth.FinishLogin(r.Context(), cookie.Value, r)
	}
	if err != nil {
		s.authError(w, err)
		return
	}
	// The browser retains its validated callback in the page URL; finish returns only values that are safe to append there.
	writeJSON(w, http.StatusOK, map[string]string{"code": code, "state": state})
}

func (s *Server) listDevices(w http.ResponseWriter, r *http.Request) {
	device := deviceFromContext(r.Context())
	devices, err := s.store.ListDevices(r.Context(), device.OwnerID)
	if err != nil {
		s.internalError(w)
		return
	}
	if devices == nil {
		devices = []store.DeviceSummary{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devices})
}
func (s *Server) deleteDevice(w http.ResponseWriter, r *http.Request) {
	device := deviceFromContext(r.Context())
	deviceID := chi.URLParam(r, "deviceID")
	if _, err := uuid.Parse(deviceID); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_device_id", "device_id must be a UUID.")
		return
	}
	if err := s.store.RevokeDevice(r.Context(), device.OwnerID, deviceID, s.now()); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "device_not_found", "The device was not found.")
		} else {
			s.internalError(w)
		}
		return
	}
	s.hub.DisconnectDevice(deviceID)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) disconnectClient(w http.ResponseWriter, r *http.Request) {
	device := deviceFromContext(r.Context())
	if device.Kind != "host" {
		writeError(w, http.StatusForbidden, "host_device_required", "A host device token is required.")
		return
	}
	hostID := chi.URLParam(r, "hostID")
	if _, err := s.store.HostForDevice(r.Context(), device.OwnerID, hostID, device.ID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusForbidden, "host_device_mismatch", "The host registration belongs to another device.")
		} else {
			s.internalError(w)
		}
		return
	}
	if err := s.hub.DisconnectClient(hostID, chi.URLParam(r, "connectionID")); err != nil {
		if errors.Is(err, transport.ErrWrongHost) || errors.Is(err, transport.ErrWrongRole) {
			writeError(w, http.StatusForbidden, "connection_scope_mismatch", "The connection does not belong to this host client scope.")
		} else if errors.Is(err, transport.ErrInvalidDestination) {
			writeError(w, http.StatusBadRequest, "invalid_connection_id", "connection_id must be a UUID.")
		} else {
			s.internalError(w)
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) exchangeToken(w http.ResponseWriter, r *http.Request) {
	var request tokenRequest
	if !decodeJSON(w, r, 16<<10, &request) {
		return
	}
	now := s.now()
	access, err := store.NewToken(32)
	if err != nil {
		s.internalError(w)
		return
	}
	refresh, err := store.NewToken(48)
	if err != nil {
		s.internalError(w)
		return
	}
	accessExpiry := now.Add(s.config.AccessTokenTTL)
	refreshExpiry := now.Add(s.config.RefreshTokenTTL)
	var device store.Device
	switch request.GrantType {
	case "authorization_code":
		var challenge string
		challenge, err = auth.PKCES256(request.CodeVerifier)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_grant", err.Error())
			return
		}
		if _, ok := auth.AllowedRedirects[request.RedirectURI]; !ok {
			writeError(w, http.StatusBadRequest, "invalid_grant", "redirect_uri is not allowed.")
			return
		}
		device, err = s.store.ExchangeAuthCode(r.Context(), request.Code, request.RedirectURI, challenge, now)
		if err == nil {
			err = s.store.CreateDeviceTokens(r.Context(), device, access, refresh, accessExpiry, refreshExpiry, now)
		}
	case "refresh_token":
		device, err = s.store.RotateRefresh(r.Context(), request.RefreshToken, refresh, access, accessExpiry, refreshExpiry, now)
	default:
		writeError(w, http.StatusBadRequest, "unsupported_grant_type", "grant_type must be authorization_code or refresh_token.")
		return
	}
	if err != nil {
		if device.ID != "" {
			s.hub.DisconnectDevice(device.ID)
		}
		if errors.Is(err, store.ErrUnauthorized) || errors.Is(err, store.ErrExpired) || errors.Is(err, store.ErrConsumed) {
			writeError(w, http.StatusUnauthorized, "invalid_grant", "The authorization grant is invalid or expired.")
		} else {
			s.internalError(w)
		}
		return
	}
	writeJSON(w, http.StatusOK, tokenResponse{AccessToken: access, TokenType: "Bearer", ExpiresIn: int64(s.config.AccessTokenTTL.Seconds()), RefreshToken: refresh, DeviceID: device.ID, AccountID: device.OwnerID})
}

func (s *Server) revokeToken(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Token string `json:"token"`
	}
	if !decodeJSON(w, r, 8<<10, &request) {
		return
	}
	if request.Token != "" {
		deviceID, err := s.store.RevokeToken(r.Context(), request.Token, s.now())
		if err != nil {
			s.internalError(w)
			return
		}
		if deviceID != "" {
			s.hub.DisconnectDevice(deviceID)
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Has("access_token") || r.URL.Query().Has("token") {
			writeError(w, http.StatusBadRequest, "token_in_url", "Bearer tokens are accepted only in the Authorization header.")
			return
		}
		header := r.Header.Get("Authorization")
		if len(header) < 8 || !strings.EqualFold(header[:7], "Bearer ") || strings.ContainsAny(header[7:], " \t\r\n") {
			writeError(w, http.StatusUnauthorized, "unauthorized", "A bearer access token is required.")
			return
		}
		device, err := s.store.AuthenticateAccess(r.Context(), header[7:], s.now())
		if err != nil {
			if errors.Is(err, store.ErrUnauthorized) {
				writeError(w, http.StatusUnauthorized, "unauthorized", "The access token is invalid or expired.")
			} else {
				s.internalError(w)
			}
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), deviceContextKey, device)))
	})
}

func (s *Server) listHosts(w http.ResponseWriter, r *http.Request) {
	device := deviceFromContext(r.Context())
	hosts, err := s.store.ListHosts(r.Context(), device.OwnerID)
	if err != nil {
		s.internalError(w)
		return
	}
	response := make([]hostJSON, 0, len(hosts))
	for _, host := range hosts {
		response = append(response, s.hostJSON(host))
	}
	writeJSON(w, http.StatusOK, map[string]any{"hosts": response})
}

func (s *Server) putHost(w http.ResponseWriter, r *http.Request) {
	device := deviceFromContext(r.Context())
	if device.Kind != "host" {
		writeError(w, http.StatusForbidden, "host_device_required", "A host device token is required.")
		return
	}
	hostID := chi.URLParam(r, "hostID")
	if _, err := uuid.Parse(hostID); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_host_id", "host_id must be a UUID persisted by the Mac installation.")
		return
	}
	var request struct {
		Name      string `json:"name"`
		PublicKey string `json:"public_key"`
	}
	if !decodeJSON(w, r, 16<<10, &request) {
		return
	}
	request.Name = strings.TrimSpace(request.Name)
	if len(request.Name) < 1 || len(request.Name) > 100 {
		writeError(w, http.StatusBadRequest, "invalid_name", "name must contain 1 through 100 characters.")
		return
	}
	publicKey, err := base64.RawURLEncoding.DecodeString(request.PublicKey)
	if err != nil || len(publicKey) < 32 || len(publicKey) > 512 {
		writeError(w, http.StatusBadRequest, "invalid_public_key", "public_key must be 32 through 512 bytes encoded as unpadded base64url.")
		return
	}
	host, err := s.store.UpsertHost(r.Context(), store.Host{ID: hostID, OwnerID: device.OwnerID, DeviceID: device.ID, Name: request.Name}, publicKey, s.now())
	if err != nil {
		s.internalError(w)
		return
	}
	writeJSON(w, http.StatusOK, hostResponse{Host: s.hostJSON(host)})
}

func (s *Server) deleteHost(w http.ResponseWriter, r *http.Request) {
	device := deviceFromContext(r.Context())
	hostID := chi.URLParam(r, "hostID")
	if _, err := s.store.HostForDevice(r.Context(), device.OwnerID, hostID, device.ID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "host_not_found", "The host registration was not found.")
		} else {
			s.internalError(w)
		}
		return
	}
	if err := s.store.DeleteHost(r.Context(), device.OwnerID, hostID); err != nil {
		s.internalError(w)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) webSocket(w http.ResponseWriter, r *http.Request) {
	device := deviceFromContext(r.Context())
	hostID, role := r.URL.Query().Get("host_id"), r.URL.Query().Get("role")
	if role != "host" && role != "client" {
		writeError(w, http.StatusBadRequest, "invalid_role", "role must be host or client.")
		return
	}
	if (role == "host" && device.Kind != "host") || (role == "client" && device.Kind != "client") {
		writeError(w, http.StatusForbidden, "invalid_device_role", "The device token cannot use the requested transport role.")
		return
	}
	if _, err := uuid.Parse(hostID); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_host_id", "host_id must be a UUID.")
		return
	}
	host, err := s.store.HostForOwner(r.Context(), device.OwnerID, hostID)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "host_not_found", "The host registration was not found.")
		} else {
			s.internalError(w)
		}
		return
	}
	if role == "host" && host.DeviceID != device.ID {
		writeError(w, http.StatusForbidden, "host_device_mismatch", "The host registration belongs to another device login.")
		return
	}
	if err := s.hub.ServeWebSocket(w, r, device, host, role); err != nil {
		slog.Debug("transport connection ended", "host_id", hostID, "role", role, "request_id", middleware.GetReqID(r.Context()))
	}
}

func (s *Server) hostJSON(host store.Host) hostJSON {
	return hostJSON{HostID: host.ID, Name: host.Name, PublicKey: host.PublicKey, TransportOnline: s.hub.HostOnline(host.ID)}
}

func (s *Server) setCeremonyCookie(w http.ResponseWriter, value string) {
	http.SetCookie(w, &http.Cookie{Name: ceremonyCookie, Value: value, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: int(s.config.CeremonyTTL.Seconds())})
}

func (s *Server) authError(w http.ResponseWriter, err error) {
	if errors.Is(err, store.ErrOwnerExists) {
		writeError(w, http.StatusConflict, "owner_exists", "The owner account is already registered.")
		return
	}
	if errors.Is(err, store.ErrOwnerMissing) {
		writeError(w, http.StatusPreconditionRequired, "owner_missing", "Run the bootstrap command before signing in.")
		return
	}
	if errors.Is(err, store.ErrUnauthorized) || errors.Is(err, store.ErrExpired) || errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "authentication_failed", "The authentication ceremony is invalid or expired.")
		return
	}
	if strings.Contains(err.Error(), "verify ") {
		writeError(w, http.StatusUnauthorized, "webauthn_verification_failed", "The passkey response could not be verified.")
		return
	}
	slog.Error("authentication operation failed", "error_type", fmt.Sprintf("%T", err))
	s.internalError(w)
}

func (s *Server) internalError(w http.ResponseWriter) {
	writeError(w, http.StatusInternalServerError, "internal_error", "The relay could not complete the request.")
}

func (s *Server) authRateLimit(next http.Handler) http.Handler {
	return s.rateLimit(s.authLimiter, next)
}

func (s *Server) rateLimit(limiter *ipLimiter, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !limiter.Allow(remoteIP(r.RemoteAddr)) {
			w.Header().Set("Retry-After", "10")
			writeError(w, http.StatusTooManyRequests, "rate_limited", "Too many requests. Try again later.")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func newIPLimiter(limit rate.Limit, burst int, now func() time.Time) *ipLimiter {
	return &ipLimiter{entries: make(map[string]*limiterEntry), rate: limit, burst: burst, now: now}
}

func (l *ipLimiter) Allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	entry := l.entries[ip]
	if entry == nil {
		entry = &limiterEntry{limiter: rate.NewLimiter(l.rate, l.burst)}
		l.entries[ip] = entry
	}
	entry.lastSeen = now
	if len(l.entries) > 1024 {
		for key, candidate := range l.entries {
			if now.Sub(candidate.lastSeen) > time.Hour {
				delete(l.entries, key)
			}
		}
	}
	return entry.limiter.AllowN(now, 1)
}

func remoteIP(address string) string {
	host, _, err := net.SplitHostPort(address)
	if err == nil {
		return host
	}
	return address
}

func (r oauthBrowserRequest) oauthContext() (store.OAuthContext, error) {
	values := make(url.Values)
	values.Set("redirect_uri", r.RedirectURI)
	values.Set("state", r.State)
	values.Set("code_challenge", r.CodeChallenge)
	values.Set("code_challenge_method", r.CodeChallengeMethod)
	values.Set("device_name", r.DeviceName)
	values.Set("device_kind", r.DeviceKind)
	return auth.ValidateOAuthContext(values)
}

func deviceFromContext(ctx context.Context) store.Device {
	device, _ := ctx.Value(deviceContextKey).(store.Device)
	return device
}

func decodeJSON(w http.ResponseWriter, r *http.Request, limit int64, destination any) bool {
	if !strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
		writeError(w, http.StatusUnsupportedMediaType, "json_required", "Content-Type must be application/json.")
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "The JSON request body is invalid.")
		return false
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "invalid_json", "The request body must contain one JSON object.")
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}

var authPage = template.Must(template.New("auth").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MyTerm relay</title><style>
:root{color-scheme:light dark;font:16px system-ui,sans-serif}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111827;color:#f9fafb}.card{width:min(30rem,calc(100% - 2rem));box-sizing:border-box;padding:2rem;border:1px solid #374151;border-radius:1rem;background:#1f2937}h1{margin-top:0}label{display:block;margin:.9rem 0 .3rem}input,button{box-sizing:border-box;width:100%;font:inherit;padding:.75rem;border-radius:.5rem}button{margin-top:1rem;border:0;background:#38bdf8;color:#082f49;font-weight:700}button:disabled{opacity:.5}.error{color:#fca5a5;white-space:pre-wrap}</style></head>
<body><main class="card"><h1>{{if eq .Mode "register"}}Register owner passkey{{else}}Sign in with a passkey{{end}}</h1>
{{if eq .Mode "register"}}<label for="owner">Account name</label><input id="owner" autocomplete="username" value="owner" maxlength="100"><label for="display">Display name</label><input id="display" autocomplete="name" value="MyTerm owner" maxlength="100">{{end}}
<button id="continue">Continue</button><p id="status" role="status"></p><p id="error" class="error" role="alert"></p></main>
<script nonce="{{.Nonce}}">
const mode={{.Mode}};const button=document.querySelector('#continue');const status=document.querySelector('#status');const error=document.querySelector('#error');
const q=new URLSearchParams(location.search);const fragment=new URLSearchParams(location.hash.slice(1));history.replaceState(null,'',location.pathname+location.search);
const payload=()=>({redirect_uri:q.get('redirect_uri'),state:q.get('state'),code_challenge:q.get('code_challenge'),code_challenge_method:q.get('code_challenge_method'),device_name:q.get('device_name'),device_kind:q.get('device_kind'),...(mode==='register'?{bootstrap_token:fragment.get('enrollment_token')||fragment.get('bootstrap_token'),owner_name:document.querySelector('#owner').value,display_name:document.querySelector('#display').value}:{})});
button.addEventListener('click',async()=>{button.disabled=true;error.textContent='';status.textContent='Waiting for your passkey…';try{const optionsResponse=await fetch('/v1/webauthn/'+mode+'/options',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload()),credentials:'same-origin'});const options=await optionsResponse.json();if(!optionsResponse.ok)throw new Error(options.error?.message||'Could not begin authentication.');const publicKey=mode==='register'?PublicKeyCredential.parseCreationOptionsFromJSON(options.publicKey):PublicKeyCredential.parseRequestOptionsFromJSON(options.publicKey);const credential=mode==='register'?await navigator.credentials.create({publicKey}):await navigator.credentials.get({publicKey});const finishResponse=await fetch('/v1/webauthn/'+mode+'/finish',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(credential.toJSON()),credentials:'same-origin'});const result=await finishResponse.json();if(!finishResponse.ok)throw new Error(result.error?.message||'Authentication failed.');const callback=new URL(q.get('redirect_uri'));callback.searchParams.set('code',result.code);callback.searchParams.set('state',result.state);location.assign(callback.toString());}catch(e){status.textContent='';error.textContent=e instanceof Error?e.message:'Authentication failed.';button.disabled=false;}});
</script></body></html>`))
