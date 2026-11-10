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
	mu  sync.Mutex
	w   *bufio.Writer
	log struct {
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

func (e *events) listening(port int, secret string) {
	e.emit(map[string]any{"type": "listening", "port": port, "secret": secret})
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
