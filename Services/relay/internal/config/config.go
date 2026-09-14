package config

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	ListenAddress       string
	PublicURL           *url.URL
	RPID                string
	RPDisplayName       string
	DatabasePath        string
	AccessTokenTTL      time.Duration
	RefreshTokenTTL     time.Duration
	AuthCodeTTL         time.Duration
	CeremonyTTL         time.Duration
	PairingTicketTTL    time.Duration
	WebSocketFrameLimit int64
	WebSocketQueueDepth int
	HeartbeatInterval   time.Duration
	HeartbeatTimeout    time.Duration
}

func Load() (Config, error) {
	publicURL, err := url.Parse(strings.TrimSpace(os.Getenv("MYTERM_RELAY_PUBLIC_URL")))
	if err != nil || publicURL.Scheme != "https" || publicURL.Host == "" || publicURL.User != nil || publicURL.Opaque != "" || publicURL.RawQuery != "" || publicURL.Fragment != "" {
		return Config{}, errors.New("MYTERM_RELAY_PUBLIC_URL must be an absolute HTTPS origin")
	}
	if publicURL.Path != "" && publicURL.Path != "/" {
		return Config{}, errors.New("MYTERM_RELAY_PUBLIC_URL must not contain a path")
	}
	publicURL.Path = ""

	rpID := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(os.Getenv("MYTERM_RELAY_RP_ID")), "."))
	if rpID == "" {
		rpID = publicURL.Hostname()
	}
	if net.ParseIP(rpID) != nil {
		return Config{}, errors.New("MYTERM_RELAY_RP_ID must be a DNS name; WebAuthn does not allow an IP RP ID")
	}
	hostname := strings.ToLower(strings.TrimSuffix(publicURL.Hostname(), "."))
	if rpID != hostname && !strings.HasSuffix(hostname, "."+rpID) {
		return Config{}, errors.New("MYTERM_RELAY_RP_ID must equal or be a registrable suffix of the public URL host")
	}

	frameLimit, err := envInt64("MYTERM_RELAY_WS_FRAME_LIMIT", 1<<20, 1024, 4<<20)
	if err != nil {
		return Config{}, err
	}
	queueDepth, err := envInt("MYTERM_RELAY_WS_QUEUE_DEPTH", 32, 1, 256)
	if err != nil {
		return Config{}, err
	}

	return Config{
		ListenAddress:       envString("MYTERM_RELAY_LISTEN", "127.0.0.1:8787"),
		PublicURL:           publicURL,
		RPID:                rpID,
		RPDisplayName:       envString("MYTERM_RELAY_RP_NAME", "MyTerm Relay"),
		DatabasePath:        envString("MYTERM_RELAY_DATABASE", "./data/relay.sqlite3"),
		AccessTokenTTL:      15 * time.Minute,
		RefreshTokenTTL:     30 * 24 * time.Hour,
		AuthCodeTTL:         2 * time.Minute,
		CeremonyTTL:         5 * time.Minute,
		PairingTicketTTL:    5 * time.Minute,
		WebSocketFrameLimit: frameLimit,
		WebSocketQueueDepth: queueDepth,
		HeartbeatInterval:   20 * time.Second,
		HeartbeatTimeout:    10 * time.Second,
	}, nil
}

func envString(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func envInt(name string, fallback, min, max int) (int, error) {
	value, err := envInt64(name, int64(fallback), int64(min), int64(max))
	return int(value), err
}

func envInt64(name string, fallback, min, max int64) (int64, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return fallback, nil
	}
	value, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || value < min || value > max {
		return 0, fmt.Errorf("%s must be an integer from %d through %d", name, min, max)
	}
	return value, nil
}
