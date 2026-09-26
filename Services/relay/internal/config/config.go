package config

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
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
	SlowReceiverGrace   time.Duration
	HeartbeatTimeout    time.Duration
	TrustedProxyCIDRs   []netip.Prefix
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
	queueDepth, err := envInt("MYTERM_RELAY_WS_QUEUE_DEPTH", 128, 1, 1024)
	if err != nil {
		return Config{}, err
	}
	// Each slot can hold a whole frame, so cap the queue by the bytes it could hold rather than
	// by slot count alone: the maximum depth against the maximum frame size is gigabytes.
	if budget := maximumQueueBytes / frameLimit; int64(queueDepth) > budget {
		if budget < 1 {
			budget = 1
		}
		queueDepth = int(budget)
	}
	slowReceiverGrace, err := envDuration("MYTERM_RELAY_WS_SLOW_RECEIVER_GRACE", 2*time.Second,
		50*time.Millisecond, 30*time.Second)
	if err != nil {
		return Config{}, err
	}
	trustedProxies, err := parseCIDRs("MYTERM_RELAY_TRUSTED_PROXY_CIDRS", envString("MYTERM_RELAY_TRUSTED_PROXY_CIDRS", "127.0.0.0/8,::1/128"))
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
		SlowReceiverGrace:   slowReceiverGrace,
		HeartbeatTimeout:    10 * time.Second,
		TrustedProxyCIDRs:   trustedProxies,
	}, nil
}

func parseCIDRs(name, value string) ([]netip.Prefix, error) {
	if strings.EqualFold(strings.TrimSpace(value), "none") {
		return nil, nil
	}
	var result []netip.Prefix
	for _, part := range strings.Split(value, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(part)
		if err != nil {
			address, addressErr := netip.ParseAddr(part)
			if addressErr != nil {
				return nil, fmt.Errorf("%s contains invalid address or CIDR %q", name, part)
			}
			prefix = netip.PrefixFrom(address, address.BitLen())
		}
		prefix = prefix.Masked()
		bits := prefix.Bits()
		if (prefix.Addr().Is4() && bits < 8) || (prefix.Addr().Is6() && bits < 24) {
			return nil, fmt.Errorf("%s contains dangerously broad CIDR %q", name, part)
		}
		result = append(result, prefix)
	}
	return result, nil
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

func envDuration(name string, fallback, min, max time.Duration) (time.Duration, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return fallback, nil
	}
	value, err := time.ParseDuration(raw)
	if err != nil || value < min || value > max {
		return 0, fmt.Errorf("%s must be a duration from %s through %s", name, min, max)
	}
	return value, nil
}

const maximumQueueBytes int64 = 64 * 1024 * 1024
