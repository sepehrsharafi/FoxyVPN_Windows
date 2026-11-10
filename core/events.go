package main

import (
	"bufio"
	"encoding/json"
	"io"
	"sync"
	"time"
)

// events writes the JSON lines Dart reads on our stdout. One object per
// line, flushed right away; the mutex keeps lines from interleaving.
type events struct {
	mu       sync.Mutex
	lastAuth time.Time
	w        *bufio.Writer
	log      struct {
		window time.Time
		count  int
	}
}

func newEvents(w io.Writer) *events { return &events{w: bufio.NewWriter(w)} }

func (e *events) emit(v map[string]any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.w.Write(b)
	e.w.WriteByte('\n')
	e.w.Flush() // if stdout is gone the app is gone too; stdin EOF ends us
}

// listening: socksPort 0 means the SOCKS server is off.
func (e *events) listening(port int, secret string, socksPort int) {
	m := map[string]any{"type": "listening", "port": port, "secret": secret}
	if socksPort > 0 {
		m["socks_port"] = socksPort
	}
	e.emit(m)
}

func (e *events) connected(tls string) { e.emit(map[string]any{"type": "connected", "tls": tls}) }
func (e *events) reconnected()         { e.emit(map[string]any{"type": "reconnected"}) }
func (e *events) lost(reason string)   { e.emit(map[string]any{"type": "lost", "reason": reason}) }
func (e *events) errorf(msg string)    { e.emit(map[string]any{"type": "error", "msg": msg}) }

// logf is for diagnostics, never per flow. At most 20 lines per 10 s so a
// misbehaving edge cannot flood the app's log; the rest are dropped.
func (e *events) logf(msg string) {
	e.mu.Lock()
	now := time.Now()
	if now.Sub(e.log.window) > 10*time.Second {
		e.log.window, e.log.count = now, 0
	}
	e.log.count++
	drop := e.log.count > 20
	e.mu.Unlock()
	if !drop {
		e.emit(map[string]any{"type": "log", "msg": msg})
	}
}

func (e *events) stats(up, down int64) {
	e.emit(map[string]any{"type": "stats", "up": up, "down": down})
}

// authFailed tells the app the edge rejected our token (it renews the pass
// and sends a new token line). At most one per 5 s.
func (e *events) authFailed() {
	e.mu.Lock()
	now := time.Now()
	if !e.lastAuth.IsZero() && now.Sub(e.lastAuth) < authFailedEvery {
		e.mu.Unlock()
		return
	}
	e.lastAuth = now
	e.mu.Unlock()
	e.emit(map[string]any{"type": "auth_failed"})
}

const authFailedEvery = 5 * time.Second
