package config

import "testing"

func TestLoadFailsClosedForOriginCredentialsAndEnvironments(t *testing.T) {
	tests := []struct {
		name, url, attest, apns string
		valid                   bool
	}{{"valid", "https://push.example.com", "production", "production", true}, {"sandbox development", "https://push.example.com", "development", "sandbox", true}, {"http", "http://push.example.com", "production", "production", false}, {"path", "https://push.example.com/api", "production", "production", false}, {"bad attest", "https://push.example.com", "disabled", "production", false}, {"bad APNs", "https://push.example.com", "production", "disabled", false}}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			for _, name := range []string{"MYTERM_PUSH_PUBLIC_URL", "MYTERM_PUSH_LISTEN", "MYTERM_PUSH_DATABASE", "MYTERM_PUSH_TEAM_ID", "MYTERM_PUSH_BUNDLE_ID", "MYTERM_PUSH_APP_ATTEST_ENVIRONMENT", "MYTERM_PUSH_APNS_KEY_ID", "MYTERM_PUSH_APNS_KEY_FILE", "MYTERM_PUSH_APNS_TOPIC", "MYTERM_PUSH_APNS_ENVIRONMENT"} {
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
