package httpapi

import (
	"bytes"
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

func TestAuthPageJavaScriptSelectsTheRequestedCeremony(t *testing.T) {
	literal := regexp.MustCompile(`const mode=([^;]+);`)
	for _, mode := range []string{"register", "login"} {
		t.Run(mode, func(t *testing.T) {
			var page bytes.Buffer
			if err := authPage.Execute(&page, authPageData{Nonce: "test", Mode: mode, RPName: "MyTerm Dev"}); err != nil {
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

func TestRegistrationUsesOneEscapedPasskeyName(t *testing.T) {
	var page bytes.Buffer
	if err := authPage.Execute(&page, authPageData{Nonce: "test", Mode: "register", RPName: `MyTerm Dev <script>alert(1)</script>`}); err != nil {
		t.Fatal(err)
	}
	html := page.String()
	if strings.Contains(html, `id="owner"`) || strings.Contains(html, `autocomplete="name"`) {
		t.Fatal("registration should not request a separate owner or personal name")
	}
	if !strings.Contains(html, `Passkey name`) || !strings.Contains(html, `value="MyTerm Dev &lt;script&gt;alert(1)&lt;/script&gt;"`) {
		t.Fatal("configured passkey name missing or not HTML escaped")
	}
}
