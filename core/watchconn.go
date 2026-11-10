package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"time"
)

// watchConn wraps the TLS connection under an http2.ClientConn so we learn
// how it ended: x/net exposes neither the read error nor the GOAWAY
// code/debug text, and we want both in the "lost" event. It also notes the
// time of the last byte read.
type watchConn struct {
	net.Conn
	born time.Time

	once sync.Once
	dead chan struct{} // closed when the connection is over

	mu     sync.Mutex
	reason string // first reason recorded
	goaway string // text of the last GOAWAY frame seen, if any

	// Minimal HTTP/2 frame scanner over the bytes read, only to find GOAWAY
	// (type 7). hdr collects the 9-byte frame header; left counts payload
	// bytes still to skip; the first bytes of a GOAWAY payload go to ga.
	hdr  [9]byte
	hn   int
	left int
	typ  byte
	ga   []byte
}

func newWatchConn(c net.Conn) *watchConn {
	return &watchConn{Conn: c, born: time.Now(), dead: make(chan struct{})}
}

func (w *watchConn) Read(p []byte) (int, error) {
	n, err := w.Conn.Read(p)
	if n > 0 {
		w.scan(p[:n])
	}
	if err != nil {
		w.end("read: " + describeErr(err))
	}
	return n, err
}

func (w *watchConn) Write(p []byte) (int, error) {
	n, err := w.Conn.Write(p)
	if err != nil {
		w.end("write: " + describeErr(err))
	}
	return n, err
}

// Close is called by x/net on ping timeout, GOAWAY handling and by us.
func (w *watchConn) Close() error {
	w.end("closed by us (ping timeout, idle or shutdown)")
	return w.Conn.Close()
}

func (w *watchConn) end(reason string) {
	w.once.Do(func() {
		w.mu.Lock()
		w.reason = reason
		w.mu.Unlock()
		close(w.dead)
	})
}

// why describes how the connection ended, with the GOAWAY text if the edge
// sent one.
func (w *watchConn) why() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	s := w.reason
	if w.goaway != "" {
		s = w.goaway + "; " + s
	}
	return fmt.Sprintf("%s; age %.0fs", s, time.Since(w.born).Seconds())
}

func (w *watchConn) goawayText() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.goaway
}

func (w *watchConn) scan(p []byte) {
	for len(p) > 0 {
		if w.left == 0 && w.hn < 9 {
			k := copy(w.hdr[w.hn:], p)
			w.hn += k
			p = p[k:]
			if w.hn < 9 {
				return
			}
			w.left = int(w.hdr[0])<<16 | int(w.hdr[1])<<8 | int(w.hdr[2])
			w.typ = w.hdr[3]
			w.ga = nil
			if w.typ == 7 {
				w.ga = make([]byte, 0, 256)
			}
			if w.left == 0 {
				w.hn = 0
			}
			continue
		}
		k := min(w.left, len(p))
		if w.typ == 7 && len(w.ga) < 256 {
			w.ga = append(w.ga, p[:min(k, 256-len(w.ga))]...)
		}
		w.left -= k
		p = p[k:]
		if w.left == 0 {
			if w.typ == 7 && len(w.ga) >= 8 {
				code := binary.BigEndian.Uint32(w.ga[4:8])
				text := fmt.Sprintf("GOAWAY code=%d", code)
				if len(w.ga) > 8 {
					text += fmt.Sprintf(" debug=%q", w.ga[8:])
				}
				w.mu.Lock()
				w.goaway = text
				w.mu.Unlock()
			}
			w.hn = 0
		}
	}
}

// describeErr tells apart a clean TLS close from a bare FIN or a reset: the
// first is the server closing on purpose, the others are usually something
// on the way (a firewall) cutting the connection.
func describeErr(err error) string {
	switch {
	case errors.Is(err, io.EOF):
		return "EOF (clean TLS close_notify)"
	case errors.Is(err, io.ErrUnexpectedEOF):
		return "TCP FIN without TLS close_notify"
	case errors.Is(err, net.ErrClosed):
		return "closed"
	}
	s := strings.Join(strings.Fields(err.Error()), " ")
	if strings.Contains(s, "reset") || strings.Contains(s, "forcibly closed") || strings.Contains(s, "aborted") {
		return "TCP reset (" + s + ")"
	}
	return s
}
