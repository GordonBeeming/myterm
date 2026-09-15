package httpapi

import (
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
)

func TestClientAddressTrustsOnlyConfiguredProxyChain(t *testing.T) {
	trusted := []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8"), netip.MustParsePrefix("10.0.0.0/8")}
	tests := []struct{ name, remote, forwarded, want string }{{"direct spoof ignored", "198.51.100.8:443", "203.0.113.9", "198.51.100.8"}, {"local proxy", "127.0.0.1:5000", "203.0.113.9", "203.0.113.9"}, {"rightmost untrusted", "127.0.0.1:5000", "192.0.2.44, 198.51.100.7, 10.2.3.4", "198.51.100.7"}, {"malformed fallback", "127.0.0.1:5000", "spoofed", "127.0.0.1"}, {"all trusted fallback", "127.0.0.1:5000", "10.1.1.1", "127.0.0.1"}, {"mapped loopback", "[::ffff:127.0.0.1]:5000", "203.0.113.10", "203.0.113.10"}}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest("GET", "https://push.example.test", nil)
			request.RemoteAddr = test.remote
			request.Header.Set("X-Forwarded-For", test.forwarded)
			if got := clientAddress(request, trusted); got != test.want {
				t.Fatalf("clientAddress=%q want %q", got, test.want)
			}
		})
	}
	request := httptest.NewRequest("GET", "https://push.example.test", nil)
	request.RemoteAddr = "127.0.0.1:5000"
	request.Header.Set("X-Forwarded-For", strings.Repeat("203.0.113.1,", maximumForwardedHops)+"203.0.113.2")
	if got := clientAddress(request, trusted); got != "127.0.0.1" {
		t.Fatalf("oversize chain=%q", got)
	}
}
