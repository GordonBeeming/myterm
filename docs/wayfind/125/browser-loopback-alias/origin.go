package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	if len(os.Args) != 5 {
		log.Fatal("use origin LISTEN HOST CERT KEY")
	}
	listen, expectedHost, cert, key := os.Args[1], os.Args[2], os.Args[3], os.Args[4]
	server := &http.Server{
		Addr: listen, ReadHeaderTimeout: 3 * time.Second,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-store")
			if r.Host != expectedHost || !strings.HasPrefix(r.RemoteAddr, "127.0.0.1:") {
				http.Error(w, "fixture host or route mismatch", http.StatusForbidden)
				return
			}
			log.Printf("origin %s %s host=%s source=loopback", r.Method, r.URL.Path, r.Host)
			switch r.URL.Path {
			case "/login":
				http.SetCookie(w, &http.Cookie{Name: "fixture_session", Value: "signed-in", Path: "/",
					Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode})
				http.Redirect(w, r, "https://"+expectedHost+"/dashboard", http.StatusSeeOther)
			case "/dashboard":
				w.Header().Set("Content-Type", "text/html")
				fmt.Fprint(w, `<!doctype html><title>ASSIGNED_LOOPBACK_ORIGIN</title><link rel="stylesheet" href="/theme.css"><p id="marker">fixture</p>`)
			case "/theme.css":
				w.Header().Set("Content-Type", "text/css")
				fmt.Fprint(w, "#marker { color: rgb(26, 97, 162); }")
			case "/session":
				cookie, err := r.Cookie("fixture_session")
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(map[string]any{"signedIn": err == nil && cookie.Value == "signed-in", "host": r.Host})
			default:
				http.NotFound(w, r)
			}
		}),
	}
	log.Fatal(server.ListenAndServeTLS(cert, key))
}
