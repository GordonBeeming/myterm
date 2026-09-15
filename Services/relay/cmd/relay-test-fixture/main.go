// relay-test-fixture runs the production relay handler with ephemeral credentials for cross-process tests.
// It is a separate command so no test seeding or TLS trust behavior can enter the production binary.
package main

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"net"
	"net/http/httptest"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/gordonbeeming/myterm/relay/internal/config"
	"github.com/gordonbeeming/myterm/relay/internal/httpapi"
	"github.com/gordonbeeming/myterm/relay/internal/store"
	"github.com/gordonbeeming/myterm/relay/internal/transport"
)

type fixture struct {
	URL            string `json:"url"`
	Certificate    string `json:"certificate_path"`
	AccountID      string `json:"account_id"`
	HostDeviceID   string `json:"host_device_id"`
	HostToken      string `json:"host_token"`
	ClientDeviceID string `json:"client_device_id"`
	ClientToken    string `json:"client_token"`
}

func main() {
	tempDir := flag.String("temp-dir", "", "required directory for fixture state")
	listen := flag.String("listen", "127.0.0.1:0", "loopback listen address")
	flag.Parse()
	if *tempDir == "" {
		fatalf("--temp-dir is required")
	}
	if err := os.MkdirAll(*tempDir, 0o700); err != nil {
		fatalf("create temp directory: %v", err)
	}

	ctx := context.Background()
	database, err := store.Open(ctx, filepath.Join(*tempDir, "relay.sqlite"))
	if err != nil {
		fatalf("open store: %v", err)
	}
	defer database.Close()

	accountID := uuid.NewString()
	bootstrap, err := store.NewToken(32)
	if err != nil {
		fatalf("create bootstrap: %v", err)
	}
	now := time.Now()
	if err := database.CreateBootstrapToken(ctx, bootstrap, now.Add(time.Minute)); err != nil {
		fatalf("store bootstrap: %v", err)
	}
	owner := store.Owner{ID: accountID, WebAuthnID: []byte("native-fixture-owner"), Name: "fixture", DisplayName: "Fixture"}
	credential := store.CredentialRecord{ID: []byte("native-fixture-credential"), JSON: []byte(`{"id":"bmF0aXZlLWZpeHR1cmUtY3JlZGVudGlhbA"}`)}
	if err := database.CreateOwnerCredential(ctx, owner, credential, bootstrap, now); err != nil {
		fatalf("create owner: %v", err)
	}
	hostDevice, hostToken := createDevice(ctx, database, accountID, "host", "Native Host", now)
	clientDevice, clientToken := createDevice(ctx, database, accountID, "client", "Native Client", now)

	publicURL, _ := url.Parse("https://relay.example.test")
	cfg := config.Config{
		PublicURL: publicURL, RPID: "relay.example.test", RPDisplayName: "Relay Fixture",
		AccessTokenTTL: 15 * time.Minute, RefreshTokenTTL: time.Hour,
		AuthCodeTTL: time.Minute, CeremonyTTL: time.Minute, PairingTicketTTL: time.Minute,
		WebSocketFrameLimit: 1 << 20, WebSocketQueueDepth: 8,
		HeartbeatInterval: time.Minute, HeartbeatTimeout: 5 * time.Second,
	}
	hub := transport.New(cfg)
	api, err := httpapi.New(cfg, database, hub)
	if err != nil {
		fatalf("create relay: %v", err)
	}
	server := httptest.NewUnstartedServer(api.Handler())
	server.Listener.Close()
	server.Listener, err = net.Listen("tcp", *listen)
	if err != nil {
		fatalf("listen: %v", err)
	}
	server.StartTLS()
	defer server.Close()

	certificatePath := filepath.Join(*tempDir, "relay-cert.pem")
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
	if err := os.WriteFile(certificatePath, certificate, 0o600); err != nil {
		fatalf("write certificate: %v", err)
	}
	ready := fixture{
		URL: server.URL, Certificate: certificatePath, AccountID: accountID,
		HostDeviceID: hostDevice.ID, HostToken: hostToken,
		ClientDeviceID: clientDevice.ID, ClientToken: clientToken,
	}
	encoded, err := json.Marshal(ready)
	if err != nil {
		fatalf("encode fixture: %v", err)
	}
	readyPath := filepath.Join(*tempDir, "ready.json")
	if err := os.WriteFile(readyPath, encoded, 0o600); err != nil {
		fatalf("write fixture: %v", err)
	}
	fmt.Println(readyPath)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
}

func createDevice(ctx context.Context, database *store.Store, accountID, kind, name string, now time.Time) (store.Device, string) {
	device := store.Device{ID: uuid.NewString(), OwnerID: accountID, Kind: kind, Name: name}
	access, err := store.NewToken(32)
	if err != nil {
		fatalf("create access token: %v", err)
	}
	refresh, err := store.NewToken(48)
	if err != nil {
		fatalf("create refresh token: %v", err)
	}
	if err := database.CreateDeviceTokens(ctx, device, access, refresh,
		now.Add(time.Hour), now.Add(time.Hour), now); err != nil {
		fatalf("store device: %v", err)
	}
	return device, access
}

func fatalf(format string, arguments ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", arguments...)
	os.Exit(1)
}
