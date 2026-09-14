package config

import (
	"errors"
	"net/url"
	"os"
	"strings"
	"time"
)

type Config struct {
	ListenAddress        string
	PublicURL            *url.URL
	DatabasePath         string
	TeamID               string
	BundleID             string
	AppAttestEnvironment string
	APNSKeyID            string
	APNSKeyFile          string
	APNSTopic            string
	APNSEnvironment      string
	ChallengeTTL         time.Duration
	DeviceSessionTTL     time.Duration
}

func Load() (Config, error) {
	publicURL, err := url.Parse(strings.TrimSpace(os.Getenv("MYTERM_PUSH_PUBLIC_URL")))
	if err != nil || publicURL.Scheme != "https" || publicURL.Host == "" || publicURL.User != nil || (publicURL.Path != "" && publicURL.Path != "/") || publicURL.RawQuery != "" || publicURL.Fragment != "" {
		return Config{}, errors.New("MYTERM_PUSH_PUBLIC_URL must be an absolute HTTPS origin")
	}
	publicURL.Path = ""
	cfg := Config{
		ListenAddress: env("MYTERM_PUSH_LISTEN", "127.0.0.1:8790"), PublicURL: publicURL,
		DatabasePath: env("MYTERM_PUSH_DATABASE", "./data/push-gateway.sqlite3"),
		TeamID:       strings.TrimSpace(os.Getenv("MYTERM_PUSH_TEAM_ID")), BundleID: strings.TrimSpace(os.Getenv("MYTERM_PUSH_BUNDLE_ID")),
		AppAttestEnvironment: env("MYTERM_PUSH_APP_ATTEST_ENVIRONMENT", "production"),
		APNSKeyID:            strings.TrimSpace(os.Getenv("MYTERM_PUSH_APNS_KEY_ID")), APNSKeyFile: strings.TrimSpace(os.Getenv("MYTERM_PUSH_APNS_KEY_FILE")),
		APNSTopic: strings.TrimSpace(os.Getenv("MYTERM_PUSH_APNS_TOPIC")), APNSEnvironment: env("MYTERM_PUSH_APNS_ENVIRONMENT", "production"),
		ChallengeTTL: 5 * time.Minute, DeviceSessionTTL: 180 * 24 * time.Hour,
	}
	if cfg.TeamID == "" || cfg.BundleID == "" || cfg.APNSKeyID == "" || cfg.APNSKeyFile == "" || cfg.APNSTopic == "" {
		return Config{}, errors.New("Team ID, bundle ID, APNs key ID, key file, and topic are required")
	}
	if cfg.APNSKeyFile[0] != '/' {
		return Config{}, errors.New("MYTERM_PUSH_APNS_KEY_FILE must be an absolute path")
	}
	if cfg.AppAttestEnvironment != "production" && cfg.AppAttestEnvironment != "development" {
		return Config{}, errors.New("App Attest environment must be production or development")
	}
	if cfg.APNSEnvironment != "production" && cfg.APNSEnvironment != "sandbox" {
		return Config{}, errors.New("APNs environment must be production or sandbox")
	}
	return cfg, nil
}

func env(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}
