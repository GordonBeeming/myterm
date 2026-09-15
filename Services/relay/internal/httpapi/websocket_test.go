package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	relayauth "github.com/gordonbeeming/myterm/relay/internal/auth"
	"github.com/gordonbeeming/myterm/relay/internal/config"
	"github.com/gordonbeeming/myterm/relay/internal/store"
	"github.com/gordonbeeming/myterm/relay/internal/transport"
)

func TestWebSocketAuthenticationRoutingScopingAndOfflineTransition(t *testing.T) {
	api, testServer, storage, ownerID := newWebSocketTestServer(t)
	_ = api
	hostOneID, hostTwoID := uuid.NewString(), uuid.NewString()
	hostOneDevice, hostOneToken := createTestDevice(t, storage, ownerID, "host", "Mac one")
	hostTwoDevice, hostTwoToken := createTestDevice(t, storage, ownerID, "host", "Mac two")
	clientDevice, clientToken := createTestDevice(t, storage, ownerID, "client", "iPhone")
	key := bytes.Repeat([]byte{7}, 32)
	if _, err := storage.UpsertHost(context.Background(), store.Host{ID: hostOneID, OwnerID: ownerID, DeviceID: hostOneDevice.ID, Name: "Mac one"}, key, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := storage.UpsertHost(context.Background(), store.Host{ID: hostTwoID, OwnerID: ownerID, DeviceID: hostTwoDevice.ID, Name: "Mac two"}, key, time.Now()); err != nil {
		t.Fatal(err)
	}

	wsURL := "wss" + strings.TrimPrefix(testServer.URL, "https") + "/v1/transport/ws"
	if _, response, err := websocket.Dial(context.Background(), wsURL+"?host_id="+hostOneID+"&role=client", &websocket.DialOptions{HTTPClient: testServer.Client()}); err == nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("missing bearer: err=%v status=%v", err, response.StatusCode)
	}
	if _, response, err := websocket.Dial(context.Background(), wsURL+"?host_id="+hostOneID+"&role=client&access_token="+clientToken, &websocket.DialOptions{HTTPClient: testServer.Client(), HTTPHeader: bearer(clientToken)}); err == nil || response.StatusCode != http.StatusBadRequest {
		t.Fatalf("URL bearer: err=%v status=%v", err, response.StatusCode)
	}

	hostOne := dialWebSocket(t, testServer, wsURL, hostOneID, "host", hostOneToken)
	defer hostOne.CloseNow()
	hostOneReady := readControlType(t, hostOne, "ready")
	clientOne := dialWebSocket(t, testServer, wsURL, hostOneID, "client", clientToken)
	defer clientOne.CloseNow()
	clientReady := readControlType(t, clientOne, "ready")
	hostOnePeer := readControlType(t, hostOne, "peer")
	if hostOnePeer.ConnectionID != clientReady.ConnectionID || hostOnePeer.Role != "client" || hostOnePeer.TransportOnline == nil || !*hostOnePeer.TransportOnline {
		t.Fatalf("unexpected client online event: %+v", hostOnePeer)
	}
	clientPeer := readControlType(t, clientOne, "peer")
	if clientPeer.ConnectionID != hostOneReady.ConnectionID || clientPeer.Role != "host" || clientPeer.TransportOnline == nil || !*clientPeer.TransportOnline {
		t.Fatalf("unexpected host online event: %+v", clientPeer)
	}
	if !hostOnlineFromAPI(t, testServer, clientToken, hostOneID) {
		t.Fatal("host list did not report the authenticated host transport")
	}

	hostTwo := dialWebSocket(t, testServer, wsURL, hostTwoID, "host", hostTwoToken)
	defer hostTwo.CloseNow()
	hostTwoReady := readControlType(t, hostTwo, "ready")

	frame := make([]byte, 17+5)
	frame[0] = transport.ProtocolVersion
	copy(frame[1:17], uuid.Nil[:])
	copy(frame[17:], []byte("hello"))
	writeBinary(t, clientOne, frame)
	received := readBinary(t, hostOne)
	clientConnectionID := uuid.MustParse(clientReady.ConnectionID)
	if !bytes.Equal(received[1:17], clientConnectionID[:]) || string(received[17:]) != "hello" {
		t.Fatalf("forwarded frame did not carry trusted source identity: %x", received)
	}

	crossHost := append([]byte(nil), frame...)
	hostTwoConnectionID := uuid.MustParse(hostTwoReady.ConnectionID)
	copy(crossHost[1:17], hostTwoConnectionID[:])
	writeBinary(t, clientOne, crossHost)
	invalidDestination := readControlType(t, clientOne, "error")
	if invalidDestination.Code != "invalid_destination" {
		t.Fatalf("unexpected routing error: %+v", invalidDestination)
	}
	assertNoMessage(t, hostTwo, 100*time.Millisecond)

	if err := hostOne.Close(websocket.StatusNormalClosure, "test disconnect"); err != nil {
		t.Fatal(err)
	}
	offline := readControlType(t, clientOne, "peer")
	if offline.ConnectionID != hostOneReady.ConnectionID || offline.TransportOnline == nil || *offline.TransportOnline {
		t.Fatalf("unexpected offline event: %+v", offline)
	}
	if hostOnlineFromAPI(t, testServer, clientToken, hostOneID) {
		t.Fatal("host list retained transport presence after disconnect")
	}
	endpoint := "/v1/hosts/" + hostOneID + "/connections/" + clientReady.ConnectionID
	denied := requestJSON(t, testServer, http.MethodDelete, endpoint, clientToken, nil)
	if denied.StatusCode != http.StatusForbidden {
		t.Fatalf("client disconnect status %d", denied.StatusCode)
	}
	denied.Body.Close()
	crossHostEndpoint := "/v1/hosts/" + hostOneID + "/connections/" + hostTwoReady.ConnectionID
	denied = requestJSON(t, testServer, http.MethodDelete, crossHostEndpoint, hostTwoToken, nil)
	if denied.StatusCode != http.StatusForbidden {
		t.Fatalf("wrong host disconnect status %d", denied.StatusCode)
	}
	denied.Body.Close()
	disconnect := requestJSON(t, testServer, http.MethodDelete, endpoint, hostOneToken, nil)
	if disconnect.StatusCode != http.StatusNoContent {
		t.Fatalf("target disconnect status %d", disconnect.StatusCode)
	}
	disconnect.Body.Close()
	closedContext, cancel := context.WithTimeout(context.Background(), time.Second)
	if _, _, err := clientOne.Read(closedContext); err == nil {
		t.Fatal("targeted client connection remained open")
	}
	cancel()
	disconnect = requestJSON(t, testServer, http.MethodDelete, endpoint, hostOneToken, nil)
	if disconnect.StatusCode != http.StatusNoContent {
		t.Fatalf("idempotent disconnect status %d", disconnect.StatusCode)
	}
	disconnect.Body.Close()
	devices := requestJSON(t, testServer, http.MethodGet, "/v1/devices", clientToken, nil)
	if devices.StatusCode != http.StatusOK {
		t.Fatalf("target disconnect revoked device status %d", devices.StatusCode)
	}
	devices.Body.Close()
	clientAfter := dialWebSocket(t, testServer, wsURL, hostOneID, "client", clientToken)
	defer clientAfter.CloseNow()
	readControlType(t, clientAfter, "ready")
	revoke := requestJSON(t, testServer, http.MethodDelete, "/v1/devices/"+clientDevice.ID, clientToken, nil)
	if revoke.StatusCode != http.StatusNoContent {
		t.Fatalf("device revoke status %d: %s", revoke.StatusCode, readBody(t, revoke))
	}
	revoke.Body.Close()
	closedContext, cancel = context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, _, err := clientAfter.Read(closedContext); err == nil {
		t.Fatal("revoked device retained its WebSocket")
	}
}

func TestStableHostHTTPAPI(t *testing.T) {
	_, testServer, storage, ownerID := newWebSocketTestServer(t)
	_, hostToken := createTestDevice(t, storage, ownerID, "host", "Mac")
	_, clientToken := createTestDevice(t, storage, ownerID, "client", "iPhone")
	hostID := uuid.NewString()
	publicKey := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32))

	response := requestJSON(t, testServer, http.MethodPut, "/v1/hosts/"+hostID, hostToken, map[string]any{"name": "Mac", "public_key": publicKey})
	if response.StatusCode != http.StatusOK {
		t.Fatalf("register host status %d: %s", response.StatusCode, readBody(t, response))
	}
	var registered hostResponse
	if err := json.NewDecoder(response.Body).Decode(&registered); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if registered.Host.HostID != hostID || registered.Host.Name != "Mac" || registered.Host.PublicKey != publicKey {
		t.Fatalf("unexpected host response: %+v", registered)
	}

	response = requestJSON(t, testServer, http.MethodPut, "/v1/hosts/"+hostID, hostToken, map[string]any{"name": "Renamed Mac", "public_key": publicKey})
	if response.StatusCode != http.StatusOK {
		t.Fatalf("update host status %d: %s", response.StatusCode, readBody(t, response))
	}
	response.Body.Close()
	response = requestJSON(t, testServer, http.MethodGet, "/v1/hosts", clientToken, nil)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("list hosts status %d", response.StatusCode)
	}
	var listed struct {
		Hosts []hostJSON `json:"hosts"`
	}
	if err := json.NewDecoder(response.Body).Decode(&listed); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if len(listed.Hosts) != 1 || listed.Hosts[0].HostID != hostID || listed.Hosts[0].Name != "Renamed Mac" {
		t.Fatalf("stable registration duplicated or changed ID: %+v", listed.Hosts)
	}
	obsolete := requestJSON(t, testServer, http.MethodPost, "/v1/hosts/"+hostID+"/pairing-tickets", hostToken, map[string]any{})
	if obsolete.StatusCode != http.StatusNotFound {
		t.Fatalf("obsolete pairing route status %d", obsolete.StatusCode)
	}
	obsolete.Body.Close()
}

func TestAuthorizationCodeFailuresNeverIssueOrPersistTokens(t *testing.T) {
	_, server, storage, ownerID := newWebSocketTestServer(t)
	now := time.Now()
	verifier := strings.Repeat("v", 43)
	challenge, err := relayauth.PKCES256(verifier)
	if err != nil {
		t.Fatal(err)
	}
	oauth := store.OAuthContext{RedirectURI: "myterm-companion://auth/callback", CodeChallenge: challenge, DeviceName: "Browser", DeviceKind: "client"}
	save := func(code string, expiry time.Time) {
		if err := storage.SaveAuthCode(context.Background(), code, ownerID, oauth, expiry); err != nil {
			t.Fatal(err)
		}
	}
	request := func(code, callback, value string) *http.Response {
		return requestJSON(t, server, http.MethodPost, "/v1/oauth/token", "", map[string]any{"grant_type": "authorization_code", "code": code, "code_verifier": value, "redirect_uri": callback})
	}
	save("wrong-callback", now.Add(time.Minute))
	assertTokenFailure(t, request("wrong-callback", "myterm-dev://companion-auth/callback", verifier))
	save("wrong-pkce", now.Add(time.Minute))
	assertTokenFailure(t, request("wrong-pkce", oauth.RedirectURI, strings.Repeat("w", 43)))
	save("expired", now.Add(-time.Second))
	assertTokenFailure(t, request("expired", oauth.RedirectURI, verifier))
	save("single-use", now.Add(time.Minute))
	valid := request("single-use", oauth.RedirectURI, verifier)
	if valid.StatusCode != http.StatusOK {
		t.Fatalf("valid exchange status %d: %s", valid.StatusCode, readBody(t, valid))
	}
	var issued tokenResponse
	if err := json.NewDecoder(valid.Body).Decode(&issued); err != nil {
		t.Fatal(err)
	}
	valid.Body.Close()
	if issued.DeviceID == "" || issued.AccountID != ownerID {
		t.Fatalf("invalid token identity: %+v", issued)
	}
	assertTokenFailure(t, request("single-use", oauth.RedirectURI, verifier))
	protected := requestJSON(t, server, http.MethodGet, "/v1/devices", issued.AccessToken, nil)
	if protected.StatusCode != http.StatusUnauthorized {
		t.Fatalf("authorization-code replay left access active: %d", protected.StatusCode)
	}
	protected.Body.Close()
	refresh := requestJSON(t, server, http.MethodPost, "/v1/oauth/token", "", map[string]any{"grant_type": "refresh_token", "refresh_token": issued.RefreshToken})
	assertTokenFailure(t, refresh)
	devices, err := storage.ListDevices(context.Background(), ownerID)
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 1 {
		t.Fatalf("invalid exchanges persisted %d devices", len(devices))
	}
}

func assertTokenFailure(t *testing.T, response *http.Response) {
	t.Helper()
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("failure status %d: %s", response.StatusCode, data)
	}
	var value map[string]any
	if err := json.Unmarshal(data, &value); err != nil {
		t.Fatal(err)
	}
	if _, ok := value["access_token"]; ok {
		t.Fatalf("failure issued token: %s", data)
	}
}

func newWebSocketTestServer(t *testing.T) (*Server, *httptest.Server, *store.Store, string) {
	t.Helper()
	publicURL, _ := url.Parse("https://relay.example.com")
	cfg := config.Config{PublicURL: publicURL, RPID: "relay.example.com", RPDisplayName: "Relay", AccessTokenTTL: 15 * time.Minute, RefreshTokenTTL: time.Hour, AuthCodeTTL: time.Minute, CeremonyTTL: time.Minute, PairingTicketTTL: time.Minute, WebSocketFrameLimit: 1 << 20, WebSocketQueueDepth: 8, HeartbeatInterval: time.Minute, HeartbeatTimeout: time.Second}
	storage, err := store.Open(context.Background(), "file:"+strings.ReplaceAll(t.Name(), "/", "-")+"?mode=memory&cache=shared")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { storage.Close() })
	bootstrap, _ := store.NewToken(32)
	if err := storage.CreateBootstrapToken(context.Background(), bootstrap, time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	ownerID := uuid.NewString()
	if err := storage.CreateOwnerCredential(context.Background(), store.Owner{ID: ownerID, WebAuthnID: []byte("test-owner-handle"), Name: "owner", DisplayName: "Owner"}, store.CredentialRecord{ID: []byte("credential"), JSON: []byte(`{"id":"Y3JlZGVudGlhbA"}`)}, bootstrap, time.Now()); err != nil {
		t.Fatal(err)
	}
	hub := transport.New(cfg)
	api, err := New(cfg, storage, hub)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewTLSServer(api.Handler())
	t.Cleanup(server.Close)
	return api, server, storage, ownerID
}

func createTestDevice(t *testing.T, storage *store.Store, ownerID, kind, name string) (store.Device, string) {
	t.Helper()
	device := store.Device{ID: uuid.NewString(), OwnerID: ownerID, Kind: kind, Name: name}
	access, _ := store.NewToken(32)
	refresh, _ := store.NewToken(48)
	now := time.Now()
	if err := storage.CreateDeviceTokens(context.Background(), device, access, refresh, now.Add(time.Hour), now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}
	return device, access
}

func dialWebSocket(t *testing.T, server *httptest.Server, baseURL, hostID, role, token string) *websocket.Conn {
	t.Helper()
	conn, response, err := websocket.Dial(context.Background(), baseURL+"?host_id="+hostID+"&role="+role, &websocket.DialOptions{HTTPClient: server.Client(), HTTPHeader: bearer(token)})
	if err != nil {
		t.Fatalf("dial websocket: %v (status %v)", err, response.StatusCode)
	}
	return conn
}

func bearer(token string) http.Header {
	headers := make(http.Header)
	headers.Set("Authorization", "Bearer "+token)
	return headers
}

func requestJSON(t *testing.T, server *httptest.Server, method, path, token string, body any) *http.Response {
	t.Helper()
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequest(method, server.URL+path, reader)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func hostOnlineFromAPI(t *testing.T, server *httptest.Server, token, hostID string) bool {
	t.Helper()
	response := requestJSON(t, server, http.MethodGet, "/v1/hosts", token, nil)
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("list hosts status %d", response.StatusCode)
	}
	var result struct {
		Hosts []hostJSON `json:"hosts"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	for _, host := range result.Hosts {
		if host.HostID == hostID {
			return host.TransportOnline
		}
	}
	t.Fatalf("host %s missing from list", hostID)
	return false
}

func readBody(t *testing.T, response *http.Response) string {
	t.Helper()
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

type testControlMessage struct {
	Type            string `json:"type"`
	ConnectionID    string `json:"connection_id"`
	Role            string `json:"role"`
	TransportOnline *bool  `json:"transport_online"`
	Code            string `json:"code"`
}

func readControlType(t *testing.T, conn *websocket.Conn, wanted string) testControlMessage {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	for {
		messageType, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("read %s control: %v", wanted, err)
		}
		if messageType != websocket.MessageText {
			t.Fatalf("wanted control message, got binary %s", base64.RawURLEncoding.EncodeToString(data))
		}
		var message testControlMessage
		if err := json.Unmarshal(data, &message); err != nil {
			t.Fatal(err)
		}
		if message.Type == wanted {
			return message
		}
	}
}

func writeBinary(t *testing.T, conn *websocket.Conn, data []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageBinary, data); err != nil {
		t.Fatal(err)
	}
}

func readBinary(t *testing.T, conn *websocket.Conn) []byte {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	kind, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if kind != websocket.MessageBinary {
		t.Fatalf("expected binary, got %s", data)
	}
	return data
}

func assertNoMessage(t *testing.T, conn *websocket.Conn, duration time.Duration) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()
	_, _, err := conn.Read(ctx)
	if err == nil {
		t.Fatal("unexpected websocket message")
	}
}
