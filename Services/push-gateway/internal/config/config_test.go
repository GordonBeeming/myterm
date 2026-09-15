package config

import "testing"

func TestLoadFailsClosedForOriginCredentialsAndEnvironments(t *testing.T) {
	tests := []struct {
		name, url, attest, apns string
		valid                   bool
	}{{"valid", "https://push.example.com", "production", "production", true}, {"sandbox development", "https://push.example.com", "development", "sandbox", true}, {"http", "http://push.example.com", "production", "production", false}, {"path", "https://push.example.com/api", "production", "production", false}, {"bad attest", "https://push.example.com", "disabled", "production", false}, {"bad APNs", "https://push.example.com", "production", "disabled", false}}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			for _, name := range []string{"MYTERM_PUSH_PUBLIC_URL", "MYTERM_PUSH_LISTEN", "MYTERM_PUSH_DATABASE", "MYTERM_PUSH_TEAM_ID", "MYTERM_PUSH_BUNDLE_ID", "MYTERM_PUSH_APP_ATTEST_ENVIRONMENT", "MYTERM_PUSH_APNS_KEY_ID", "MYTERM_PUSH_APNS_KEY_FILE", "MYTERM_PUSH_APNS_TOPIC", "MYTERM_PUSH_APNS_ENVIRONMENT", "MYTERM_PUSH_TRUSTED_PROXY_CIDRS"} {
				t.Setenv(name, "")
			}
			t.Setenv("MYTERM_PUSH_PUBLIC_URL", test.url)
			t.Setenv("MYTERM_PUSH_TEAM_ID", "TEAM")
			t.Setenv("MYTERM_PUSH_BUNDLE_ID", "com.example.app")
			t.Setenv("MYTERM_PUSH_APP_ATTEST_ENVIRONMENT", test.attest)
			t.Setenv("MYTERM_PUSH_APNS_KEY_ID", "KEY")
			t.Setenv("MYTERM_PUSH_APNS_KEY_FILE", "/run/secrets/key.p8")
			t.Setenv("MYTERM_PUSH_APNS_TOPIC", "com.example.app")
			t.Setenv("MYTERM_PUSH_APNS_ENVIRONMENT", test.apns)
			_, err := Load()
			if test.valid && err != nil {
				t.Fatal(err)
			}
			if !test.valid && err == nil {
				t.Fatal("invalid config accepted")
			}
		})
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
