package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"time"

	"golang.org/x/net/websocket"
)

func handleNavigation(w http.ResponseWriter, r *http.Request) bool {
	path := r.URL.Path
	switch path {
	case "/navigation", "/login-start", "/login-provider", "/login-complete", "/login-proof",
		"/popup", "/cors-ok", "/cors-denied", "/hot-reload":
	default:
		return false
	}

	_, port, err := net.SplitHostPort(r.Host)
	if err != nil {
		http.Error(w, "fixture requires an explicit port", http.StatusBadRequest)
		return true
	}
	first := "https://" + net.JoinHostPort("myterm-route-probe.invalid", port)
	second := "https://" + net.JoinHostPort("other-route-probe.invalid", port)
	log.Printf("navigation %s %s%s", r.Method, r.Host, path)
	w.Header().Set("Cache-Control", "no-store")

	switch path {
	case "/login-start":
		http.Redirect(w, r, second+"/login-provider", http.StatusFound)
	case "/login-provider":
		http.Redirect(w, r, first+"/login-complete", http.StatusSeeOther)
	case "/login-complete", "/navigation":
		title := "NAVIGATION_HOME"
		if path == "/login-complete" {
			http.SetCookie(w, &http.Cookie{Name: "fixture_login", Value: "approved", Path: "/",
				Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode})
			title = "NAVIGATION_SIGNED_IN"
		}
		expected, err := json.Marshal(second)
		if err != nil {
			http.Error(w, "fixture failed to encode popup origin", http.StatusInternalServerError)
			return true
		}
		w.Header().Set("Content-Type", "text/html")
		fmt.Fprintf(w, `<!doctype html><title>%s</title><a id="popup" href="%s/popup" target="_blank" rel="opener">Open popup</a>
<script>window.addEventListener('message', event => {
  if (event.origin === %s && event.data === 'fixture-popup-ok') window.fixturePopup = event.origin;
});</script>`, title, second, expected)
	case "/login-proof":
		cookie, err := r.Cookie("fixture_login")
		if err == nil && cookie.Value == "approved" {
			fmt.Fprint(w, "SIGNED_IN")
		} else {
			w.WriteHeader(http.StatusUnauthorized)
			fmt.Fprint(w, "SIGNED_OUT")
		}
	case "/popup":
		opener := url.URL{Scheme: "https", Host: net.JoinHostPort("myterm-route-probe.invalid", port)}
		destination, err := json.Marshal(opener.String())
		if err != nil {
			http.Error(w, "fixture failed to encode opener", http.StatusInternalServerError)
			return true
		}
		w.Header().Set("Content-Type", "text/html")
		fmt.Fprintf(w, `<!doctype html><title>NAVIGATION_POPUP</title>
<script>window.opener.postMessage('fixture-popup-ok', %s);</script>`, destination)
	case "/hot-reload":
		generation := r.URL.Query().Get("generation")
		if generation != "1" && generation != "2" {
			http.Error(w, "unknown fixture generation", http.StatusBadRequest)
			return true
		}
		websocket.Handler(func(connection *websocket.Conn) {
			log.Printf("hot-reload generation %s connected via %s", generation, r.Proto)
			if err := connection.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
				log.Print(err)
				return
			}
			if err := websocket.Message.Send(connection, "hot-reload-"+generation); err != nil {
				log.Print(err)
				return
			}
			var acknowledgement string
			if err := websocket.Message.Receive(connection, &acknowledgement); err != nil {
				log.Printf("hot-reload generation %s acknowledgement: %v", generation, err)
				return
			}
			log.Printf("hot-reload generation %s acknowledgement: %s", generation, acknowledgement)
			if err := connection.Close(); err != nil {
				log.Print(err)
			}
		}).ServeHTTP(w, r)
	case "/cors-ok", "/cors-denied":
		if path == "/cors-ok" && r.Header.Get("Origin") == first {
			w.Header().Set("Access-Control-Allow-Origin", first)
		}
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprint(w, "CROSS_ORIGIN_FIXTURE")
	}
	return true
}
