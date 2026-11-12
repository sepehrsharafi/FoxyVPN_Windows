package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"
)

func readAll(t *testing.T, r io.Reader, c *net.TCPConn) string {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	b, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read: %v (got %q)", err, b)
	}
	return string(b)
}

func TestTCPEchoAndHalfClose(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	m, _ := g.ev.wait(t, "connected", 0)
	if m["tls"] != "tls1.3 h2 firefox" {
		t.Fatalf("tls = %v", m["tls"])
	}

	c, r, reply := g.flow("TCP", "echo.test", "443")
	if reply != "OK" {
		t.Fatalf("reply %q", reply)
	}
	io.WriteString(c, "hello")
	buf := make([]byte, 5)
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	if _, err := io.ReadFull(r, buf); err != nil || string(buf) != "hello" {
		t.Fatalf("echo %q %v", buf, err)
	}
	// Half-close: client EOF must end the request body; the echo of what is
	// still in flight arrives, then the response ends and we see EOF.
	io.WriteString(c, " world")
	c.CloseWrite()
	if got := readAll(t, r, c); got != " world" {
		t.Fatalf("after half-close got %q", got)
	}

	req := edge.requests()[0]
	if req.method != "CONNECT" || req.authority != "echo.test:443" || req.auth != "Bearer tok1" || req.protocol != "" {
		t.Fatalf("edge saw %+v", req)
	}
}

func TestIPv6Authority(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	_, _, reply := g.flow("TCP", "2001:db8::1", "8443")
	if reply != "OK" {
		t.Fatal(reply)
	}
	if a := edge.requests()[0].authority; a != "[2001:db8::1]:8443" {
		t.Fatalf("authority %q", a)
	}
}

func TestLargeTransferBothWays(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	c, r, reply := g.flow("TCP", "echo.test", "443")
	if reply != "OK" {
		t.Fatal(reply)
	}
	const n = 8 << 20
	go func() {
		chunk := make([]byte, 64<<10)
		for i := range chunk {
			chunk[i] = byte(i)
		}
		for sent := 0; sent < n; sent += len(chunk) {
			c.Write(chunk)
		}
		c.CloseWrite()
	}()
	c.SetReadDeadline(time.Now().Add(30 * time.Second))
	got, err := io.Copy(io.Discard, r)
	if err != nil || got != n {
		t.Fatalf("echoed %d of %d: %v", got, n, err)
	}
}

func TestErr502(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	_, _, reply := g.flow("TCP", "refuse.test", "443")
	if reply != "ERR 502 fastly;_error=destination_unavailable Bad Gateway" {
		t.Fatalf("reply %q", reply)
	}
	// The connection must survive a refused flow.
	if _, _, ok := g.flow("TCP", "echo.test", "443"); ok != "OK" {
		t.Fatalf("next flow: %q", ok)
	}
	if edge.connCount() != 1 {
		t.Fatalf("connections: %d", edge.connCount())
	}
}

func TestErr407WhenAuthHeader(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	_, _, reply := g.flow("TCP", "authfail.test", "443")
	if !strings.HasPrefix(reply, "ERR 407 - ") {
		t.Fatalf("reply %q", reply)
	}
}

func TestTokenUpdateAffectsNewStreams(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	c1, r1, _ := g.flow("TCP", "echo.test", "443")
	g.f.setToken("tok2")
	_, _, reply := g.flow("TCP", "echo.test", "444")
	if reply != "OK" {
		t.Fatal(reply)
	}
	seen := edge.requests()
	if seen[0].auth != "Bearer tok1" || seen[1].auth != "Bearer tok2" {
		t.Fatalf("tokens: %+v", seen)
	}
	// The old stream still works.
	io.WriteString(c1, "x")
	b := make([]byte, 1)
	c1.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(r1, b); err != nil {
		t.Fatal(err)
	}
}

func TestUDPExtendedConnect(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	for _, tc := range []struct{ host, path string }{
		{"1.1.1.1", "/.well-known/masque/udp/1.1.1.1/53/"},
		{"2001:db8::1", "/.well-known/masque/udp/2001%3Adb8%3A%3A1/53/"},
		{"a b.example", ""}, // fields split: bad request, see below
	} {
		if tc.path == "" {
			continue
		}
		c, r, reply := g.flow("UDP", tc.host, "53")
		if reply != "OK" {
			t.Fatalf("%s: %q", tc.host, reply)
		}
		io.WriteString(c, "capsule")
		b := make([]byte, 7)
		c.SetReadDeadline(time.Now().Add(5 * time.Second))
		if _, err := io.ReadFull(r, b); err != nil || string(b) != "capsule" {
			t.Fatalf("echo %q %v", b, err)
		}
		req := edge.requests()[len(edge.requests())-1]
		want := net.JoinHostPort(edgeName, strconv.Itoa(edge.port))
		if req.method != "CONNECT" || req.protocol != "connect-udp" || req.authority != want ||
			req.path != tc.path || req.capsule != "?1" || req.auth != "Bearer tok1" {
			t.Fatalf("edge saw %+v (want path %s authority %s)", req, tc.path, want)
		}
	}
}

func TestPercentEncodedName(t *testing.T) {
	if got := connectUDPPath("exa mple.com", 443); got != "/.well-known/masque/udp/exa%20mple.com/443/" {
		t.Fatal(got)
	}
	if got := connectUDPPath("::1", 53); got != "/.well-known/masque/udp/%3A%3A1/53/" {
		t.Fatal(got)
	}
}

func TestWrongSecretAndBadRequest(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)

	c, _ := net.Dial("tcp", "127.0.0.1:"+strconv.Itoa(g.port))
	io.WriteString(c, "wrong TCP echo.test 443\n")
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if b, _ := io.ReadAll(c); len(b) != 0 {
		t.Fatalf("wrong secret got reply %q", b)
	}
	if _, _, reply := g.flow("TCP", "echo.test", "99999"); reply != "ERR 0 - bad request" {
		t.Fatalf("%q", reply)
	}
	if n := len(edge.requests()); n != 0 {
		t.Fatalf("edge saw %d requests", n)
	}
}

func TestReplyTimeout(t *testing.T) {
	old := replyTimeout
	replyTimeout = 400 * time.Millisecond
	defer func() { replyTimeout = old }()
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	if _, _, reply := g.flow("TCP", "hang.test", "443"); reply != "ERR 0 - timeout" {
		t.Fatalf("%q", reply)
	}
}

func TestNoTokenIsErr(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	g.f.token.Store(nil)
	if _, _, reply := g.flow("TCP", "echo.test", "443"); reply != "ERR 0 - no token" {
		t.Fatalf("%q", reply)
	}
}

func TestGoawayRotation(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	g.ev.wait(t, "connected", 0)

	c1, r1, reply := g.flow("TCP", "echo.test", "443")
	if reply != "OK" {
		t.Fatal(reply)
	}
	edge.goaway("rotate")

	// A new flow after the GOAWAY lands on a second connection.
	c2, r2, reply := g.flow("TCP", "echo.test", "443")
	if reply != "OK" {
		t.Fatalf("flow after GOAWAY: %q", reply)
	}
	if edge.connCount() != 2 {
		t.Fatalf("connections after GOAWAY: %d", edge.connCount())
	}
	// The old stream keeps working on the draining connection.
	for _, p := range []struct {
		c *net.TCPConn
		r *bufio.Reader
	}{{c1, r1}, {c2, r2}} {
		io.WriteString(p.c, "ping")
		b := make([]byte, 4)
		p.c.SetReadDeadline(time.Now().Add(5 * time.Second))
		if _, err := io.ReadFull(p.r, b); err != nil || string(b) != "ping" {
			t.Fatalf("echo %q %v", b, err)
		}
	}
	// Once the old stream ends, the drained connection is closed by us.
	c1.CloseWrite()
	readAll(t, r1, c1)
	deadline := time.Now().Add(5 * time.Second)
	for {
		g.up.mu.Lock()
		n := len(g.up.conns)
		g.up.mu.Unlock()
		if n == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("drained connection not closed; %d conns", n)
		}
		time.Sleep(50 * time.Millisecond)
	}
	for i := 0; !strings.Contains(g.ev.all(), "GOAWAY code=0"); i++ {
		if i > 100 {
			t.Fatalf("GOAWAY not logged:\n%s", g.ev.all())
		}
		time.Sleep(50 * time.Millisecond)
	}
	if strings.Contains(g.ev.all(), `"lost"`) {
		t.Fatalf("graceful rotation reported as lost:\n%s", g.ev.all())
	}
}

func TestLostAndReconnected(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	_, i := g.ev.wait(t, "connected", 0)

	c, r, _ := g.flow("TCP", "echo.test", "443")
	edge.killConns()
	m, i := g.ev.wait(t, "lost", i)
	if m["reason"] == "" {
		t.Fatal("empty lost reason")
	}
	g.ev.wait(t, "reconnected", i)
	// The flow on the dead connection ended; a new one works.
	readAll(t, r, c)
	if _, _, reply := g.flow("TCP", "echo.test", "443"); reply != "OK" {
		t.Fatalf("flow after reconnect: %q", reply)
	}
}

// TestEngineProcess runs the real main() as a child process (this test
// binary with FOXY_CORE_MAIN=1): token line, events, a flow, token update,
// and exit on stdin EOF.
func TestEngineProcess(t *testing.T) {
	edge := newTestEdge(t)
	cmd := exec.Command(os.Args[0], "--server", net.JoinHostPort(edgeName, strconv.Itoa(edge.port)),
		"--ip", "127.0.0.1", "--test-root", edge.certFile)
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
	if l["type"] != "listening" {
		t.Fatalf("first line %v", l)
	}
	port, secret := int(l["port"].(float64)), l["secret"].(string)
	if len(secret) != 32 {
		t.Fatalf("secret %q", secret)
	}
	// Nothing connects before the token.
	time.Sleep(300 * time.Millisecond)
	if edge.connCount() != 0 {
		t.Fatal("connected before the token")
	}
	io.WriteString(stdin, `{"token":"secret-token-1"}`+"\n")
	if c := next(); c["type"] != "connected" || c["tls"] != "tls1.3 h2 firefox" {
		t.Fatalf("connected: %v", c)
	}

	flow := func() string {
		c, err := net.Dial("tcp", "127.0.0.1:"+strconv.Itoa(port))
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		io.WriteString(c, secret+" TCP echo.test 443\n")
		c.SetReadDeadline(time.Now().Add(10 * time.Second))
		r := bufio.NewReader(c)
		line, _ := r.ReadString('\n')
		return strings.TrimSpace(line)
	}
	if got := flow(); got != "OK" {
		t.Fatalf("flow: %q", got)
	}
	io.WriteString(stdin, `{"token":"secret-token-2"}`+"\n")
	time.Sleep(200 * time.Millisecond)
	if got := flow(); got != "OK" {
		t.Fatalf("flow: %q", got)
	}
	seen := edge.requests()
	if seen[0].auth != "Bearer secret-token-1" || seen[1].auth != "Bearer secret-token-2" {
		t.Fatalf("tokens %+v", seen)
	}

	stdin.Close() // the app quit: the engine must exit at once
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("exit: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("engine did not exit on stdin EOF")
	}
}

func TestUsageError(t *testing.T) {
	cmd := exec.Command(os.Args[0], "--server", "nope")
	cmd.Env = append(os.Environ(), "FOXY_CORE_MAIN=1")
	if err := cmd.Run(); err == nil {
		t.Fatal("expected exit status 2")
	}
}

// With want=3 the pool fills to three connections, spreads flows over them,
// and losing one is not "lost": the others carry on and it is replaced.
func TestPoolSpreadsAndSurvivesOneLoss(t *testing.T) {
	edge := newTestEdge(t)
	g := startEngine(t, edge)
	g.up.mu.Lock()
	g.up.want = 3
	g.up.mu.Unlock()
	g.ev.wait(t, "connected", 0)

	waitFor := func(what string, ok func() bool) {
		t.Helper()
		for deadline := time.Now().Add(5 * time.Second); !ok(); time.Sleep(20 * time.Millisecond) {
			if time.Now().After(deadline) {
				t.Fatalf("timed out waiting for %s", what)
			}
		}
	}
	open := func() int {
		g.up.mu.Lock()
		defer g.up.mu.Unlock()
		return g.up.openLocked()
	}
	// The first flow tops the pool up; it fills one dial at a time.
	if _, _, reply := g.flow("TCP", "echo.test", "443"); reply != "OK" {
		t.Fatal(reply)
	}
	waitFor("3 connections", func() bool { return open() == 3 })

	for k := 0; k < 5; k++ {
		if _, _, reply := g.flow("TCP", "echo.test", "443"); reply != "OK" {
			t.Fatal(reply)
		}
	}
	waitFor("2 streams on each connection", func() bool {
		g.up.mu.Lock()
		defer g.up.mu.Unlock()
		for _, c := range g.up.conns {
			if c.cc.State().StreamsActive != 2 {
				return false
			}
		}
		return len(g.up.conns) == 3
	})

	edge.killOne()
	waitFor("replacement connection", func() bool { return edge.connCount() == 4 && open() == 3 })
	if _, _, reply := g.flow("TCP", "echo.test", "443"); reply != "OK" {
		t.Fatalf("flow after losing one connection: %q", reply)
	}
	if strings.Contains(g.ev.all(), `"lost"`) {
		t.Fatalf("one dropped connection out of three reported as lost:\n%s", g.ev.all())
	}
}
