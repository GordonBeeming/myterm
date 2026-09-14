package httpapi

import (
	"bytes"
	"encoding/json"
	"regexp"
	"testing"
)

func TestAuthPageJavaScriptSelectsTheRequestedCeremony(t *testing.T) {
	literal := regexp.MustCompile(`const mode=([^;]+);`)
	for _, mode := range []string{"register", "login"} {
		t.Run(mode, func(t *testing.T) {
			var page bytes.Buffer
			if err := authPage.Execute(&page, struct{ Nonce, Mode string }{Nonce: "test", Mode: mode}); err != nil {
				t.Fatal(err)
			}
			match := literal.FindSubmatch(page.Bytes())
			if len(match) != 2 {
				t.Fatal("authentication script has no mode")
			}
			var actual string
			if err := json.Unmarshal(match[1], &actual); err != nil {
				t.Fatal(err)
			}
			if actual != mode {
				t.Fatalf("browser selects ceremony %q, want %q", actual, mode)
			}
		})
	}
}
