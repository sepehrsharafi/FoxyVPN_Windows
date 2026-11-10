package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// UDP ASSOCIATE: mirrors lib/tunnel/socks_server.dart and udp_relay.dart.
// The association (a loopback UDP socket) lives as long as its TCP control
// connection. DNS (port 53) goes to DoH; every other (association, target)
// pair gets one CONNECT-UDP stream carrying RFC 9297 DATAGRAM capsules
// (type 0, varint length, context id 0 + payload).

var udpIdleTimeout = 60 * time.Second // a var for tests

const (
	maxUDPFlows       = 32
	maxQueuedUDPBytes = 256 * 1024 // per flow, beyond this datagrams are dropped
	maxCapsuleBytes   = 65535 + 16
	maxConcurrentDNS  = 32
	maxUDPDatagram    = 64 << 10
)

type udpAssoc struct {
	s  *socksServer
	pc *net.UDPConn

	mu     sync.Mutex
	flows  map[string]*udpFlow
	closed bool
}

func (s *socksServer) udpAssociate(c net.Conn, r *bufio.Reader) {
	pc, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		c.Write(zeroReply(1))
		return
	}
	a := &udpAssoc{s: s, pc: pc, flows: map[string]*udpFlow{}}
	if _, err := c.Write(socksReply(0, netip.AddrFrom4([4]byte{127, 0, 0, 1}), pc.LocalAddr().(*net.UDPAddr).Port)); err != nil {
		pc.Close()
		return
	}
	_ = c.SetDeadline(time.Time{})
	go a.readLoop()
	// The association lasts as long as the TCP control connection.
	io.Copy(io.Discard, r)
	a.close()
}

func (a *udpAssoc) close() {
	a.mu.Lock()
	a.closed = true
	fl := make([]*udpFlow, 0, len(a.flows))
	for _, f := range a.flows {
		fl = append(fl, f)
	}
	a.mu.Unlock()
	a.pc.Close()
	for _, f := range fl {
		f.close()
	}
}

func (a *udpAssoc) flowCount() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.flows)
}

// parseSocksUDP parses the header of a SOCKS5 UDP datagram (RFC 1928 section
// 7). Not ok if malformed, an unknown address type, or a fragment.
func parseSocksUDP(d []byte) (host string, port, headerLen int, ok bool) {
	if len(d) < 10 || d[2] != 0 {
		return
	}
	switch d[3] {
	case 1:
		headerLen = 10
		host = netip.AddrFrom4([4]byte(d[4:8])).String()
	case 4:
		headerLen = 4 + 16 + 2
		if len(d) < headerLen {
			return
		}
		host = netip.AddrFrom16([16]byte(d[4:20])).String()
	case 3:
		headerLen = 4 + 1 + int(d[4]) + 2
		if len(d) < headerLen {
			return
		}
		host = string(d[5 : 5+int(d[4])])
	default:
		return
	}
	port = int(d[headerLen-2])<<8 | int(d[headerLen-1])
	return host, port, headerLen, true
}

func (a *udpAssoc) readLoop() {
	buf := make([]byte, maxUDPDatagram+300)
	dnsSem := make(chan struct{}, maxConcurrentDNS)
	for {
		n, from, err := a.pc.ReadFromUDPAddrPort(buf)
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			// e.g. WSAECONNRESET after a reply to a gone client port: harmless.
			time.Sleep(time.Millisecond)
			continue
		}
		d := buf[:n]
		host, port, hl, ok := parseSocksUDP(d)
		if !ok || n <= hl {
			continue
		}
		if port == 53 {
			// Mozilla's edge prohibits UDP port 53: DNS goes over DoH.
			select {
			case dnsSem <- struct{}{}:
			default:
				continue
			}
			go func(msg []byte, hl int, from netip.AddrPort) {
				defer func() { <-dnsSem }()
				a.answerDNS(msg, hl, from)
			}(bytes.Clone(d), hl, from)
			continue
		}
		a.send(host, port, d[:hl], d[hl:], from)
	}
}

func (a *udpAssoc) answerDNS(msg []byte, hl int, from netip.AddrPort) {
	query := msg[hl:]
	answer, err := a.s.doh.resolve(query)
	if err != nil {
		return
	}
	a.s.st.up.Add(int64(len(query)))
	out := make([]byte, 0, hl+len(answer))
	out = append(append(out, msg[:hl]...), answer...)
	a.s.st.down.Add(int64(len(answer)))
	a.pc.WriteToUDPAddrPort(out, from)
}

// send forwards one datagram from the client to host:port. Datagrams for a
// rejected destination, or beyond the flow cap, are dropped.
func (a *udpAssoc) send(host string, port int, header, payload []byte, from netip.AddrPort) {
	key := strings.ToLower(host) + ":" + itoa(port)
	if a.s.rej.isRejected(key) {
		return
	}
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return
	}
	fl := a.flows[key]
	if fl == nil {
		if len(a.flows) >= maxUDPFlows {
			a.mu.Unlock()
			return
		}
		fl = newUDPFlow(a, key, host, port)
		a.flows[key] = fl
		go fl.run()
	}
	a.mu.Unlock()
	fl.setReply(header, from)
	fl.enqueue(encodeDatagramCapsule(payload), len(payload))
}

// ---------------------------------------------------------------------------
// Capsules (RFC 9297, varints from RFC 9000 section 16)
// ---------------------------------------------------------------------------

func varintLen(v int) int {
	switch {
	case v < 1<<6:
		return 1
	case v < 1<<14:
		return 2
	case v < 1<<30:
		return 4
	}
	return 8
}

// encodeDatagramCapsule builds a DATAGRAM capsule carrying payload (context
// id 0) in one exactly sized buffer.
func encodeDatagramCapsule(payload []byte) []byte {
	length := len(payload) + 1 // context id + payload
	ll := varintLen(length)
	out := make([]byte, 1+ll+length)
	// out[0]: capsule type 0x00, a 1-byte varint.
	for i := 0; i < ll; i++ {
		out[1+i] = byte(length >> (8 * (ll - 1 - i)))
	}
	switch ll {
	case 2:
		out[1] |= 0x40
	case 4:
		out[1] |= 0x80
	case 8:
		out[1] |= 0xc0
	}
	// out[1+ll]: context id 0, then the plain UDP payload.
	copy(out[2+ll:], payload)
	return out
}

// readVarint reads a QUIC variable-length integer.
func readVarint(r *bufio.Reader) (int, error) {
	first, err := r.ReadByte()
	if err != nil {
		return 0, err
	}
	n := 1 << (first >> 6)
	v := int(first & 0x3f)
	for i := 1; i < n; i++ {
		b, err := r.ReadByte()
		if err != nil {
			return 0, err
		}
		v = v<<8 | int(b)
	}
	return v, nil
}

// ---------------------------------------------------------------------------
// One CONNECT-UDP flow
// ---------------------------------------------------------------------------

type udpItem struct {
	b       []byte // the capsule
	payload int
}

type udpFlow struct {
	a         *udpAssoc
	key       string
	host      string
	port      int
	ctx       context.Context
	cancel    context.CancelFunc
	ch        chan udpItem // capsules waiting for the stream (also while it opens)
	queued    atomic.Int64
	closed    atomic.Bool
	last      atomic.Int64 // time.Since(flowEpoch) of the last datagram either way
	idleTimer *time.Timer

	mu     sync.Mutex
	header []byte         // the client's SOCKS UDP header, reused for replies
	from   netip.AddrPort // where replies go
}

var flowEpoch = time.Now()

func newUDPFlow(a *udpAssoc, key, host string, port int) *udpFlow {
	ctx, cancel := context.WithCancel(context.Background())
	f := &udpFlow{a: a, key: key, host: host, port: port, ctx: ctx, cancel: cancel, ch: make(chan udpItem, 64)}
	a.s.udpFlows.Add(1)
	f.touch()
	f.idleTimer = time.AfterFunc(udpIdleTimeout, f.checkIdle)
	return f
}

func (f *udpFlow) touch() { f.last.Store(int64(time.Since(flowEpoch))) }

// checkIdle: one timer per flow that re-arms itself for the remainder when
// it fires early, instead of being reset for every packet.
func (f *udpFlow) checkIdle() {
	if f.closed.Load() {
		return
	}
	left := udpIdleTimeout - (time.Since(flowEpoch) - time.Duration(f.last.Load()))
	if left <= 0 {
		f.close()
		return
	}
	f.idleTimer.Reset(left)
}

func (f *udpFlow) setReply(header []byte, from netip.AddrPort) {
	f.mu.Lock()
	if !bytes.Equal(f.header, header) {
		f.header = bytes.Clone(header)
	}
	f.from = from
	f.mu.Unlock()
}

// enqueue queues a capsule for the stream; dropped if the flow already has
// maxQueuedUDPBytes waiting (the stream is slower than the sender).
func (f *udpFlow) enqueue(capsule []byte, payload int) {
	if f.closed.Load() {
		return
	}
	if f.queued.Add(int64(len(capsule))) > maxQueuedUDPBytes {
		f.queued.Add(-int64(len(capsule)))
		return
	}
	select {
	case f.ch <- udpItem{capsule, payload}:
		f.touch()
	default:
		f.queued.Add(-int64(len(capsule)))
	}
}

func (f *udpFlow) close() {
	if !f.closed.CompareAndSwap(false, true) {
		return
	}
	f.idleTimer.Stop()
	f.a.s.udpFlows.Add(-1)
	f.cancel() // ends the stream (RST_STREAM) and unblocks run and the reader
	f.a.mu.Lock()
	if f.a.flows[f.key] == f {
		delete(f.a.flows, f.key)
	}
	f.a.mu.Unlock()
}

func (f *udpFlow) run() {
	defer f.close()
	s := f.a.s
	resp, pw, oe := s.f.openStream(f.ctx, f.cancel, "UDP", f.host, f.port)
	if oe != nil {
		if f.closed.Load() {
			return // the association ended meanwhile: not the edge's doing
		}
		s.openFailed(oe)
		switch {
		case oe.authProblem():
			s.rej.reject(f.key, transientFailureTTL)
		case oe.status != 0:
			life := rejectLifetime(f.port, oe.proxyStatus)
			s.rej.reject(f.key, life)
			s.ev.logf(fmt.Sprintf("UDP to %s:%d refused by Mozilla's server (HTTP %d); ignoring it for %s",
				f.host, f.port, oe.status, lifeText(life)))
		default:
			s.rej.reject(f.key, transientFailureTTL)
		}
		return
	}
	defer resp.Body.Close()
	defer pw.CloseWithError(io.ErrClosedPipe)
	if f.closed.Load() {
		return
	}
	go f.readStream(resp.Body)

	for {
		select {
		case it := <-f.ch:
			f.queued.Add(-int64(len(it.b)))
			if _, err := pw.Write(it.b); err != nil {
				return
			}
			s.st.up.Add(int64(it.payload))
		case <-f.ctx.Done():
			return
		}
	}
}

func lifeText(d time.Duration) string {
	if d >= time.Minute {
		return fmt.Sprintf("%d minutes", int(d/time.Minute))
	}
	return fmt.Sprintf("%d seconds", int(d/time.Second))
}

// readStream parses capsules from the response and sends each datagram to
// the client with the header it used. Allocation-free once the buffers have
// grown to the datagram size.
func (f *udpFlow) readStream(body io.Reader) {
	defer f.close()
	br := bufio.NewReaderSize(body, 32<<10)
	var capsule, out []byte
	for {
		typ, err := readVarint(br)
		if err != nil {
			return
		}
		length, err := readVarint(br)
		if err != nil {
			return
		}
		if length > 1<<30 {
			return
		}
		if length > maxCapsuleBytes { // skipped, not buffered
			if _, err := br.Discard(length); err != nil {
				return
			}
			continue
		}
		if cap(capsule) < length {
			capsule = make([]byte, length)
		}
		capsule = capsule[:length]
		if _, err := io.ReadFull(br, capsule); err != nil {
			return
		}
		if typ != 0 || length < 1 || capsule[0] != 0 { // only DATAGRAM, context id 0 (1-byte varint)
			continue
		}
		payload := capsule[1:]
		f.mu.Lock()
		out = append(append(out[:0], f.header...), payload...)
		from := f.from
		f.mu.Unlock()
		f.touch()
		f.a.s.st.down.Add(int64(len(payload)))
		f.a.pc.WriteToUDPAddrPort(out, from)
	}
}
