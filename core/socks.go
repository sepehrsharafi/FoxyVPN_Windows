package main

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync/atomic"
	"time"
)

// SOCKS5 server (RFC 1928, no authentication) on 127.0.0.1 for tun2socks.
// CONNECT becomes an upstream CONNECT stream; UDP ASSOCIATE answers port 53
// through DoH and relays the rest as CONNECT-UDP flows (udp.go). It mirrors
// lib/tunnel/socks_server.dart, minus the direct fallback (the engine never
// connects around the tunnel).

const socksHandshakeTimeout = 15 * time.Second

// stats counts payload bytes through the SOCKS server: up is from the
// client, down to it.
type stats struct {
	up, down atomic.Int64
}

// run emits a stats event every interval while the numbers changed.
func (s *stats) run(ev *events, every time.Duration) {
	var lu, ld int64
	for range time.Tick(every) {
		u, d := s.up.Load(), s.down.Load()
		if u != lu || d != ld {
			lu, ld = u, d
			ev.stats(u, d)
		}
	}
}

type socksServer struct {
	f   *flows
	ev  *events
	st  *stats
	rej *rejectCache
	doh *dohClient

	udpFlows atomic.Int64 // open CONNECT-UDP flows, all associations
}

func newSocksServer(f *flows, ev *events, st *stats) *socksServer {
	return &socksServer{f: f, ev: ev, st: st, rej: newRejectCache(), doh: newDoHClient(f, ev, dohHost, nil)}
}

func (s *socksServer) serve(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go s.handle(c)
	}
}

func socksReply(rep byte, ip netip.Addr, port int) []byte {
	if ip.Is4() {
		a := ip.As4()
		return []byte{5, rep, 0, 1, a[0], a[1], a[2], a[3], byte(port >> 8), byte(port)}
	}
	return []byte{5, rep, 0, 1, 0, 0, 0, 0, byte(port >> 8), byte(port)}
}

var zeroReply = func(rep byte) []byte { return socksReply(rep, netip.IPv4Unspecified(), 0) }

func (s *socksServer) handle(c net.Conn) {
	defer c.Close()
	if t, ok := c.(*net.TCPConn); ok {
		_ = t.SetNoDelay(true)
	}
	_ = c.SetDeadline(time.Now().Add(socksHandshakeTimeout))
	r := bufio.NewReaderSize(c, 512)

	// Greeting: only "no authentication" is offered.
	var head [4]byte
	if _, err := io.ReadFull(r, head[:2]); err != nil || head[0] != 5 {
		return
	}
	methods := make([]byte, head[1])
	if _, err := io.ReadFull(r, methods); err != nil {
		return
	}
	ok := false
	for _, m := range methods {
		ok = ok || m == 0
	}
	if !ok {
		c.Write([]byte{5, 0xff})
		return
	}
	if _, err := c.Write([]byte{5, 0}); err != nil {
		return
	}

	if _, err := io.ReadFull(r, head[:4]); err != nil || head[0] != 5 {
		return
	}
	host, port, err := readSocksAddr(r, head[3])
	if err != nil {
		c.Write(zeroReply(8)) // address type not supported
		return
	}
	switch head[1] {
	case 1:
		s.connect(c, r, host, port)
	case 3:
		s.udpAssociate(c, r)
	default:
		c.Write(zeroReply(7))
	}
}

func readSocksAddr(r *bufio.Reader, atyp byte) (string, int, error) {
	var host string
	var buf [256]byte
	switch atyp {
	case 1:
		if _, err := io.ReadFull(r, buf[:4]); err != nil {
			return "", 0, err
		}
		host = netip.AddrFrom4([4]byte(buf[:4])).String()
	case 4:
		if _, err := io.ReadFull(r, buf[:16]); err != nil {
			return "", 0, err
		}
		host = netip.AddrFrom16([16]byte(buf[:16])).String()
	case 3:
		n, err := r.ReadByte()
		if err != nil {
			return "", 0, err
		}
		if _, err := io.ReadFull(r, buf[:n]); err != nil {
			return "", 0, err
		}
		host = string(buf[:n])
	default:
		return "", 0, io.ErrUnexpectedEOF
	}
	if _, err := io.ReadFull(r, buf[:2]); err != nil {
		return "", 0, err
	}
	return host, int(buf[0])<<8 | int(buf[1]), nil
}

// openFailed tells the app about a token problem (it renews the pass).
func (s *socksServer) openFailed(oe *openError) {
	if oe.authProblem() {
		s.ev.authFailed()
	}
}

func (s *socksServer) connect(c net.Conn, r *bufio.Reader, host string, port int) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	resp, pw, oe := s.f.openStream(ctx, cancel, "TCP", host, port)
	if oe != nil {
		s.openFailed(oe)
		// The edge refuses this destination (502): "connection refused" (5);
		// anything else is "host unreachable" (4). The reply goes out at once
		// and the socket closes, so tun2socks ends the app's connection
		// instead of leaving it hanging.
		rep := byte(4)
		if oe.status == 502 {
			rep = 5
		}
		c.Write(zeroReply(rep))
		// Let the client read the reply before the FIN (a RST could eat it).
		if t, ok := c.(*net.TCPConn); ok {
			_ = t.CloseWrite()
			_ = c.SetReadDeadline(time.Now().Add(time.Second))
			io.Copy(io.Discard, r)
		}
		return
	}
	defer resp.Body.Close()
	if _, err := c.Write(zeroReply(0)); err != nil {
		pw.CloseWithError(io.ErrClosedPipe)
		return
	}
	_ = c.SetDeadline(time.Time{})
	bridge(c, r, resp.Body, pw, cancel, &s.st.up, &s.st.down)
}

func itoa(n int) string { return strconv.Itoa(n) }
