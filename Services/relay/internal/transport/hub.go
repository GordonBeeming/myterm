package transport

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"github.com/gordonbeeming/myterm/relay/internal/config"
	"github.com/gordonbeeming/myterm/relay/internal/store"
)

const ProtocolVersion byte = 1

const maximumControlBytes = 8 * 1024

// Authenticator resolves an access token to its device, exactly as the HTTP layer does when a
// connection is first accepted.
type Authenticator func(ctx context.Context, accessToken string, now time.Time) (store.Device, error)

type Hub struct {
	mu           sync.RWMutex
	hosts        map[string]*hostGroup
	config       config.Config
	authenticate Authenticator
}

// SetAuthenticator supplies the token check used to extend a live connection. Without it the hub
// still serves traffic; connections simply expire with their original token.
func (h *Hub) SetAuthenticator(authenticate Authenticator) {
	h.authenticate = authenticate
}

type hostGroup struct {
	host    *connection
	clients map[uuid.UUID]*connection
}

type connection struct {
	id       uuid.UUID
	hostID   string
	role     string
	deviceID string
	socket   *websocket.Conn
	outbound chan outboundMessage
	ctx      context.Context
	cancel   context.CancelFunc
	once     sync.Once

	// expiry closes the connection when the newest validated access token runs out. It is reset
	// by an in-band auth message, so a live connection survives a token refresh while a device
	// that can no longer produce a valid token still drops at its last validated expiry.
	expiryMu sync.Mutex
	expiry   *time.Timer
}

func (c *connection) extendUntil(deadline time.Time) {
	c.expiryMu.Lock()
	defer c.expiryMu.Unlock()
	remaining := time.Until(deadline)
	if remaining <= 0 {
		c.cancel()
		return
	}
	if c.expiry == nil {
		c.expiry = time.AfterFunc(remaining, c.cancel)
		return
	}
	c.expiry.Reset(remaining)
}

func (c *connection) stopExpiry() {
	c.expiryMu.Lock()
	defer c.expiryMu.Unlock()
	if c.expiry != nil {
		c.expiry.Stop()
	}
}

type outboundMessage struct {
	typeCode websocket.MessageType
	data     []byte
}

type controlMessage struct {
	Type             string `json:"type"`
	Protocol         int    `json:"protocol,omitempty"`
	ConnectionID     string `json:"connection_id,omitempty"`
	HostID           string `json:"host_id,omitempty"`
	Role             string `json:"role,omitempty"`
	TransportOnline  *bool  `json:"transport_online,omitempty"`
	MaxFrameBytes    int64  `json:"max_frame_bytes,omitempty"`
	HeartbeatSeconds int64  `json:"heartbeat_seconds,omitempty"`
	Code             string `json:"code,omitempty"`
	ExpiresAt        int64  `json:"expires_at,omitempty"`
}

type inboundControl struct {
	Type        string `json:"type"`
	AccessToken string `json:"access_token,omitempty"`
}

var (
	ErrHostAlreadyConnected = errors.New("host already connected")
	ErrInvalidDestination   = errors.New("invalid destination")
	ErrWrongHost            = errors.New("connection belongs to another host")
	ErrWrongRole            = errors.New("connection is not a client")
)

func New(cfg config.Config) *Hub {
	return &Hub{hosts: make(map[string]*hostGroup), config: cfg}
}

func (h *Hub) HostOnline(hostID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	group := h.hosts[hostID]
	return group != nil && group.host != nil
}

func (h *Hub) DisconnectDevice(deviceID string) {
	h.mu.RLock()
	var connections []*connection
	for _, group := range h.hosts {
		if group.host != nil && group.host.deviceID == deviceID {
			connections = append(connections, group.host)
		}
		for _, client := range group.clients {
			if client.deviceID == deviceID {
				connections = append(connections, client)
			}
		}
	}
	h.mu.RUnlock()
	for _, conn := range connections {
		conn.cancel()
		_ = conn.socket.Close(websocket.StatusPolicyViolation, "device session revoked")
	}
}

func (h *Hub) DisconnectClient(hostID, connectionID string) error {
	id, err := uuid.Parse(connectionID)
	if err != nil {
		return ErrInvalidDestination
	}
	h.mu.RLock()
	group := h.hosts[hostID]
	var target *connection
	if group != nil {
		target = group.clients[id]
		if group.host != nil && group.host.id == id {
			h.mu.RUnlock()
			return ErrWrongRole
		}
	}
	if target == nil {
		for otherHost, other := range h.hosts {
			if otherHost == hostID {
				continue
			}
			if (other.host != nil && other.host.id == id) || other.clients[id] != nil {
				h.mu.RUnlock()
				return ErrWrongHost
			}
		}
	}
	h.mu.RUnlock()
	if target == nil {
		return nil
	}
	target.cancel()
	_ = target.socket.Close(websocket.StatusPolicyViolation, "host ended client connection")
	return nil
}

func (h *Hub) ServeWebSocket(w http.ResponseWriter, r *http.Request, device store.Device, host store.Host, role string) error {
	if role != "host" && role != "client" {
		return errors.New("role must be host or client")
	}
	if role == "host" && (device.Kind != "host" || host.DeviceID != device.ID) {
		return store.ErrUnauthorized
	}
	if role == "client" && device.Kind != "client" {
		return store.ErrUnauthorized
	}

	socket, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		OriginPatterns:  []string{h.config.PublicURL.Host},
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return fmt.Errorf("accept websocket: %w", err)
	}
	socket.SetReadLimit(h.config.WebSocketFrameLimit)
	// The access token's expiry bounds the connection, but as a timer that an in-band auth message
	// can push forward. It used to be a fixed context deadline, which killed every live connection
	// on the token's schedule no matter how busy it was.
	ctx, cancel := context.WithCancel(r.Context())
	conn := &connection{
		id: uuid.New(), hostID: host.ID, role: role, deviceID: device.ID,
		socket: socket, outbound: make(chan outboundMessage, h.config.WebSocketQueueDepth),
		ctx: ctx, cancel: cancel,
	}
	conn.extendUntil(time.Unix(device.AccessExpiresAt, 0))
	defer conn.stopExpiry()
	peers, err := h.register(conn)
	if err != nil {
		cancel()
		socket.Close(websocket.StatusPolicyViolation, "host already connected")
		return err
	}
	defer h.unregister(conn)

	if !conn.sendControl(controlMessage{
		Type: "ready", Protocol: 1, ConnectionID: conn.id.String(), HostID: host.ID, Role: role,
		MaxFrameBytes: h.config.WebSocketFrameLimit, HeartbeatSeconds: int64(h.config.HeartbeatInterval.Seconds()),
		ExpiresAt: device.AccessExpiresAt,
	}) {
		return errors.New("initial control queue unavailable")
	}
	for _, peer := range peers {
		online := true
		if !conn.sendControl(controlMessage{Type: "peer", ConnectionID: peer.id.String(), Role: peer.role, TransportOnline: &online}) {
			return errors.New("initial peer queue unavailable")
		}
	}

	errCh := make(chan error, 2)
	go func() { errCh <- h.writeLoop(ctx, conn) }()
	go func() { errCh <- h.readLoop(ctx, conn) }()
	err = <-errCh
	cancel()
	slog.Info("relay connection ended",
		"host_id", host.ID, "role", role, "connection_id", conn.id.String(),
		"device_id", device.ID, "reason", closeReason(err))
	_ = socket.Close(websocket.StatusNormalClosure, "connection closed")
	return err
}

func (h *Hub) register(conn *connection) ([]*connection, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	group := h.hosts[conn.hostID]
	if group == nil {
		group = &hostGroup{clients: make(map[uuid.UUID]*connection)}
		h.hosts[conn.hostID] = group
	}
	var peers []*connection
	if conn.role == "host" {
		if group.host != nil {
			return nil, ErrHostAlreadyConnected
		}
		group.host = conn
		for _, client := range group.clients {
			peers = append(peers, client)
		}
	} else {
		group.clients[conn.id] = conn
		if group.host != nil {
			peers = append(peers, group.host)
		}
	}
	online := true
	for _, peer := range peers {
		peer.sendControl(controlMessage{Type: "peer", ConnectionID: conn.id.String(), Role: conn.role, TransportOnline: &online})
	}
	return peers, nil
}

func (h *Hub) unregister(conn *connection) {
	conn.once.Do(func() {
		conn.cancel()
		h.mu.Lock()
		group := h.hosts[conn.hostID]
		if group == nil {
			h.mu.Unlock()
			return
		}
		var peers []*connection
		if conn.role == "host" && group.host == conn {
			group.host = nil
			for _, client := range group.clients {
				peers = append(peers, client)
			}
		} else if conn.role == "client" {
			if group.clients[conn.id] == conn {
				delete(group.clients, conn.id)
			}
			if group.host != nil {
				peers = append(peers, group.host)
			}
		}
		if group.host == nil && len(group.clients) == 0 {
			delete(h.hosts, conn.hostID)
		}
		h.mu.Unlock()
		online := false
		for _, peer := range peers {
			peer.sendControl(controlMessage{Type: "peer", ConnectionID: conn.id.String(), Role: conn.role, TransportOnline: &online})
		}
	})
}

func (h *Hub) readLoop(ctx context.Context, source *connection) error {
	for {
		messageType, data, err := source.socket.Read(ctx)
		if err != nil {
			return err
		}
		if messageType == websocket.MessageText {
			if err := h.handleControl(ctx, source, data); err != nil {
				return err
			}
			continue
		}
		if messageType != websocket.MessageBinary {
			return errors.New("clients may send binary or control messages only")
		}
		if int64(len(data)) > h.config.WebSocketFrameLimit || len(data) < 17 || data[0] != ProtocolVersion {
			return errors.New("invalid binary frame")
		}
		if err := h.route(source, data); err != nil {
			if !source.sendControl(controlMessage{Type: "error", Code: "invalid_destination"}) {
				return err
			}
		}
	}
}

// handleControl accepts the small set of text messages a peer may send. Today that is only a
// re-authentication carrying a fresh access token, which moves the connection's expiry forward.
func (h *Hub) handleControl(ctx context.Context, source *connection, data []byte) error {
	if int64(len(data)) > maximumControlBytes {
		return errors.New("control message too large")
	}
	var message inboundControl
	if err := json.Unmarshal(data, &message); err != nil {
		return fmt.Errorf("decode control message: %w", err)
	}
	if message.Type != "auth" {
		return fmt.Errorf("unsupported control message %q", message.Type)
	}
	if h.authenticate == nil {
		return errors.New("re-authentication is unavailable")
	}
	device, err := h.authenticate(ctx, message.AccessToken, time.Now())
	if err != nil {
		slog.Info("rejecting relay re-authentication",
			"host_id", source.hostID, "role", source.role,
			"connection_id", source.id.String(), "reason", err.Error())
		return fmt.Errorf("re-authenticate: %w", err)
	}
	// A token for a different device must never extend this one's connection.
	if device.ID != source.deviceID {
		return errors.New("re-authentication is for another device")
	}
	source.extendUntil(time.Unix(device.AccessExpiresAt, 0))
	if !source.sendControl(controlMessage{Type: "auth_ok", ExpiresAt: device.AccessExpiresAt}) {
		return errors.New("auth acknowledgement queue unavailable")
	}
	return nil
}

func (h *Hub) route(source *connection, frame []byte) error {
	destination, err := uuid.FromBytes(frame[1:17])
	if err != nil {
		return ErrInvalidDestination
	}
	isZero := destination == uuid.Nil
	h.mu.RLock()
	group := h.hosts[source.hostID]
	var recipients []*connection
	if group != nil && source.role == "client" {
		if group.host != nil && (isZero || group.host.id == destination) {
			recipients = append(recipients, group.host)
		}
	} else if group != nil && source.role == "host" {
		if isZero {
			for _, client := range group.clients {
				recipients = append(recipients, client)
			}
		} else if client := group.clients[destination]; client != nil {
			recipients = append(recipients, client)
		}
	}
	h.mu.RUnlock()
	if len(recipients) == 0 {
		return ErrInvalidDestination
	}
	delivered := append([]byte(nil), frame...)
	copy(delivered[1:17], source.id[:])
	for _, recipient := range recipients {
		if !recipient.sendWithin(recipient.ctx, outboundMessage{typeCode: websocket.MessageBinary, data: delivered},
			h.config.SlowReceiverGrace) {
			slog.Warn("closing slow relay receiver",
				"host_id", recipient.hostID, "role", recipient.role,
				"connection_id", recipient.id.String(), "device_id", recipient.deviceID,
				"queue_depth", h.config.WebSocketQueueDepth, "grace", h.config.SlowReceiverGrace)
			recipient.cancel()
			_ = recipient.socket.Close(websocket.StatusTryAgainLater, "receiver too slow")
		}
	}
	return nil
}

func (h *Hub) writeLoop(ctx context.Context, conn *connection) error {
	ticker := time.NewTicker(h.config.HeartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case message := <-conn.outbound:
			writeCtx, cancel := context.WithTimeout(ctx, h.config.HeartbeatTimeout)
			err := conn.socket.Write(writeCtx, message.typeCode, message.data)
			cancel()
			if err != nil {
				return err
			}
		case <-ticker.C:
			pingCtx, cancel := context.WithTimeout(ctx, h.config.HeartbeatTimeout)
			err := conn.socket.Ping(pingCtx)
			cancel()
			if err != nil {
				return err
			}
		}
	}
}

func (c *connection) sendControl(message controlMessage) bool {
	data, err := json.Marshal(message)
	if err != nil {
		return false
	}
	return c.send(outboundMessage{typeCode: websocket.MessageText, data: data})
}

func (c *connection) send(message outboundMessage) bool {
	select {
	case c.outbound <- message:
		return true
	default:
		return false
	}
}

// sendWithin waits a bounded time for room in the queue before giving up. A burst of terminal
// output used to overflow the queue instantly and cost the reader its connection; waiting here
// pushes back on the sender instead, which is what a relay should do with a slow consumer.
func (c *connection) sendWithin(ctx context.Context, message outboundMessage, wait time.Duration) bool {
	if c.send(message) {
		return true
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case c.outbound <- message:
		return true
	case <-timer.C:
		return false
	case <-ctx.Done():
		return false
	}
}

func closeReason(err error) string {
	if err == nil {
		return "closed"
	}
	if errors.Is(err, context.Canceled) {
		return "access token expired or connection cancelled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "write timed out"
	}
	return err.Error()
}
