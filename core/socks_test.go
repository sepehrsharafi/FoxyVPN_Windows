package main

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/json"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// ---- SOCKS client helpers --------------------------------------------------

func socksGreet(t *testing.T, port int) (*net.TCPConn, *bufio.Reader) {
	t.Helper()
	c, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(15 * time.Second))
	c.Write([]byte{5, 1, 0})
	r := bufio.NewReader(c)
	var rep [2]byte
	if _, err := io.ReadFull(r, rep[:]); err != nil || rep != [2]byte{5, 0} {
		t.Fatalf("greeting reply %v %v", rep, err)
	}
	return c.(*net.TCPConn), r
}

func socksAddr(host string, port int) []byte {
	var b []byte
	if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
		b = append([]byte{1}, ip.To4()...)
	} else if ip != nil {
		b = append([]byte{4}, ip.To16()...)
	} else {
		b = append([]byte{3, byte(len(host))}, host...)
	}
	return append(b, byte(port>>8), byte(port))
}

// socksRequest sends cmd for host:port and returns the REP and BND port.
func socksRequest(t *testing.T, c net.Conn, r *bufio.Reader, cmd byte, host string, port int) (byte, int) {
	t.Helper()
	c.Write(append([]byte{5, cmd, 0}, socksAddr(host, port)...))
	var rep [10]byte
	if _, err := io.ReadFull(r, rep[:]); err != nil {
		t.Fatalf("no SOCKS reply: %v", err)
	}
	if rep[0] != 5 || rep[3] != 1 {
		t.Fatalf("bad reply %v", rep)
	}
	return rep[1], int(rep[8])<<8 | int(rep[9])
}

func socksConnect(t *testing.T, g *engine, host string, port int) (*net.TCPConn, *bufio.Reader, byte) {
	c, r := socksGreet(t, g.socks)
	rep, _ := socksRequest(t, c, r, 1, host, port)
	return c, r, rep
}

func echoCheck(t *testing.T, c net.Conn, r io.Reader, msg string) {
	t.Helper()
	io.WriteString(c, msg)
	b := make([]byte, len(msg))
	if _, err := io.ReadFull(r, b); err != nil || string(b) != msg {
		t.Fatalf("echo %q %v", b, err)
	}
}

func countEvents(g *engine, typ string) int {
	n := 0
	for _, l := range strings.Split(g.ev.all(), "\n") {
		var m map[string]any
		if json.Unmarshal([]byte(l), &m) == nil && m["type"] == typ {
			n++
		}
	}
	return n
}

// ---- CONNECT ---------------------------------------------------------------

func TestSocksConnectOK(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	for _, tc := range []struct{ host, authority string }{
		{"echo.test", "echo.test:443"},
		{"93.184.216.34", "93.184.216.34:443"},
		{"2001:db8::7", "[2001:db8::7]:443"},
	} {
		c, r, rep := socksConnect(t, g, tc.host, 443)
		if rep != 0 {
			t.Fatalf("%s: REP %d", tc.host, rep)
		}
		echoCheck(t, c, r, "hello socks")
		reqs := edge.requests()
		if last := reqs[len(reqs)-1]; last.method != "CONNECT" || last.authority != tc.authority || last.auth != "Bearer tok1" {
			t.Fatalf("edge saw %+v", last)
		}
	}
}

func TestSocksHalfClose(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	c, r, rep := socksConnect(t, g, "echo.test", 443)
	if rep != 0 {
		t.Fatal(rep)
	}
	io.WriteString(c, "bye")
	c.CloseWrite()
	if got := readAll(t, r, c); got != "bye" {
		t.Fatalf("got %q", got)
	}
}

func TestSocksConnectErrors(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)

	if _, _, rep := socksConnect(t, g, "refuse.test", 443); rep != 5 {
		t.Fatalf("502: REP %d, want 5", rep)
	}
	if _, _, rep := socksConnect(t, g, "broken.test", 443); rep != 4 {
		t.Fatalf("500: REP %d, want 4", rep)
	}
	if n := countEvents(g, "auth_failed"); n != 0 {
		t.Fatalf("auth_failed before any auth failure: %d", n)
	}
	c, r, rep := socksConnect(t, g, "authfail.test", 443)
	if rep != 4 {
		t.Fatalf("407: REP %d, want 4", rep)
	}
	g.ev.wait(t, "auth_failed", 0)
	// The socket is closed after the reply.
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if b, _ := io.ReadAll(r); len(b) != 0 {
		t.Fatalf("data after error reply: %q", b)
	}
	// Rate limit: one auth_failed per 5 s.
	socksConnect(t, g, "authfail.test", 443)
	socksConnect(t, g, "authfail.test", 443)
	time.Sleep(200 * time.Millisecond)
	if n := countEvents(g, "auth_failed"); n != 1 {
		t.Fatalf("auth_failed events: %d, want 1 (rate limited)", n)
	}
	// The connection survived all of it.
	if _, _, rep := socksConnect(t, g, "echo.test", 443); rep != 0 {
		t.Fatalf("REP %d", rep)
	}
	if edge.connCount() != 1 {
		t.Fatalf("connections: %d", edge.connCount())
	}
}

func TestSocksNoToken(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	g.f.token.Store(nil)
	if _, _, rep := socksConnect(t, g, "echo.test", 443); rep != 4 {
		t.Fatalf("REP %d", rep)
	}
}

func TestSocksBadRequests(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)

	// No acceptable auth method.
	c, _ := net.Dial("tcp", "127.0.0.1:"+strconv.Itoa(g.socks))
	defer c.Close()
	c.Write([]byte{5, 1, 2})
	b := make([]byte, 2)
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(c, b); err != nil || b[0] != 5 || b[1] != 0xff {
		t.Fatalf("%v %v", b, err)
	}
	// BIND is not supported: REP 7.
	c2, r2 := socksGreet(t, g.socks)
	if rep, _ := socksRequest(t, c2, r2, 2, "echo.test", 443); rep != 7 {
		t.Fatalf("BIND REP %d", rep)
	}
}

// ---- UDP -------------------------------------------------------------------

func socksUDPPacket(host string, port int, frag byte, payload string) []byte {
	p := append([]byte{0, 0, frag}, socksAddr(host, port)...)
	return append(p, payload...)
}

// associate opens a UDP association and returns the control connection and
// a UDP socket connected to the relay.
func associate(t *testing.T, g *engine) (*net.TCPConn, *net.UDPConn) {
	t.Helper()
	c, r := socksGreet(t, g.socks)
	rep, port := socksRequest(t, c, r, 3, "0.0.0.0", 0)
	if rep != 0 || port == 0 {
		t.Fatalf("associate: REP %d port %d", rep, port)
	}
	c.SetDeadline(time.Time{})
	u, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { u.Close() })
	return c, u
}

func readDatagram(t *testing.T, u *net.UDPConn) []byte {
	t.Helper()
	b := make([]byte, 70000)
	u.SetReadDeadline(time.Now().Add(10 * time.Second))
	n, err := u.Read(b)
	if err != nil {
		t.Fatalf("no datagram: %v", err)
	}
	return b[:n]
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if cond() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestSocksUDPAssociateEcho(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	ctl, u := associate(t, g)

	// IPv4 target, then a name, then IPv6: all go through CONNECT-UDP, the
	// edge echoes the capsules back.
	for _, tc := range []struct {
		host, path string
		port       int
	}{
		{"8.8.8.8", "/.well-known/masque/udp/8.8.8.8/443/", 443},
		{"quic.test", "/.well-known/masque/udp/quic.test/443/", 443},
		{"2001:db8::1", "/.well-known/masque/udp/2001%3Adb8%3A%3A1/3478/", 3478},
	} {
		pkt := socksUDPPacket(tc.host, tc.port, 0, "ping-"+tc.host)
		u.Write(pkt)
		if got := readDatagram(t, u); !bytes.Equal(got, pkt) {
			t.Fatalf("%s: reply %q, want %q", tc.host, got, pkt)
		}
		req := edge.requests()[len(edge.requests())-1]
		want := net.JoinHostPort(edgeName, strconv.Itoa(edge.port))
		if req.method != "CONNECT" || req.protocol != "connect-udp" || req.authority != want ||
			req.path != tc.path || req.capsule != "?1" || req.auth != "Bearer tok1" {
			t.Fatalf("edge saw %+v", req)
		}
	}
	if n := g.ss.udpFlows.Load(); n != 3 {
		t.Fatalf("flows: %d", n)
	}
	// More datagrams reuse the flow (no new request).
	before := len(edge.requests())
	pkt := socksUDPPacket("8.8.8.8", 443, 0, "again")
	for i := 0; i < 5; i++ {
		u.Write(pkt)
		if got := readDatagram(t, u); !bytes.Equal(got, pkt) {
			t.Fatalf("reply %q", got)
		}
	}
	if n := len(edge.requests()); n != before {
		t.Fatalf("%d new requests for an existing flow", n-before)
	}

	// Fragments and empty payloads are dropped; the next good datagram works.
	u.Write(socksUDPPacket("8.8.4.4", 443, 1, "frag"))
	u.Write(socksUDPPacket("8.8.4.4", 443, 0, ""))
	u.Write([]byte{0, 0, 0, 9, 1, 2, 3}) // unknown ATYP, short
	good := socksUDPPacket("8.8.4.4", 443, 0, "good")
	u.Write(good)
	if got := readDatagram(t, u); !bytes.Equal(got, good) {
		t.Fatalf("reply %q", got)
	}
	last := edge.requests()
	if n := len(last) - before; n != 1 {
		t.Fatalf("%d requests for the dropped packets and one good one, want 1", n)
	}

	// Closing the control connection ends the association and its flows.
	ctl.Close()
	waitFor(t, "flows to end", func() bool { return g.ss.udpFlows.Load() == 0 })
}

func TestUDPFlowCap(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	_, u := associate(t, g)
	for i := 0; i < maxUDPFlows+5; i++ {
		u.Write(socksUDPPacket("10.0.0."+strconv.Itoa(i+1), 443, 0, "x"))
	}
	waitFor(t, "flows", func() bool { return g.ss.udpFlows.Load() == maxUDPFlows })
	time.Sleep(300 * time.Millisecond)
	if n := g.ss.udpFlows.Load(); n != maxUDPFlows {
		t.Fatalf("flows %d, want cap %d", n, maxUDPFlows)
	}
}

func TestUDPIdleTimeout(t *testing.T) {
	old := udpIdleTimeout
	udpIdleTimeout = 400 * time.Millisecond
	defer func() { udpIdleTimeout = old }()
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	_, u := associate(t, g)
	pkt := socksUDPPacket("8.8.8.8", 443, 0, "idle")
	u.Write(pkt)
	readDatagram(t, u)
	if g.ss.udpFlows.Load() != 1 {
		t.Fatal("flow not open")
	}
	waitFor(t, "idle flow to close", func() bool { return g.ss.udpFlows.Load() == 0 })
	// A new datagram opens a new flow.
	u.Write(pkt)
	if got := readDatagram(t, u); !bytes.Equal(got, pkt) {
		t.Fatalf("reply %q", got)
	}
	if n := len(edge.requests()); n != 2 {
		t.Fatalf("edge requests %d, want 2", n)
	}
}

func TestUDPRejectionCache(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	_, u := associate(t, g)

	pkt := socksUDPPacket("refuse.test", 9999, 0, "nope")
	u.Write(pkt)
	waitFor(t, "refusal log", func() bool { return strings.Contains(g.ev.all(), "refused by Mozilla's server") })
	if !strings.Contains(g.ev.all(), "ignoring it for 5 minutes") {
		t.Fatalf("log: %s", g.ev.all())
	}
	waitFor(t, "flow to end", func() bool { return g.ss.udpFlows.Load() == 0 })
	n := len(edge.requests())
	// Retries, also from a new association, are not sent to the edge.
	_, u2 := associate(t, g)
	for i := 0; i < 5; i++ {
		u.Write(pkt)
		u2.Write(pkt)
	}
	time.Sleep(300 * time.Millisecond)
	if m := len(edge.requests()); m != n {
		t.Fatalf("edge saw %d more requests for a rejected target", m-n)
	}
	if c := strings.Count(g.ev.all(), "refused by Mozilla's server"); c != 1 {
		t.Fatalf("logged %d times, want once", c)
	}
	// Other targets still work.
	good := socksUDPPacket("8.8.8.8", 443, 0, "ok")
	u.Write(good)
	if got := readDatagram(t, u); !bytes.Equal(got, good) {
		t.Fatalf("reply %q", got)
	}
}

func TestRejectCacheUnit(t *testing.T) {
	now := time.Unix(1000, 0)
	c := newRejectCache()
	c.now = func() time.Time { return now }
	if c.isRejected("a:1") {
		t.Fatal("empty cache rejects")
	}
	c.reject("a:1", rejectLifetime(9999, ""))
	c.reject("b:443", rejectLifetime(443, "fastly;_error=destination_unavailable"))
	c.reject("c:443", rejectLifetime(443, "fastly;_error=destination_ip_prohibited"))
	now = now.Add(9 * time.Second)
	if !c.isRejected("a:1") || !c.isRejected("b:443") || !c.isRejected("c:443") {
		t.Fatal("entries expired early")
	}
	now = now.Add(2 * time.Second) // 11 s: the transient one is gone
	if c.isRejected("b:443") {
		t.Fatal("transient refusal still cached after 10 s")
	}
	if !c.isRejected("a:1") || !c.isRejected("c:443") {
		t.Fatal("5-minute entries expired early")
	}
	now = now.Add(5 * time.Minute)
	if c.isRejected("a:1") || c.isRejected("c:443") {
		t.Fatal("entries outlived 5 minutes")
	}
	c.maxEntries = 3
	for i := 0; i < 10; i++ {
		c.reject(strconv.Itoa(i), time.Duration(i+1)*time.Minute)
	}
	if len(c.until) != 3 || !c.isRejected("9") {
		t.Fatalf("cap not enforced: %d", len(c.until))
	}
}

func TestCapsuleEncoding(t *testing.T) {
	if got := encodeDatagramCapsule([]byte("abc")); !bytes.Equal(got, []byte{0, 4, 0, 'a', 'b', 'c'}) {
		t.Fatalf("% x", got)
	}
	long := bytes.Repeat([]byte{7}, 100) // length 101 needs a 2-byte varint
	got := encodeDatagramCapsule(long)
	if got[0] != 0 || got[1] != 0x40 || got[2] != 101 || got[3] != 0 || len(got) != 4+100 {
		t.Fatalf("% x", got[:6])
	}
	r := bufio.NewReader(bytes.NewReader(got[1:3]))
	if v, err := readVarint(r); err != nil || v != 101 {
		t.Fatalf("varint %d %v", v, err)
	}
}

// ---- DNS over DoH ----------------------------------------------------------

func newCert(t *testing.T, name string) (tls.Certificate, *x509.Certificate) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: name}, DNSNames: []string{name},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true, IsCA: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := x509.ParseCertificate(der)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, c
}

// dnsQuery builds a standard A query for name.
func dnsQuery(id uint16, name string) []byte {
	q := binary.BigEndian.AppendUint16(nil, id)
	q = append(q, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0)
	for _, l := range strings.Split(name, ".") {
		q = append(append(q, byte(len(l))), l...)
	}
	return append(q, 0, 0, 1, 0, 1)
}

// fakeDoH serves RFC 8484 POST: answers every A query with 1.2.3.4 (TTL 60).
type fakeDoH struct {
	addr string
	hits atomic.Int64
	bad  atomic.Int64
}

func newFakeDoH(t *testing.T, cert tls.Certificate) *fakeDoH {
	t.Helper()
	d := &fakeDoH{}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}})
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q, _ := io.ReadAll(r.Body)
		if r.Method != "POST" || r.URL.Path != "/dns-query" || r.Header.Get("Content-Type") != "application/dns-message" ||
			r.Header.Get("Accept") != "application/dns-message" || len(q) < 12 {
			d.bad.Add(1)
			w.WriteHeader(400)
			return
		}
		d.hits.Add(1)
		end, _ := dnsQuestionEnd(q)
		a := append([]byte(nil), q[:end]...)
		a[2], a[3] = 0x81, 0x80
		a[6], a[7] = 0, 1
		a = append(a, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 2, 3, 4)
		w.Header().Set("Content-Type", "application/dns-message")
		w.Write(a)
	})}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	d.addr = ln.Addr().String()
	return d
}

func TestSocksDNSOverDoH(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	cert, xc := newCert(t, "doh.test")
	doh := newFakeDoH(t, cert)
	edge.setBackend("doh.test:443", doh.addr)
	pool := x509.NewCertPool()
	pool.AddCert(xc)
	g.ss.doh = newDoHClient(g.f, g.up.ev, "doh.test", pool)

	_, u := associate(t, g)
	query := dnsQuery(0xbeef, "Example.com")
	pkt := socksUDPPacket("1.1.1.1", 53, 0, string(query))
	u.Write(pkt)
	got := readDatagram(t, u)
	hl := len(pkt) - len(query)
	if !bytes.Equal(got[:hl], pkt[:hl]) {
		t.Fatalf("reply header % x", got[:hl])
	}
	ans := got[hl:]
	if len(ans) < len(query)+16 || ans[0] != 0xbe || ans[1] != 0xef || ans[2]&0x80 == 0 ||
		!bytes.Equal(ans[len(ans)-4:], []byte{1, 2, 3, 4}) {
		t.Fatalf("answer % x", ans)
	}
	// The DoH connection went through the tunnel as CONNECT doh.test:443.
	req := edge.requests()[0]
	if req.method != "CONNECT" || req.authority != "doh.test:443" || req.auth != "Bearer tok1" {
		t.Fatalf("edge saw %+v", req)
	}
	if doh.bad.Load() != 0 {
		t.Fatal("DoH server got a malformed request")
	}

	// Same question (any case, new ID): served from the cache, ID follows the query.
	u.Write(socksUDPPacket("8.8.8.8", 53, 0, string(dnsQuery(0x1234, "example.COM"))))
	got2 := readDatagram(t, u)
	if a := got2[hl:]; a[0] != 0x12 || a[1] != 0x34 || !bytes.Equal(a[len(a)-4:], []byte{1, 2, 3, 4}) {
		t.Fatalf("cached answer % x", a)
	}
	if doh.hits.Load() != 1 {
		t.Fatalf("DoH hits %d, want 1 (cache)", doh.hits.Load())
	}
	// A different name is a new lookup on the same tunnelled connection.
	u.Write(socksUDPPacket("1.1.1.1", 53, 0, string(dnsQuery(7, "other.example"))))
	readDatagram(t, u)
	if doh.hits.Load() != 2 {
		t.Fatalf("DoH hits %d, want 2", doh.hits.Load())
	}
	if n := len(edge.requests()); n != 1 {
		t.Fatalf("%d tunnel streams for DNS, want 1 reused connection", n)
	}
	if g.st.up.Load() == 0 || g.st.down.Load() == 0 {
		t.Fatal("DNS not counted in stats")
	}
}

func TestSocksDNSFailureIsServfail(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	g.ss.doh = newDoHClient(g.f, g.up.ev, "refuse.test", nil) // the edge refuses it
	_, u := associate(t, g)
	query := dnsQuery(0x4242, "example.com")
	u.Write(socksUDPPacket("1.1.1.1", 53, 0, string(query)))
	got := readDatagram(t, u)
	ans := got[10:] // the IPv4 header is 10 bytes
	if ans[0] != 0x42 || ans[1] != 0x42 || ans[3]&0x0f != 2 {
		t.Fatalf("not a SERVFAIL for the query: % x", ans)
	}
}

func TestDNSHelpers(t *testing.T) {
	if _, err := newDoHClientTestResolve(); err == nil {
		t.Fatal("malformed query accepted")
	}
	if s := servfail(dnsQuery(1, "a.b")); s[3]&0x0f != 2 || s[2]&0x80 == 0 {
		t.Fatalf("servfail % x", s)
	}
}

func newDoHClientTestResolve() ([]byte, error) {
	d := &dohClient{cache: map[string]dnsEntry{}}
	return d.resolve([]byte{1, 2, 3})
}

// ---- stats -----------------------------------------------------------------

func TestStatsEvent(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	c, r, rep := socksConnect(t, g, "echo.test", 443)
	if rep != 0 {
		t.Fatal(rep)
	}
	payload := strings.Repeat("x", 10000)
	echoCheck(t, c, r, payload)

	deadline := time.Now().Add(10 * time.Second)
	idx := 0
	var m map[string]any
	for {
		m, idx = g.ev.wait(t, "stats", idx)
		if m["up"].(float64) >= 10000 && m["down"].(float64) >= 10000 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("stats never reached 10000: %v", m)
		}
	}
	if m["up"].(float64) != 10000 || m["down"].(float64) != 10000 {
		t.Fatalf("stats %v, want exactly 10000 each", m)
	}
	// Unchanged numbers are not repeated.
	n := countEvents(g, "stats")
	time.Sleep(450 * time.Millisecond)
	if countEvents(g, "stats") != n {
		t.Fatal("stats repeated while nothing changed")
	}
}

// ---- throughput ------------------------------------------------------------

// TestSocksThroughput pushes data both ways through SOCKS CONNECT and the
// in-process test edge (which echoes it with 32 KiB reads; the edge, TLS and
// the Go HTTP/2 server are part of what is measured, so this is a lower bound
// for the bridge itself).
func TestSocksThroughput(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	c, r, rep := socksConnect(t, g, "echo.test", 443)
	if rep != 0 {
		t.Fatal(rep)
	}
	c.SetDeadline(time.Time{})
	const total = 256 << 20
	start := time.Now()
	go func() {
		chunk := make([]byte, 128<<10)
		for sent := 0; sent < total; sent += len(chunk) {
			if _, err := c.Write(chunk); err != nil {
				return
			}
		}
		c.CloseWrite()
	}()
	n, err := io.Copy(io.Discard, r)
	el := time.Since(start)
	if err != nil || n != total {
		t.Fatalf("echoed %d of %d: %v", n, total, err)
	}
	mbs := float64(total) / (1 << 20) / el.Seconds()
	t.Logf("SOCKS CONNECT through the test edge: %.0f MiB each way in %.2fs = %.0f MB/s up and %.0f MB/s down (simultaneous)", float64(total)/(1<<20), el.Seconds(), mbs, mbs)
	if mbs < 20 {
		t.Fatalf("bridge too slow: %.1f MB/s", mbs)
	}
	if g.st.up.Load() != total || g.st.down.Load() != total {
		t.Fatalf("stats up %d down %d, want %d", g.st.up.Load(), g.st.down.Load(), total)
	}
}

// ---- the real process ------------------------------------------------------

func TestEngineProcessSocks(t *testing.T) {
	edge := newTestEdge(t)
	cmd := exec.Command(os.Args[0], "--server", net.JoinHostPort(edgeName, strconv.Itoa(edge.port)),
		"--ip", "127.0.0.1", "--test-root", edge.certFile, "--socks")
	cmd.Env = append(os.Environ(), "FOXY_CORE_MAIN=1")
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill() })
	out := bufio.NewReader(stdout)
	next := func() map[string]any {
		line, err := out.ReadString('\n')
		if err != nil {
			t.Fatalf("stdout: %v", err)
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("not JSON: %q", line)
		}
		return m
	}
	l := next()
	if l["type"] != "listening" || l["socks_port"] == nil || l["socks_port"].(float64) == 0 {
		t.Fatalf("listening: %v", l)
	}
	sp := int(l["socks_port"].(float64))
	if sp == int(l["port"].(float64)) {
		t.Fatal("socks and flow ports are the same")
	}
	io.WriteString(stdin, `{"token":"tok-p"}`+"\n")
	if c := next(); c["type"] != "connected" {
		t.Fatalf("connected: %v", c)
	}
	c, r := socksGreet(t, sp)
	if rep, _ := socksRequest(t, c, r, 1, "echo.test", 443); rep != 0 {
		t.Fatalf("REP %d", rep)
	}
	echoCheck(t, c, r, "via process")
	// stats arrive on stdout (once per second).
	for i := 0; ; i++ {
		m := next()
		if m["type"] == "stats" {
			if m["up"].(float64) != 11 || m["down"].(float64) != 11 {
				t.Fatalf("stats %v", m)
			}
			break
		}
		if i > 10 {
			t.Fatal("no stats event")
		}
	}
	if got := edge.requests()[0].auth; got != "Bearer tok-p" {
		t.Fatalf("token %q", got)
	}
	stdin.Close()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("engine did not exit on stdin EOF")
	}
}

func TestSocksPortFlagFixed(t *testing.T) {
	// --socks-port pins the port (the app passes the previous one on restart).
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	edge := newTestEdge(t)
	cmd := exec.Command(os.Args[0], "--server", net.JoinHostPort(edgeName, strconv.Itoa(edge.port)),
		"--ip", "127.0.0.1", "--test-root", edge.certFile, "--socks", "--socks-port", strconv.Itoa(port))
	cmd.Env = append(os.Environ(), "FOXY_CORE_MAIN=1")
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { stdin.Close(); cmd.Process.Kill() })
	line, _ := bufio.NewReader(stdout).ReadString('\n')
	var m map[string]any
	if json.Unmarshal([]byte(line), &m) != nil || int(m["socks_port"].(float64)) != port {
		t.Fatalf("listening %q, want socks_port %d", line, port)
	}
}
