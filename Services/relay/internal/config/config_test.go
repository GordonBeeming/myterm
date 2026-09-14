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
		})
	}
}

func setCleanEnvironment(t *testing.T) {
	t.Helper()
	for _, name := range []string{"MYTERM_RELAY_PUBLIC_URL", "MYTERM_RELAY_RP_ID", "MYTERM_RELAY_RP_NAME", "MYTERM_RELAY_LISTEN", "MYTERM_RELAY_DATABASE", "MYTERM_RELAY_WS_FRAME_LIMIT", "MYTERM_RELAY_WS_QUEUE_DEPTH"} {
		t.Setenv(name, "")
	}
}
