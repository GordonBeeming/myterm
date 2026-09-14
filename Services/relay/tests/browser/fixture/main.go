package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gordonbeeming/myterm/relay/internal/config"
	"github.com/gordonbeeming/myterm/relay/internal/httpapi"
	"github.com/gordonbeeming/myterm/relay/internal/store"
	"github.com/gordonbeeming/myterm/relay/internal/transport"
)

type fixtureInfo struct {
	Origin       string `json:"origin"`
	BootstrapURL string `json:"bootstrap_url"`
	LoginURL     string `json:"login_url"`
	Verifier     string `json:"verifier"`
	SPKIHash     string `json:"spki_hash"`
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
func run() error {
	temporary, err := os.MkdirTemp("", "myterm-relay-browser-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temporary)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	origin := fmt.Sprintf("https://relay.localhost:%d", port)
	publicURL, _ := url.Parse(origin)
	cfg := config.Config{ListenAddress: listener.Addr().String(), PublicURL: publicURL, RPID: "relay.localhost", RPDisplayName: "MyTerm browser test", DatabasePath: temporary + "/relay.sqlite3", AccessTokenTTL: 15 * time.Minute, RefreshTokenTTL: time.Hour, AuthCodeTTL: 2 * time.Minute, CeremonyTTL: 5 * time.Minute, PairingTicketTTL: time.Minute, WebSocketFrameLimit: 1 << 20, WebSocketQueueDepth: 8, HeartbeatInterval: time.Minute, HeartbeatTimeout: time.Second}
	storage, err := store.Open(context.Background(), cfg.DatabasePath)
	if err != nil {
		return err
	}
	defer storage.Close()
	hub := transport.New(cfg)
	api, err := httpapi.New(cfg, storage, hub)
	if err != nil {
		return err
	}
	verifier, challenge, state, err := oauthValues()
	if err != nil {
		return err
	}
	bootstrap, err := store.NewToken(32)
	if err != nil {
		return err
	}
	if err := storage.CreateBootstrapToken(context.Background(), bootstrap, time.Now().Add(10*time.Minute)); err != nil {
		return err
	}
	registerURL := authURL(publicURL, "register", challenge, state)
	registerURL.Fragment = "bootstrap_token=" + bootstrap
	loginURL := authURL(publicURL, "login", challenge, state)
	mux := http.NewServeMux()
	mux.Handle("/", api.Handler())
	certificate, spki, err := testCertificate()
	if err != nil {
		return err
	}
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	tlsListener := tls.NewListener(listener, &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS13})
	go func() {
		if err := server.Serve(tlsListener); err != nil && err != http.ErrServerClosed {
			log.Printf("serve: %v", err)
		}
	}()
	if err := json.NewEncoder(os.Stdout).Encode(fixtureInfo{Origin: origin, BootstrapURL: registerURL.String(), LoginURL: loginURL.String(), Verifier: verifier, SPKIHash: spki}); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return server.Shutdown(shutdown)
}
func oauthValues() (verifier, challenge, state string, err error) {
	verifier, err = store.NewToken(48)
	if err != nil {
		return
	}
	digest := sha256.Sum256([]byte(verifier))
	challenge = base64.RawURLEncoding.EncodeToString(digest[:])
	state, err = store.NewToken(32)
	return
}
func authURL(origin *url.URL, mode, challenge, state string) *url.URL {
	value := *origin
	value.Path = "/auth/" + mode
	query := value.Query()
	query.Set("redirect_uri", "myterm-companion://auth/callback")
	query.Set("state", state)
	query.Set("code_challenge", challenge)
	query.Set("code_challenge_method", "S256")
	query.Set("device_name", "Browser fixture")
	query.Set("device_kind", "client")
	value.RawQuery = query.Encode()
	return &value
}
func testCertificate() (tls.Certificate, string, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	now := time.Now()
	template := &x509.Certificate{SerialNumber: big.NewInt(now.UnixNano()), Subject: pkix.Name{CommonName: "relay.localhost browser fixture"}, DNSNames: []string{"relay.localhost"}, NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	certificate, err := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}))
	if err != nil {
		return tls.Certificate{}, "", err
	}
	parsed, err := x509.ParseCertificate(der)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	digest := sha256.Sum256(parsed.RawSubjectPublicKeyInfo)
	return certificate, base64.StdEncoding.EncodeToString(digest[:]), nil
}
