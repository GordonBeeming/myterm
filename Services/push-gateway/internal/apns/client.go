package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/gordonbeeming/myterm/push-gateway/internal/config"
)

const MaxPayloadBytes = 4096

type Sender interface {
	Send(context.Context, string, []byte, string) (string, error)
}
type Error struct {
	Status       int
	Reason       string
	Unregistered bool
}

func (e *Error) Error() string { return fmt.Sprintf("APNs status %d: %s", e.Status, e.Reason) }

type Client struct {
	httpClient                     *http.Client
	key                            *ecdsa.PrivateKey
	teamID, keyID, topic, endpoint string
	mu                             sync.Mutex
	providerToken                  string
	providerCreated                time.Time
	now                            func() time.Time
	sleep                          func(context.Context, time.Duration) error
}

func New(cfg config.Config) (*Client, error) {
	encoded, err := os.ReadFile(cfg.APNSKeyFile)
	if err != nil {
		return nil, fmt.Errorf("read APNs signing key: %w", err)
	}
	block, _ := pem.Decode(encoded)
	if block == nil {
		return nil, errors.New("APNs key file is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse APNs signing key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("APNs signing key is not P-256 ECDSA")
	}
	endpoint := "https://api.push.apple.com"
	if cfg.APNSEnvironment == "sandbox" {
		endpoint = "https://api.sandbox.push.apple.com"
	}
	return newClient(cfg, key, &http.Client{Transport: &http.Transport{ForceAttemptHTTP2: true}, Timeout: 15 * time.Second}, endpoint), nil
}

func newClient(cfg config.Config, key *ecdsa.PrivateKey, client *http.Client, endpoint string) *Client {
	return &Client{httpClient: client, key: key, teamID: cfg.TeamID, keyID: cfg.APNSKeyID, topic: cfg.APNSTopic, endpoint: endpoint, now: time.Now, sleep: func(ctx context.Context, d time.Duration) error {
		timer := time.NewTimer(d)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
			return nil
		}
	}}
}

func (c *Client) Send(ctx context.Context, deviceToken string, payload []byte, collapseID string) (string, error) {
	if len(payload) > MaxPayloadBytes {
		return "", errors.New("APNs payload exceeds 4096 bytes")
	}
	if len(collapseID) > 64 {
		return "", errors.New("APNs collapse identifier exceeds 64 bytes")
	}
	for attempt := 0; attempt < 3; attempt++ {
		providerToken, err := c.token()
		if err != nil {
			return "", err
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint+"/3/device/"+deviceToken, bytes.NewReader(payload))
		if err != nil {
			return "", err
		}
		request.Header.Set("authorization", "bearer "+providerToken)
		request.Header.Set("apns-topic", c.topic)
		request.Header.Set("apns-push-type", "alert")
		request.Header.Set("apns-priority", "10")
		request.Header.Set("apns-expiration", "0")
		request.Header.Set("content-type", "application/json")
		if collapseID != "" {
			request.Header.Set("apns-collapse-id", collapseID)
		}
		response, err := c.httpClient.Do(request)
		if err != nil {
			if attempt < 2 {
				if err := c.sleep(ctx, time.Duration(attempt+1)*100*time.Millisecond); err != nil {
					return "", err
				}
				continue
			}
			return "", err
		}
		body, readErr := io.ReadAll(io.LimitReader(response.Body, 4096))
		response.Body.Close()
		if readErr != nil {
			return "", readErr
		}
		if response.StatusCode == http.StatusOK {
			return response.Header.Get("apns-id"), nil
		}
		var detail struct {
			Reason string `json:"reason"`
		}
		_ = json.Unmarshal(body, &detail)
		apnsErr := &Error{Status: response.StatusCode, Reason: detail.Reason, Unregistered: response.StatusCode == http.StatusGone}
		if (response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500) && attempt < 2 {
			delay := retryDelay(response.Header.Get("retry-after"), c.now())
			if delay > 5*time.Second {
				delay = 5 * time.Second
			}
			if err := c.sleep(ctx, delay); err != nil {
				return "", err
			}
			continue
		}
		return "", apnsErr
	}
	return "", errors.New("APNs retry loop exhausted")
}

func (c *Client) token() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.providerToken != "" && now.Sub(c.providerCreated) < 30*time.Minute {
		return c.providerToken, nil
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"iss": c.teamID, "iat": now.Unix()})
	token.Header["kid"] = c.keyID
	signed, err := token.SignedString(c.key)
	if err != nil {
		return "", err
	}
	c.providerToken = signed
	c.providerCreated = now
	return signed, nil
}

func retryDelay(value string, now time.Time) time.Duration {
	value = strings.TrimSpace(value)
	if seconds, err := strconv.Atoi(value); err == nil && seconds >= 0 {
		return time.Duration(seconds) * time.Second
	}
	if parsed, err := http.ParseTime(value); err == nil && parsed.After(now) {
		return parsed.Sub(now)
	}
	return 200 * time.Millisecond
}
