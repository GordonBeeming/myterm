package transport

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"github.com/gordonbeeming/myterm/relay/internal/config"
	"github.com/gordonbeeming/myterm/relay/internal/store"
)

const ProtocolVersion byte = 1

type Hub struct {
	mu     sync.RWMutex
	hosts  map[string]*hostGroup
	config config.Config
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
	cancel   context.CancelFunc
	once     sync.Once
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
	ctx, cancel := context.WithDeadline(r.Context(), time.Unix(device.AccessExpiresAt, 0))
	conn := &connection{
		id: uuid.New(), hostID: host.ID, role: role, deviceID: device.ID,
		socket: socket, outbound: make(chan outboundMessage, h.config.WebSocketQueueDepth), cancel: cancel,
	}
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
		if messageType != websocket.MessageBinary {
			return errors.New("clients may send binary messages only")
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
		if !recipient.send(outboundMessage{typeCode: websocket.MessageBinary, data: delivered}) {
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
