package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"sync"
	"time"

	"golang.org/x/net/http2"
)

const (
	redialMin = 1 * time.Second
	redialMax = 15 * time.Second
)

// extraRetry is how long a failed dial holds off topping the pool up again.
// Only extra connections wait for it: with none usable, flows dial at once.
const extraRetry = 10 * time.Second

// upstream is the pool of HTTP/2 connections to the edge. It keeps up to
// want connections open and puts each new flow on the least busy one, so a
// lost packet on one TCP connection stalls only its share of the flows.
// When the edge sends GOAWAY (rotation), or a connection is full or dead,
// a new one is dialed, and old ones keep serving their streams until they
// finish.
type upstream struct {
	ip, host string
	port     int
	ev       *events
	tr       *http2.Transport

	// want is the number of connections to keep open (at least 1).
	want int

	// dialFn makes one TLS connection. Replaced in tests.
	dialFn func(ctx context.Context) (net.Conn, string, error)

	mu       sync.Mutex
	conns    []*pconn
	dial     *dialState // dial in flight (singleflight), else nil
	failedAt time.Time  // last dial failure
	everUp   bool
	lost     bool // "lost" sent, "reconnected" not yet
	ensuring bool
	closed   bool
	errSent  bool
}

type pconn struct {
	cc       *http2.ClientConn
	w        *watchConn
	graceful bool // drained after GOAWAY and closed by us on purpose
}

type dialState struct {
	done chan struct{}
	err  error
}

func newUpstream(host string, port int, ip string, sndbuf int, ev *events) *upstream {
	// 2 MiB per stream (a flow can have that much in memory) and a big
	// connection window so one flow never waits for another's
	// WINDOW_UPDATE. ConfigureTransports is the supported way to set these
	// on a Transport that we drive through NewClientConn.
	t1 := &http.Transport{HTTP2: &http.HTTP2Config{
		MaxReceiveBufferPerStream:     2 << 20,
		MaxReceiveBufferPerConnection: 256 << 20,
	}}
	tr, err := http2.ConfigureTransports(t1)
	if err != nil {
		panic(err)
	}
	// Strict: never exceed the peer's MAX_CONCURRENT_STREAMS; a full
	// connection means "dial another" (see get) instead of queueing.
	tr.StrictMaxConcurrentStreams = true
	// Ping only after 10 s of nothing read: a busy connection is not dead.
	tr.ReadIdleTimeout = 10 * time.Second
	tr.PingTimeout = 10 * time.Second
	tr.WriteByteTimeout = 30 * time.Second
	tr.MaxReadFrameSize = 1 << 20
	// A proxy request carries only what the edge needs: no accept-encoding.
	tr.DisableCompression = true
	u := &upstream{ip: ip, host: host, port: port, ev: ev, tr: tr, want: 1}
	u.dialFn = func(ctx context.Context) (net.Conn, string, error) {
		return dialTLS(ctx, ip, host, port, sndbuf)
	}
	return u
}

// start dials the first connection and keeps trying (backoff) until one
// is up. The first failure is reported as an "error" event.
func (u *upstream) start() { u.ensure() }

// get returns a connection with a stream reserved on it, dialing if none
// can take a new stream. It does not wait for the redial backoff: a flow
// that needs a connection tries right now.
func (u *upstream) get(ctx context.Context) (*pconn, error) {
	for {
		u.mu.Lock()
		if u.closed {
			u.mu.Unlock()
			return nil, fmt.Errorf("engine closed")
		}
		if c := u.reserveLocked(); c != nil {
			u.topUpLocked()
			u.mu.Unlock()
			return c, nil
		}
		d := u.startDialLocked()
		u.mu.Unlock()
		select {
		case <-d.done:
			if d.err != nil {
				return nil, d.err
			}
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
}

// reserveLocked reserves a stream on the open connection with the fewest
// streams, or returns nil if none can take one.
func (u *upstream) reserveLocked() *pconn {
	tried := make([]bool, len(u.conns))
	for range u.conns {
		best, load := -1, 0
		for i, c := range u.conns {
			if tried[i] {
				continue
			}
			st := c.cc.State()
			if st.Closed || st.Closing {
				tried[i] = true
				continue
			}
			if l := st.StreamsActive + st.StreamsReserved + st.StreamsPending; best < 0 || l < load {
				best, load = i, l
			}
		}
		if best < 0 {
			break
		}
		tried[best] = true
		if u.conns[best].cc.ReserveNewRequest() {
			return u.conns[best]
		}
	}
	return nil
}

// openLocked counts connections that can still take new streams.
func (u *upstream) openLocked() int {
	n := 0
	for _, c := range u.conns {
		if st := c.cc.State(); !st.Closed && !st.Closing {
			n++
		}
	}
	return n
}

// topUpLocked dials one more connection in the background when the pool is
// short, unless a dial is running or one failed within extraRetry. Never
// blocks a flow.
func (u *upstream) topUpLocked() {
	if u.closed || u.dial != nil || u.openLocked() >= u.want || time.Since(u.failedAt) < extraRetry {
		return
	}
	u.startDialLocked()
}

func (u *upstream) startDialLocked() *dialState {
	if u.dial != nil {
		return u.dial
	}
	d := &dialState{done: make(chan struct{})}
	u.dial = d
	go u.runDial(d)
	return d
}

func (u *upstream) runDial(d *dialState) {
	// Not tied to the flow that triggered it: that flow may give up while
	// the connection is still useful for the next one.
	ctx, cancel := context.WithTimeout(context.Background(), dialTimeout+handshakeTimeout)
	defer cancel()
	nc, info, err := u.dialFn(ctx)
	var pc *pconn
	if err == nil {
		w := newWatchConn(nc)
		var cc *http2.ClientConn
		if cc, err = u.tr.NewClientConn(w); err != nil {
			nc.Close()
			err = fmt.Errorf("HTTP/2 setup: %w", err)
		} else {
			pc = &pconn{cc: cc, w: w}
		}
	}

	u.mu.Lock()
	var sendConnected, sendReconnected bool
	if pc != nil {
		if u.closed {
			pc.cc.Close()
			pc = nil
		} else {
			u.conns = append(u.conns, pc)
			sendConnected = !u.everUp
			sendReconnected = u.everUp && u.lost
			u.everUp, u.lost = true, false
		}
	}
	u.dial = nil
	d.err = err
	if err != nil {
		u.failedAt = time.Now()
	}
	u.mu.Unlock()
	close(d.done)

	if pc == nil {
		return
	}
	if sendConnected {
		u.ev.connected(info)
	} else if sendReconnected {
		u.ev.reconnected()
	} else {
		u.ev.logf("new upstream connection (" + info + ")")
	}
	go u.monitor(pc)

	// Fill the pool one connection at a time.
	u.mu.Lock()
	u.topUpLocked()
	u.mu.Unlock()
}

// ensure makes sure a usable connection exists, redialing with backoff
// (1 s doubling to 15 s). One loop at a time.
func (u *upstream) ensure() {
	u.mu.Lock()
	if u.ensuring || u.closed {
		u.mu.Unlock()
		return
	}
	u.ensuring = true
	u.mu.Unlock()
	go func() {
		defer func() { u.mu.Lock(); u.ensuring = false; u.mu.Unlock() }()
		backoff := redialMin
		for {
			u.mu.Lock()
			if u.closed || u.usableLocked() {
				u.mu.Unlock()
				return
			}
			d := u.startDialLocked()
			u.mu.Unlock()
			<-d.done
			if d.err == nil {
				return
			}
			u.mu.Lock()
			first := !u.everUp && !u.errSent
			u.errSent = u.errSent || first
			u.mu.Unlock()
			if first {
				u.ev.errorf(d.err.Error())
			} else {
				u.ev.logf("upstream dial failed: " + d.err.Error())
			}
			time.Sleep(backoff)
			backoff = min(backoff*2, redialMax)
		}
	}()
}

func (u *upstream) usableLocked() bool {
	for _, c := range u.conns {
		if st := c.cc.State(); !st.Closed && !st.Closing {
			return true
		}
	}
	return false
}

// monitor watches one connection: notes a GOAWAY (and dials the successor at
// once), closes it when it has drained, and reports how it ended.
func (u *upstream) monitor(pc *pconn) {
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	noted := false
loop:
	for {
		select {
		case <-pc.w.dead:
			break loop
		case <-tick.C:
			st := pc.cc.State()
			if st.Closing && !noted {
				noted = true
				text := pc.w.goawayText()
				if text == "" {
					text = "closing"
				}
				u.ev.logf("upstream connection draining: " + text)
				u.ensure()
				u.mu.Lock()
				u.topUpLocked()
				u.mu.Unlock()
			}
			if st.Closing && st.StreamsActive == 0 && st.StreamsReserved == 0 {
				u.mu.Lock()
				pc.graceful = true
				u.mu.Unlock()
				pc.w.end("drained after GOAWAY")
				pc.cc.Close()
			}
		}
	}
	pc.cc.Close()

	u.mu.Lock()
	for i, c := range u.conns {
		if c == pc {
			u.conns = append(u.conns[:i:i], u.conns[i+1:]...)
			break
		}
	}
	announce := !pc.graceful && !u.closed && !u.usableLocked() && !u.lost
	if announce {
		u.lost = true
	}
	closed := u.closed
	graceful := pc.graceful
	u.mu.Unlock()
	if closed {
		return
	}
	if announce {
		u.ev.lost(pc.w.why())
	} else if !graceful {
		u.ev.logf("upstream connection ended: " + pc.w.why())
	}
	u.ensure()
	u.mu.Lock()
	u.topUpLocked()
	u.mu.Unlock()
}

func (u *upstream) close() {
	u.mu.Lock()
	u.closed = true
	conns := u.conns
	u.mu.Unlock()
	for _, c := range conns {
		c.cc.Close()
	}
}
