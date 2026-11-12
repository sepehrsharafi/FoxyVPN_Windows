package main

import (
	"context"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func countType(s, typ string) int { return strings.Count(s, `"type":"`+typ+`"`) }

func TestAuthFailedTrailing(t *testing.T) {
	old := authFailedEvery
	authFailedEvery = 200 * time.Millisecond
	defer func() { authFailedEvery = old }()
	sink := newLineSink()
	ev := newEvents(sink)
	ev.authFailed() // emitted now
	for i := 0; i < 5; i++ {
		ev.authFailed() // suppressed; only one queued
	}
	if n := countType(sink.all(), "auth_failed"); n != 1 {
		t.Fatalf("immediately: %d auth_failed, want 1", n)
	}
	time.Sleep(350 * time.Millisecond)
	if n := countType(sink.all(), "auth_failed"); n != 2 {
		t.Fatalf("after window: %d auth_failed, want 2", n)
	}
	time.Sleep(450 * time.Millisecond)
	if n := countType(sink.all(), "auth_failed"); n != 2 {
		t.Fatalf("later: %d auth_failed, want still 2", n)
	}
}

// ctxReader blocks until ctx ends (like a response body of a stalled stream),
// delivering anything sent on feed first.
type ctxReader struct {
	ctx  context.Context
	feed chan []byte
}

func (r *ctxReader) Read(p []byte) (int, error) {
	select {
	case b := <-r.feed:
		return copy(p, b), nil
	case <-r.ctx.Done():
		return 0, r.ctx.Err()
	}
}

func TestBridgeHalfCloseIdle(t *testing.T) {
	old := halfCloseIdle
	halfCloseIdle = 300 * time.Millisecond
	defer func() { halfCloseIdle = old }()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cl, srv := net.Pipe()
	defer cl.Close()
	go io.Copy(io.Discard, cl)
	pr, pw := io.Pipe()
	go io.Copy(io.Discard, pr)
	body := &ctxReader{ctx, make(chan []byte)}
	var up, down atomic.Int64
	done := make(chan struct{})
	go func() {
		bridge(srv, strings.NewReader("hi"), body, pw, cancel, &up, &down)
		close(done)
	}()
	// Active download: bytes keep arriving past the idle limit; not cut.
	start := time.Now()
	for time.Since(start) < 900*time.Millisecond {
		select {
		case body.feed <- []byte("x"):
		case <-done:
			t.Fatal("stream cut while download active")
		}
		time.Sleep(50 * time.Millisecond)
	}
	// Download stalls: cut after the idle limit.
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("idle half-closed stream not cancelled")
	}
	if ctx.Err() == nil {
		t.Fatal("cancel not called")
	}
}
