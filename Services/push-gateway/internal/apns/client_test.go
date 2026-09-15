package apns

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/gordonbeeming/myterm/push-gateway/internal/config"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestAPNSHeadersJWTEnvironmentAndRetry(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	fixed := time.Unix(1789470900, 0)
	current := fixed
	attempts := 0
	var authorizations []string
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		attempts++
		if r.URL.String() != "https://api.sandbox.push.apple.com/3/device/"+strings.Repeat("a", 64) {
			t.Errorf("endpoint %s", r.URL)
		}
		for name, want := range map[string]string{"apns-topic": "com.example.myterm", "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "0", "apns-collapse-id": "event"} {
			if got := r.Header.Get(name); got != want {
				t.Errorf("%s=%q want %q", name, got, want)
			}
		}
		authorizations = append(authorizations, r.Header.Get("authorization"))
		if attempts == 1 {
			return response(429, `{"reason":"TooManyRequests"}`, map[string]string{"retry-after": "0"}), nil
		}
		return response(200, "", map[string]string{"apns-id": "accepted-id"}), nil
	})
	c := newClient(config.Config{TeamID: "TEAM123", APNSKeyID: "KEY123", APNSTopic: "com.example.myterm"}, key, &http.Client{Transport: transport}, "https://api.sandbox.push.apple.com")
	c.now = func() time.Time { return current }
	c.sleep = func(context.Context, time.Duration) error { return nil }
	id, err := c.Send(context.Background(), strings.Repeat("a", 64), []byte(`{"aps":{}}`), "event")
	if err != nil || id != "accepted-id" || attempts != 2 {
		t.Fatalf("send id=%q attempts=%d err=%v", id, attempts, err)
	}
	if authorizations[0] != authorizations[1] {
		t.Fatal("provider JWT refreshed inside 20 minute window")
	}
	encoded := strings.TrimPrefix(authorizations[0], "bearer ")
	parsed, err := jwt.Parse(encoded, func(token *jwt.Token) (any, error) { return &key.PublicKey, nil })
	if err != nil || !parsed.Valid {
		t.Fatalf("JWT invalid: %v", err)
	}
	claims := parsed.Claims.(jwt.MapClaims)
	if claims["iss"] != "TEAM123" || parsed.Header["kid"] != "KEY123" {
		t.Fatalf("JWT claims/header: %#v %#v", claims, parsed.Header)
	}
	current = fixed.Add(31 * time.Minute)
	if _, err := c.Send(context.Background(), strings.Repeat("a", 64), []byte(`{"aps":{}}`), "event"); err != nil {
		t.Fatal(err)
	}
	if authorizations[2] == authorizations[0] {
		t.Fatal("provider JWT was not refreshed after 30 minutes")
	}
}

func TestAPNSPayloadLimitAndUnregistered(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	calls := 0
	c := newClient(config.Config{TeamID: "T", APNSKeyID: "K", APNSTopic: "topic"}, key, &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		calls++
		return response(410, `{"reason":"Unregistered"}`, nil), nil
	})}, "https://api.push.apple.com")
	if _, err := c.Send(context.Background(), strings.Repeat("a", 64), make([]byte, 4097), ""); err == nil || calls != 0 {
		t.Fatalf("oversize payload calls=%d err=%v", calls, err)
	}
	_, err := c.Send(context.Background(), strings.Repeat("a", 64), []byte(`{}`), "")
	var apnsErr *Error
	if !errors.As(err, &apnsErr) || !apnsErr.Unregistered {
		t.Fatalf("want unregistered, got %v", err)
	}
}

func response(status int, body string, headers map[string]string) *http.Response {
	h := make(http.Header)
	for k, v := range headers {
		h.Set(k, v)
	}
	return &http.Response{StatusCode: status, Header: h, Body: io.NopCloser(strings.NewReader(body))}
}
