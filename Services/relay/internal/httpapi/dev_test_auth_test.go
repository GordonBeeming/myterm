package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	relayauth "github.com/gordonbeeming/myterm/relay/internal/auth"
	"github.com/gordonbeeming/myterm/relay/internal/store"
	"github.com/gordonbeeming/myterm/relay/internal/transport"
)

const devTestSecret = "c29tZS1kZXRlcm1pbmlzdGljLWZpeHR1cmUtc2VjcmV0LTMyaQ"

func newDevTestAPI(t *testing.T, enrolled bool) *Server {
	t.Helper()
	original, _, storage, _ := newWebSocketTestServer(t)
	cfg := original.config
	cfg.PublicURL, _ = url.Parse("https://myterm-relay-dev.gordonbeeming.dev")
	cfg.RPID = cfg.PublicURL.Hostname()
	cfg.DevTestAuthEnabled = true
	cfg.DevTestAuthToken = devTestSecret
	if !enrolled {
		var err error
		storage, err = store.Open(context.Background(), "file:"+strings.ReplaceAll(t.Name(), "/", "-")+"-empty?mode=memory&cache=shared")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { storage.Close() })
	}
	api, err := New(cfg, storage, transport.New(cfg))
	if err != nil {
		t.Fatal(err)
	}
	return api
}

func devOAuth(t *testing.T) map[string]any {
	t.Helper()
	challenge, err := relayauth.PKCES256(strings.Repeat("v", 43))
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{"redirect_uri": "myterm-companion-dev://auth/callback", "state": base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32)), "code_challenge": challenge, "code_challenge_method": "S256", "device_name": "Simulator", "device_kind": "client"}
}

func devRequest(t *testing.T, api *Server, path, secret string, body any) *httptest.ResponseRecorder {
	t.Helper()
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, api.config.PublicURL.String()+path, bytes.NewReader(data))
	request.Header.Set("Content-Type", "application/json")
	if secret != "" {
		request.Header.Set("Authorization", "Bearer "+secret)
	}
	response := httptest.NewRecorder()
	api.Handler().ServeHTTP(response, request)
	return response
}

func TestDevelopmentTestAuthDefaultDisabledAndConstructorsRejectProduction(t *testing.T) {
	api, _, _, _ := newWebSocketTestServer(t)
	if response := devRequest(t, api, "/v1/dev-test/authorize", devTestSecret, devOAuth(t)); response.Code != http.StatusNotFound {
		t.Fatalf("disabled endpoint status %d", response.Code)
	}
	cfg := api.config
	cfg.DevTestAuthEnabled = true
	cfg.DevTestAuthToken = devTestSecret
	if _, err := New(cfg, api.store, api.hub); err == nil {
		t.Fatal("server constructor enabled production endpoint")
	}
	if _, err := relayauth.New(cfg, api.store); err == nil {
		t.Fatal("auth constructor accepted production test authentication")
	}
}

func TestDevelopmentTestAuthRejectsUntrustedAndMalformedRequests(t *testing.T) {
	for _, test := range []struct {
		name   string
		edit   func(map[string]any)
		secret string
		status int
	}{
		{"missing secret", nil, "", http.StatusUnauthorized},
		{"wrong secret", nil, "wrong-secret", http.StatusUnauthorized},
		{"production redirect", func(v map[string]any) { v["redirect_uri"] = "myterm-companion://auth/callback" }, devTestSecret, http.StatusBadRequest},
		{"redirect prefix", func(v map[string]any) { v["redirect_uri"] = "myterm-companion-dev://auth/callback/extra" }, devTestSecret, http.StatusBadRequest},
		{"host role", func(v map[string]any) { v["device_kind"] = "host" }, devTestSecret, http.StatusBadRequest},
		{"invalid state", func(v map[string]any) { v["state"] = "weak" }, devTestSecret, http.StatusBadRequest},
		{"invalid PKCE", func(v map[string]any) { v["code_challenge"] = "weak" }, devTestSecret, http.StatusBadRequest},
		{"plain PKCE", func(v map[string]any) { v["code_challenge_method"] = "plain" }, devTestSecret, http.StatusBadRequest},
		{"unknown field", func(v map[string]any) { v["token"] = "secret-in-body" }, devTestSecret, http.StatusBadRequest},
		{"bootstrap fields", func(v map[string]any) { v["owner_name"] = "new owner" }, devTestSecret, http.StatusBadRequest},
	} {
		t.Run(test.name, func(t *testing.T) {
			api := newDevTestAPI(t, true)
			values := devOAuth(t)
			if test.edit != nil {
				test.edit(values)
			}
			response := devRequest(t, api, "/v1/dev-test/authorize", test.secret, values)
			if response.Code != test.status {
				t.Fatalf("status %d, expected %d: %s", response.Code, test.status, response.Body.String())
			}
			if strings.Contains(response.Body.String(), devTestSecret) {
				t.Fatal("response leaked test credential")
			}
			if response.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("authorization response was cacheable")
			}
		})
	}
}

func TestDevelopmentTestAuthRequiresEnrolledOwner(t *testing.T) {
	api := newDevTestAPI(t, false)
	if response := devRequest(t, api, "/v1/dev-test/authorize", devTestSecret, devOAuth(t)); response.Code != http.StatusConflict {
		t.Fatalf("unenrolled owner status %d", response.Code)
	}
	if _, err := api.store.Owner(context.Background()); err != store.ErrOwnerMissing {
		t.Fatalf("test auth created an owner: %v", err)
	}
}

func TestDevelopmentTestAuthRateLimitsFailedSecrets(t *testing.T) {
	api := newDevTestAPI(t, true)
	for i := 0; i < 10; i++ {
		if response := devRequest(t, api, "/v1/dev-test/authorize", "wrong", devOAuth(t)); response.Code != http.StatusUnauthorized {
			t.Fatalf("attempt %d status %d", i, response.Code)
		}
	}
	if response := devRequest(t, api, "/v1/dev-test/authorize", devTestSecret, devOAuth(t)); response.Code != http.StatusTooManyRequests {
		t.Fatalf("rate limit status %d", response.Code)
	}
}

func TestDevelopmentTestAuthRejectsWrongHostAndInvalidBodies(t *testing.T) {
	for _, scenario := range []string{"wrong host", "oversized", "trailing JSON", "missing bearer"} {
		t.Run(scenario, func(t *testing.T) {
			api := newDevTestAPI(t, true)
			body, err := json.Marshal(devOAuth(t))
			if err != nil {
				t.Fatal(err)
			}
			switch scenario {
			case "oversized":
				body = []byte(strings.Repeat(" ", 17000))
			case "trailing JSON":
				body = append(body, []byte(" {}")...)
			}
			request := httptest.NewRequest(http.MethodPost, api.config.PublicURL.String()+"/v1/dev-test/authorize", bytes.NewReader(body))
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set("Authorization", "Bearer "+devTestSecret)
			expected := http.StatusBadRequest
			if scenario == "wrong host" {
				request.Host = "myterm-relay.gordonbeeming.dev"
				expected = http.StatusMisdirectedRequest
			}
			if scenario == "missing bearer" {
				request.Header.Del("Authorization")
				request.URL.RawQuery = "token=" + devTestSecret
				expected = http.StatusUnauthorized
			}
			response := httptest.NewRecorder()
			api.Handler().ServeHTTP(response, request)
			if response.Code != expected {
				t.Fatalf("status %d expected %d", response.Code, expected)
			}
		})
	}
}

func TestDevelopmentAuthorizationUsesExistingPKCEExpiryAndSingleUseExchange(t *testing.T) {
	for _, scenario := range []string{"valid", "wrong verifier", "wrong callback", "expired", "replay"} {
		t.Run(scenario, func(t *testing.T) {
			api := newDevTestAPI(t, true)
			values := devOAuth(t)
			authorized := devRequest(t, api, "/v1/dev-test/authorize", devTestSecret, values)
			if authorized.Code != http.StatusOK {
				t.Fatalf("authorize status %d: %s", authorized.Code, authorized.Body.String())
			}
			var grant struct {
				Code  string `json:"code"`
				State string `json:"state"`
			}
			if err := json.Unmarshal(authorized.Body.Bytes(), &grant); err != nil {
				t.Fatal(err)
			}
			if len(grant.Code) != 43 || grant.State != values["state"] {
				t.Fatal("authorization code or OAuth state invalid")
			}
			exchange := map[string]any{"grant_type": "authorization_code", "code": grant.Code, "code_verifier": strings.Repeat("v", 43), "redirect_uri": values["redirect_uri"]}
			if scenario == "wrong verifier" {
				exchange["code_verifier"] = strings.Repeat("w", 43)
			}
			if scenario == "wrong callback" {
				exchange["redirect_uri"] = "myterm-companion://auth/callback"
			}
			if scenario == "expired" {
				api.now = func() time.Time { return time.Now().Add(time.Hour) }
			}
			response := devRequest(t, api, "/v1/oauth/token", "", exchange)
			if scenario == "valid" || scenario == "replay" {
				if response.Code != http.StatusOK {
					t.Fatalf("valid exchange %d", response.Code)
				}
				var tokens tokenResponse
				if err := json.Unmarshal(response.Body.Bytes(), &tokens); err != nil {
					t.Fatal(err)
				}
				device, err := api.store.AuthenticateAccess(context.Background(), tokens.AccessToken, time.Now())
				if err != nil || device.Kind != "client" {
					t.Fatalf("issued device scope invalid: %v", err)
				}
				if scenario == "replay" {
					if repeat := devRequest(t, api, "/v1/oauth/token", "", exchange); repeat.Code != http.StatusUnauthorized {
						t.Fatalf("replay status %d", repeat.Code)
					}
				}
			} else if response.Code != http.StatusUnauthorized {
				t.Fatalf("bad exchange status %d", response.Code)
			}
		})
	}
}
