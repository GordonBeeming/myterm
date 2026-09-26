package transport

import (
	"context"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
)

func newTestConnection(depth int) *connection {
	ctx, cancel := context.WithCancel(context.Background())
	return &connection{
		id: uuid.New(), hostID: "host", role: "client", deviceID: "device",
		outbound: make(chan outboundMessage, depth), ctx: ctx, cancel: cancel,
	}
}

func TestSendWithinWaitsForRoomInsteadOfFailingImmediately(t *testing.T) {
	conn := newTestConnection(1)
	defer conn.cancel()
	conn.outbound <- outboundMessage{typeCode: websocket.MessageBinary, data: []byte("first")}

	// A reader that drains shortly after the queue fills, which is the shape of a client that is
	// briefly behind during a burst of output rather than one that is actually gone.
	go func() {
		time.Sleep(50 * time.Millisecond)
		<-conn.outbound
	}()

	if !conn.sendWithin(conn.ctx, outboundMessage{typeCode: websocket.MessageBinary, data: []byte("second")},
		2*time.Second) {
		t.Fatal("a briefly slow receiver must not be dropped while there is still grace left")
	}
}

func TestSendWithinGivesUpOnAReceiverThatNeverDrains(t *testing.T) {
	conn := newTestConnection(1)
	defer conn.cancel()
	conn.outbound <- outboundMessage{typeCode: websocket.MessageBinary, data: []byte("first")}

	start := time.Now()
	if conn.sendWithin(conn.ctx, outboundMessage{typeCode: websocket.MessageBinary, data: []byte("second")},
		100*time.Millisecond) {
		t.Fatal("a receiver that never drains has to be given up on")
	}
	if elapsed := time.Since(start); elapsed < 100*time.Millisecond {
		t.Fatalf("gave up after %s, before the grace period elapsed", elapsed)
	}
}

func TestSendWithinStopsWaitingWhenTheConnectionIsCancelled(t *testing.T) {
	conn := newTestConnection(1)
	conn.outbound <- outboundMessage{typeCode: websocket.MessageBinary, data: []byte("first")}
	go func() {
		time.Sleep(20 * time.Millisecond)
		conn.cancel()
	}()

	if conn.sendWithin(conn.ctx, outboundMessage{typeCode: websocket.MessageBinary, data: []byte("second")},
		10*time.Second) {
		t.Fatal("a cancelled connection must not keep holding the sender")
	}
}

func TestExtendUntilKeepsTheConnectionAliveAcrossATokenRefresh(t *testing.T) {
	conn := newTestConnection(1)
	defer conn.stopExpiry()
	conn.extendUntil(time.Now().Add(80 * time.Millisecond))

	// The refreshed token lands before the first expiry, exactly as a live client re-authenticating.
	time.Sleep(40 * time.Millisecond)
	conn.extendUntil(time.Now().Add(2 * time.Second))

	select {
	case <-conn.ctx.Done():
		t.Fatal("re-authenticating must move the expiry out, not leave the original deadline")
	case <-time.After(150 * time.Millisecond):
	}
}

func TestExpiryClosesTheConnectionWhenNothingRefreshesIt(t *testing.T) {
	conn := newTestConnection(1)
	defer conn.stopExpiry()
	conn.extendUntil(time.Now().Add(50 * time.Millisecond))

	select {
	case <-conn.ctx.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("a connection whose token expired with no refresh has to be closed")
	}
}

func TestExtendUntilClosesImmediatelyForATokenThatHasAlreadyExpired(t *testing.T) {
	conn := newTestConnection(1)
	defer conn.stopExpiry()
	conn.extendUntil(time.Now().Add(-time.Second))

	select {
	case <-conn.ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("an expired token must not extend a connection")
	}
}
