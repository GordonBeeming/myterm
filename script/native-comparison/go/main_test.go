package main

import (
	"io"
	"strings"
	"sync"
	"testing"
	"time"
)

type blockedInput struct {
	release  chan struct{}
	finished chan struct{}
	once     sync.Once
}

func (p *blockedInput) Write(_ []byte) (int, error) {
	<-p.release
	close(p.finished)
	return 0, io.ErrClosedPipe
}
func (p *blockedInput) Kill() error { p.once.Do(func() { close(p.release) }); return nil }
func TestBlockedPTYWriteTerminatesChildWithoutWaitingForSocket(t *testing.T) {
	p := &blockedInput{release: make(chan struct{}), finished: make(chan struct{})}
	err := writeBounded(p, []byte("input"), 20*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "timeout") {
		t.Fatalf("expected timeout, got %v", err)
	}
	select {
	case <-p.finished:
	case <-time.After(time.Second):
		t.Fatal("child termination did not release blocked write")
	}
}
