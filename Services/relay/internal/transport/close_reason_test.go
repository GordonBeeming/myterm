package transport

import (
	"context"
	"errors"
	"testing"
)

// Every teardown cancels the connection, so a cancellation on its own carried no information.
// These assert that a close names what actually happened.
func TestCloseReasonPrefersTheRecordedCause(t *testing.T) {
	for _, tc := range []struct {
		name  string
		err   error
		cause string
		want  string
	}{
		{"revoked device", context.Canceled, "device session revoked", "device session revoked"},
		{"expired token", context.Canceled,
			"access token expired without an in-band refresh",
			"access token expired without an in-band refresh"},
		{"evicted by host", context.Canceled, "host ended this client connection",
			"host ended this client connection"},
		{"slow receiver", context.Canceled, "receiver too slow to keep up with its peer",
			"receiver too slow to keep up with its peer"},
		{"ordinary close", context.Canceled, "connection closed", "connection closed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := closeReason(tc.err, tc.cause); got != tc.want {
				t.Fatalf("closeReason = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestCloseReasonSaysWhenACancellationHasNoCause(t *testing.T) {
	got := closeReason(context.Canceled, "")
	if got != "cancelled without a recorded cause" {
		t.Fatalf("closeReason = %q", got)
	}
	// The old string blamed token expiry for every cancellation, which sent a week of debugging
	// in the wrong direction. It must not come back as a default.
	if got == "access token expired or connection cancelled" {
		t.Fatal("an uncaused cancellation must not be reported as token expiry")
	}
}

func TestCloseReasonNamesAStalledReaderRatherThanTheRelay(t *testing.T) {
	got := closeReason(context.DeadlineExceeded, "")
	if got != "write timed out: peer stopped reading" {
		t.Fatalf("closeReason = %q", got)
	}
}

func TestCloseReasonKeepsATransportErrorVerbatim(t *testing.T) {
	err := errors.New("failed to get reader: received close frame: status = StatusProtocolError")
	if got := closeReason(err, "connection closed"); got != err.Error() {
		t.Fatalf("a real transport error must outrank the teardown cause, got %q", got)
	}
}

func TestCloseReasonWithNoErrorUsesTheCause(t *testing.T) {
	if got := closeReason(nil, "device session revoked"); got != "device session revoked" {
		t.Fatalf("closeReason = %q", got)
	}
	if got := closeReason(nil, ""); got != "closed" {
		t.Fatalf("closeReason = %q", got)
	}
}

func TestCancellationCauseKeepsTheFirstReason(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	conn := &connection{ctx: ctx, cancel: cancel}

	conn.cancelBecause("receiver too slow to keep up with its peer")
	// unregister cancels again on the way out; the vaguer reason must not win.
	conn.cancelBecause("connection closed")

	if got := conn.cancellationCause(); got != "receiver too slow to keep up with its peer" {
		t.Fatalf("cause = %q, want the first one recorded", got)
	}
}

func TestCancellationCauseIsEmptyUntilSomethingCancels(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	conn := &connection{ctx: ctx, cancel: cancel}

	if got := conn.cancellationCause(); got != "" {
		t.Fatalf("cause = %q, want empty", got)
	}
}
