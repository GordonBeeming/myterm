package config

import "testing"

func TestLoadRequiresFixedHTTPSWebAuthnOrigin(t *testing.T) {
	tests := []struct {
		name      string
		publicURL string
		rpID      string
		wantError bool
	}{
		{name: "valid exact RP", publicURL: "https://relay.example.com", rpID: "relay.example.com"},
		{name: "valid parent RP", publicURL: "https://relay.example.com", rpID: "example.com"},
		{name: "plain HTTP", publicURL: "http://relay.example.com", rpID: "relay.example.com", wantError: true},
		{name: "URL path", publicURL: "https://relay.example.com/auth", rpID: "relay.example.com", wantError: true},
		{name: "URL credentials", publicURL: "https://owner:secret@relay.example.com", rpID: "relay.example.com", wantError: true},
		{name: "IP RP", publicURL: "https://192.0.2.1", rpID: "192.0.2.1", wantError: true},
		{name: "unrelated RP", publicURL: "https://relay.example.com", rpID: "attacker.example", wantError: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			setCleanEnvironment(t)
			t.Setenv("MYTERM_RELAY_PUBLIC_URL", test.publicURL)
			t.Setenv("MYTERM_RELAY_RP_ID", test.rpID)
			cfg, err := Load()
			if test.wantError && err == nil {
				t.Fatalf("Load() accepted %+v", cfg)
			}
			if !test.wantError && err != nil {
				t.Fatalf("Load() rejected valid config: %v", err)
			}
			if !test.wantError && cfg.ListenAddress != "127.0.0.1:8787" {
				t.Fatalf("unsafe default listener %q", cfg.ListenAddress)
			}
			if !test.wantError && len(cfg.TrustedProxyCIDRs) != 2 {
				t.Fatalf("trusted proxy defaults: %v", cfg.TrustedProxyCIDRs)
			}
		})
	}
}

func setCleanEnvironment(t *testing.T) {
	t.Helper()
	for _, name := range []string{"MYTERM_RELAY_PUBLIC_URL", "MYTERM_RELAY_RP_ID", "MYTERM_RELAY_RP_NAME", "MYTERM_RELAY_LISTEN", "MYTERM_RELAY_DATABASE", "MYTERM_RELAY_WS_FRAME_LIMIT", "MYTERM_RELAY_WS_QUEUE_DEPTH", "MYTERM_RELAY_TRUSTED_PROXY_CIDRS"} {
		t.Setenv(name, "")
	}
}

func TestTrustedProxyCIDRsRejectInvalidAndBroadRanges(t *testing.T) {
	for _, value := range []string{"not-a-network", "0.0.0.0/0", "::/0"} {
		if _, err := parseCIDRs("TEST", value); err == nil {
			t.Fatalf("accepted %q", value)
		}
	}
	values, err := parseCIDRs("TEST", "127.0.0.1, 172.16.0.0/12, 2606:4700::/32")
	if err != nil || len(values) != 3 {
		t.Fatalf("parse proxies: %v %v", values, err)
	}
	if values, err := parseCIDRs("TEST", "none"); err != nil || len(values) != 0 {
		t.Fatalf("none proxies: %v %v", values, err)
	}
}
