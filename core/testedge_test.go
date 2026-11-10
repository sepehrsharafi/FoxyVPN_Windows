package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/net/http2"
)

// TestMain does two tricks:
//   - FOXY_CORE_MAIN=1: run the real main() (the process tests start us as
//     the engine: the test binary is the engine binary).
//   - x/net's HTTP/2 server only advertises SETTINGS_ENABLE_CONNECT_PROTOCOL
//     when GODEBUG has http2xconnect=1 at program start, so the test run
//     re-executes itself once with it.
func TestMain(m *testing.M) {
	if os.Getenv("FOXY_CORE_MAIN") == "1" {
		main()
		os.Exit(0)
	}
	if !strings.Contains(os.Getenv("GODEBUG"), "http2xconnect=1") {
		cmd := exec.Command(os.Args[0], os.Args[1:]...)
		cmd.Env = append(os.Environ(), "GODEBUG=http2xconnect=1")
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				os.Exit(ee.ExitCode())
			}
			panic(err)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// seenReq is what the test edge saw of one request.
type seenReq struct {
	method, authority, path, protocol, capsule, auth string
}

// testEdge is an in-process HTTP/2 TLS server that acts like the VPN edge:
// CONNECT is accepted and echoed, chosen targets are refused.
type testEdge struct {
	ln       net.Listener
	port     int
	certFile string // PEM of the test root (the self-signed cert)

	mu       sync.Mutex
	conns    []net.Conn
	seen     []seenReq
	total    int               // connections accepted
	backends map[string]string // CONNECT authority -> TCP address to relay to
}

const edgeName = "edge.test"

func newTestEdge(t *testing.T) *testEdge {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: edgeName},
		DNSNames:              []string{edgeName},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	extraRoots = []*x509.Certificate{cert}
	rootsPool = nil
	rootsOnce = sync.Once{}

	dir := t.TempDir()
	e := &testEdge{certFile: dir + "/root.pem"}
	os.WriteFile(e.certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600)

	ln, err := tls.Listen("tcp4", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		NextProtos:   []string{"h2"},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.ln, e.port = ln, ln.Addr().(*net.TCPAddr).Port
	t.Cleanup(func() { ln.Close(); e.killConns() })

	h2s := &http2.Server{MaxConcurrentStreams: 100}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			e.mu.Lock()
			e.conns = append(e.conns, c)
			e.total++
			e.mu.Unlock()
			go func() {
				// ServeConn checks the TLS version: finish the handshake first.
				if tc, ok := c.(*tls.Conn); ok && tc.Handshake() != nil {
					return
				}
				h2s.ServeConn(c, &http2.ServeConnOpts{Handler: http.HandlerFunc(e.handle)})
			}()
		}
	}()
	return e
}

func (e *testEdge) handle(w http.ResponseWriter, r *http.Request) {
	s := seenReq{
		method:    r.Method,
		authority: r.Host,
		path:      r.URL.EscapedPath(),
		protocol:  r.Header.Get(":protocol"),
		capsule:   r.Header.Get("Capsule-Protocol"),
		auth:      r.Header.Get("Proxy-Authorization"),
	}
	e.mu.Lock()
	e.seen = append(e.seen, s)
	e.mu.Unlock()

	switch {
	case strings.HasPrefix(r.Host, "refuse.test"), r.Header.Get(":protocol") != "" && strings.Contains(r.URL.Path, "/refuse.test/"):
		w.Header().Set("Proxy-Status", "fastly; error=destination_unavailable")
		w.WriteHeader(502)
		return
	case strings.HasPrefix(r.Host, "authfail.test"):
		w.Header().Set("X-Fastly-Proxy-Auth-Failed", "1")
		w.WriteHeader(400)
		return
	case strings.HasPrefix(r.Host, "broken.test"):
		w.WriteHeader(500)
		return
	case strings.HasPrefix(r.Host, "hang.test"):
		<-r.Context().Done()
		return
	}
	e.mu.Lock()
	backend := e.backends[r.Host]
	e.mu.Unlock()
	if backend != "" {
		e.relay(w, r, backend)
		return
	}
	w.WriteHeader(200)
	fl := w.(http.Flusher)
	fl.Flush()
	buf := make([]byte, 32<<10)
	for {
		n, err := r.Body.Read(buf)
		if n > 0 {
			w.Write(buf[:n])
			fl.Flush()
		}
		if err != nil {
			return // request body ended: end the response too
		}
	}
}

func (e *testEdge) requests() []seenReq {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]seenReq(nil), e.seen...)
}

func (e *testEdge) connCount() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.total
}

// goaway sends a graceful GOAWAY (NO_ERROR, all streams processed) on every
// connection, like the edge rotating a connection. Safe because the server
// writes nothing on an idle connection at that moment.
func (e *testEdge) goaway(debug string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, c := range e.conns {
		f := make([]byte, 9+8+len(debug))
		n := 8 + len(debug)
		f[0], f[1], f[2], f[3] = byte(n>>16), byte(n>>8), byte(n), 7
		binary.BigEndian.PutUint32(f[9:], 0x7fffffff)
		copy(f[17:], debug)
		c.Write(f)
	}
}

func (e *testEdge) killConns() {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, c := range e.conns {
		c.Close()
	}
	e.conns = nil
}

// lineSink collects the engine's JSON event lines.
type lineSink struct {
	mu    sync.Mutex
	lines []string
	ch    chan struct{}
}

func newLineSink() *lineSink { return &lineSink{ch: make(chan struct{}, 100)} }

func (l *lineSink) Write(p []byte) (int, error) {
	l.mu.Lock()
	for _, ln := range strings.Split(strings.TrimRight(string(p), "\n"), "\n") {
		l.lines = append(l.lines, ln)
	}
	l.mu.Unlock()
	select {
	case l.ch <- struct{}{}:
	default:
	}
	return len(p), nil
}

// wait returns the first event of the given type at or after index from.
func (l *lineSink) wait(t *testing.T, typ string, from int) (map[string]any, int) {
	t.Helper()
	deadline := time.After(10 * time.Second)
	for {
		l.mu.Lock()
		for i := from; i < len(l.lines); i++ {
			var m map[string]any
			if json.Unmarshal([]byte(l.lines[i]), &m) == nil && m["type"] == typ {
				l.mu.Unlock()
				return m, i + 1
			}
		}
		l.mu.Unlock()
		select {
		case <-l.ch:
		case <-time.After(50 * time.Millisecond):
		case <-deadline:
			t.Fatalf("no %q event; got %v", typ, l.lines)
		}
	}
}

func (l *lineSink) all() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return strings.Join(l.lines, "\n")
}

// engine is the in-process engine: the same pieces main() wires up.
type engine struct {
	t      *testing.T
	f      *flows
	ss     *socksServer
	st     *stats
	socks  int
	up     *upstream
	ev     *lineSink
	port   int
	secret string
}

func startEngine(t *testing.T, e *testEdge) *engine {
	t.Helper()
	sink := newLineSink()
	up := newUpstream(edgeName, e.port, "127.0.0.1", 0, newEvents(sink))
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &flows{up: up, secret: "s3cret", serverAuthority: net.JoinHostPort(edgeName, strconv.Itoa(e.port))}
	f.setToken("tok1")
	go f.serve(ln)
	st := &stats{}
	ss := newSocksServer(f, up.ev, st)
	sln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go ss.serve(sln)
	go st.run(up.ev, 100*time.Millisecond)
	up.start()
	t.Cleanup(func() { ln.Close(); sln.Close(); up.close() })
	return &engine{t: t, f: f, up: up, ev: sink, ss: ss, st: st, socks: sln.Addr().(*net.TCPAddr).Port, port: ln.Addr().(*net.TCPAddr).Port, secret: "s3cret"}
}

// flow opens a loopback flow and returns the connection and the reply line.
func (g *engine) flow(kind, host, port string) (*net.TCPConn, *bufio.Reader, string) {
	g.t.Helper()
	c, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(g.port)))
	if err != nil {
		g.t.Fatal(err)
	}
	g.t.Cleanup(func() { c.Close() })
	io.WriteString(c, g.secret+" "+kind+" "+host+" "+port+"\n")
	r := bufio.NewReader(c)
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	line, err := r.ReadString('\n')
	if err != nil {
		g.t.Fatalf("no reply line: %v", err)
	}
	return c.(*net.TCPConn), r, strings.TrimRight(line, "\n")
}

func (e *testEdge) setBackend(authority, addr string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.backends == nil {
		e.backends = map[string]string{}
	}
	e.backends[authority] = addr
}

// relay connects the CONNECT stream to a real TCP server.
func (e *testEdge) relay(w http.ResponseWriter, r *http.Request, addr string) {
	bc, err := net.Dial("tcp", addr)
	if err != nil {
		w.WriteHeader(502)
		return
	}
	defer bc.Close()
	w.WriteHeader(200)
	fl := w.(http.Flusher)
	fl.Flush()
	go func() {
		io.Copy(bc, r.Body)
		bc.(*net.TCPConn).CloseWrite()
	}()
	buf := make([]byte, 32<<10)
	for {
		n, err := bc.Read(buf)
		if n > 0 {
			w.Write(buf[:n])
			fl.Flush()
		}
		if err != nil {
			return
		}
	}
}
