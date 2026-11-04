package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type tc struct {
	conn net.Conn
	r    *bufio.Reader
}

func (c *tc) send(t *testing.T, s string) map[string]any {
	t.Helper()
	if _, err := c.conn.Write([]byte(s + "\n")); err != nil {
		t.Fatal(err)
	}
	return c.read(t)
}

func (c *tc) read(t *testing.T) map[string]any {
	t.Helper()
	_ = c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := c.r.ReadBytes('\n')
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(line, &m); err != nil {
		t.Fatalf("bad json %q", line)
	}
	return m
}

func startTestServer(t *testing.T, exe string, f *fakePlatform) (*Server, func() *tc) {
	dir, err := os.MkdirTemp("", "fxs")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	paths := Paths{Dir: dir, State: filepath.Join(dir, "state.json"), Config: filepath.Join(dir, "helper.json"),
		Tun2socks: "/x/tun2socks", Socket: filepath.Join(dir, "s.sock")}
	if err := writeConfig(paths, "/Applications/FoxyVPN.app"); err != nil {
		t.Fatal(err)
	}
	l, err := net.Listen("unix", paths.Socket)
	if err != nil {
		t.Skipf("unix sockets unavailable: %v", err)
	}
	t.Cleanup(func() { _ = l.Close() })
	mgr := newManager(paths, f.platform(), nil)
	srv := newServer(paths, mgr, nil, func(net.Conn) (string, error) { return exe, nil })
	go srv.Serve(l)
	return srv, func() *tc {
		c, err := net.Dial("unix", paths.Socket)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = c.Close() })
		return &tc{conn: c, r: bufio.NewReader(c)}
	}
}

func TestServerRejectsStrangers(t *testing.T) {
	_, dial := startTestServer(t, "/usr/bin/curl", newFake())
	c := dial()
	h := c.send(t, `{"id":1,"cmd":"hello"}`)
	if h["ok"] != true || h["version"] != HelperVersion || h["appPath"] != "/Applications/FoxyVPN.app" {
		t.Errorf("hello: %v", h)
	}
	for _, cmd := range []string{`{"id":2,"cmd":"start","socksPort":5000}`, `{"id":3,"cmd":"stop"}`, `{"id":4,"cmd":"cleanup"}`} {
		c := dial() // a stranger is disconnected after its first answer
		r := c.send(t, cmd)
		if r["ok"] != false || r["error"] != "Not allowed." {
			t.Errorf("%s -> %v", cmd, r)
		}
	}
}

func TestServerProtocol(t *testing.T) {
	f := newFake()
	_, dial := startTestServer(t, "/Applications/FoxyVPN.app/Contents/MacOS/FoxyVPN", f)
	c := dial()
	if r := c.send(t, `{"id":1,"cmd":"start","socksPort":80}`); r["ok"] != false || r["id"] != float64(1) {
		t.Errorf("bad port: %v", r)
	}
	if r := c.send(t, `{"id":2,"cmd":"start","socksPort":5000,"bypass":["127.0.0.1"]}`); r["ok"] != false {
		t.Errorf("bad bypass: %v", r)
	}
	if r := c.send(t, `not json`); r["ok"] != false || r["error"] != "Malformed request." {
		t.Errorf("malformed: %v", r)
	}
	if r := c.send(t, `{"id":5,"cmd":"bogus"}`); r["ok"] != false || r["id"] != float64(5) {
		t.Errorf("unknown: %v", r)
	}
	r := c.send(t, `{"id":3,"cmd":"start","socksPort":5000,"bypass":["203.0.113.9"]}`)
	if r["ok"] != true || r["interface"] != "utun100" || r["physicalAddress"] != "192.168.1.50" || r["gateway"] != "192.168.1.1" {
		t.Fatalf("start: %v", r)
	}
	// A second connection cannot start or clean up.
	c2 := dial()
	if r := c2.send(t, `{"id":1,"cmd":"start","socksPort":5001}`); r["ok"] != false ||
		!strings.Contains(r["error"].(string), "Another FoxyVPN window") {
		t.Errorf("second start: %v", r)
	}
	if r := c2.send(t, `{"id":2,"cmd":"cleanup"}`); r["ok"] != false {
		t.Errorf("second cleanup: %v", r)
	}
	// Closing the first connection without stop tears the session down.
	_ = c.conn.Close()
	deadline := time.Now().Add(5 * time.Second)
	for {
		f.mu.Lock()
		n := len(f.ifaces)
		f.mu.Unlock()
		if n == 2 && len(f.dns["Wi-Fi"]) == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("session not torn down after disconnect: %v %v", f.ifaces, f.dns)
		}
		time.Sleep(20 * time.Millisecond)
	}
	// Now the second client can connect.
	if r := c2.send(t, `{"id":3,"cmd":"start","socksPort":5001}`); r["ok"] != true {
		t.Errorf("start after disconnect: %v", r)
	}
	if r := c2.send(t, `{"id":4,"cmd":"refreshBypass"}`); r["ok"] != true {
		t.Errorf("refresh: %v", r)
	}
	if r := c2.send(t, `{"id":5,"cmd":"stop"}`); r["ok"] != true {
		t.Errorf("stop: %v", r)
	}
	if r := c2.send(t, `{"id":6,"cmd":"stop"}`); r["ok"] != true {
		t.Errorf("second stop: %v", r)
	}
	if r := c2.send(t, `{"id":7,"cmd":"refreshBypass"}`); r["ok"] != false {
		t.Errorf("refresh when idle: %v", r)
	}
}

func TestServerExitedEvent(t *testing.T) {
	f := newFake()
	_, dial := startTestServer(t, "/Applications/FoxyVPN.app/Contents/MacOS/FoxyVPN", f)
	c := dial()
	if r := c.send(t, `{"id":1,"cmd":"start","socksPort":5000}`); r["ok"] != true {
		t.Fatal(r)
	}
	f.child.Terminate()
	ev := c.read(t)
	if ev["event"] != "exited" || ev["reason"] == "" {
		t.Errorf("event: %v", ev)
	}
}

func TestServerLineTooLong(t *testing.T) {
	_, dial := startTestServer(t, "/Applications/FoxyVPN.app/Contents/MacOS/FoxyVPN", newFake())
	c := dial()
	big := strings.Repeat("a", 70*1024)
	_, _ = c.conn.Write([]byte(`{"id":1,"cmd":"` + big + `"}` + "\n"))
	r := c.read(t)
	if r["ok"] != false {
		t.Errorf("long line: %v", r)
	}
}

func TestStrangerIsClosedAfterFirstAnswer(t *testing.T) {
	_, dial := startTestServer(t, "/usr/bin/curl", newFake())
	c := dial()
	if h := c.send(t, `{"id":1,"cmd":"hello"}`); h["ok"] != true {
		t.Fatalf("hello: %v", h)
	}
	_ = c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.r.ReadBytes('\n'); err == nil || errors.Is(err, os.ErrDeadlineExceeded) {
		t.Errorf("connection should be closed by the helper, got %v", err)
	}
}

func TestStrangerIdleTimesOut(t *testing.T) {
	srv, dial := startTestServer(t, "/usr/bin/curl", newFake())
	srv.strangerTimeout = 100 * time.Millisecond
	c := dial()
	_ = c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.r.ReadBytes('\n'); err == nil || errors.Is(err, os.ErrDeadlineExceeded) {
		t.Errorf("idle stranger should be dropped by the helper, got %v", err)
	}
}

func TestAllowedPeerStaysOpenWithoutTimeout(t *testing.T) {
	srv, dial := startTestServer(t, "/Applications/FoxyVPN.app/Contents/MacOS/FoxyVPN", newFake())
	srv.strangerTimeout = 50 * time.Millisecond
	c := dial()
	time.Sleep(200 * time.Millisecond)
	for id := 1; id <= 2; id++ {
		if h := c.send(t, `{"id":`+strconv.Itoa(id)+`,"cmd":"hello"}`); h["ok"] != true {
			t.Errorf("hello %d: %v", id, h)
		}
	}
}
