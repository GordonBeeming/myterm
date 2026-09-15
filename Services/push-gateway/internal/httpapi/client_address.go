package httpapi

import (
	"net"
	"net/http"
	"net/netip"
	"strings"
)

const maximumForwardedHops = 32

func clientAddress(request *http.Request, trustedProxies []netip.Prefix) string {
	peer, ok := parsePeerAddress(request.RemoteAddr)
	if !ok || !addressTrusted(peer, trustedProxies) {
		return peerOrRaw(peer, ok, request.RemoteAddr)
	}
	var forwarded []netip.Addr
	for _, header := range request.Header.Values("X-Forwarded-For") {
		for _, part := range strings.Split(header, ",") {
			if len(forwarded) >= maximumForwardedHops {
				return peer.String()
			}
			address, err := netip.ParseAddr(strings.TrimSpace(part))
			if err != nil {
				return peer.String()
			}
			forwarded = append(forwarded, address.Unmap())
		}
	}
	for index := len(forwarded) - 1; index >= 0; index-- {
		if !addressTrusted(forwarded[index], trustedProxies) {
			return forwarded[index].String()
		}
	}
	return peer.String()
}

func parsePeerAddress(value string) (netip.Addr, bool) {
	host, _, err := net.SplitHostPort(value)
	if err != nil {
		host = strings.Trim(value, "[]")
	}
	address, err := netip.ParseAddr(host)
	if err != nil {
		return netip.Addr{}, false
	}
	return address.Unmap(), true
}
func addressTrusted(address netip.Addr, prefixes []netip.Prefix) bool {
	for _, prefix := range prefixes {
		if prefix.Contains(address) {
			return true
		}
	}
	return false
}
func peerOrRaw(address netip.Addr, ok bool, raw string) string {
	if ok {
		return address.String()
	}
	return raw
}
