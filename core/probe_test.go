package main

import (
	"bufio"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"
)

func probeBackend(t *testing.T, status int) string {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/generate_204" || r.Host != probeTarget {
			w.WriteHeader(404)
			return
		}
		w.WriteHeader(status)
	}))
	t.Cleanup(s.Close)
	return strings.TrimPrefix(s.URL, "http://")
}

func TestProbeMeasuresDelay(t *testing.T) {
	edge := newTestEdge(t)
	edge.setBackend(probeTarget+":80", probeBackend(t, 204))
	srv := net.JoinHostPort(edgeName, strconv.Itoa(edge.port))
	ms, e := probeOne(t.Context(), "127.0.0.1", srv, "tok", 5*time.Second)
	if e != "" || ms < 1 {
		t.Fatalf("ms=%d err=%q", ms, e)
	}
	reqs := edge.requests()
	if len(reqs) != 1 || reqs[0].method != "CONNECT" || reqs[0].authority != probeTarget+":80" || reqs[0].auth != "Bearer tok" {
		t.Fatalf("edge saw %+v", reqs)
	}
	edge.setBackend(probeTarget+":80", probeBackend(t, 200))
	if _, e := probeOne(t.Context(), "127.0.0.1", srv, "tok", 5*time.Second); e != "" {
		t.Fatalf("200 should be accepted: %q", e)
	}
	edge.setBackend(probeTarget+":80", probeBackend(t, 500))
	if _, e := probeOne(t.Context(), "127.0.0.1", srv, "tok", 5*time.Second); e != "target 500" {
		t.Fatalf("got %q", e)
	}
}

func TestProbeRefusedAuthTimeout(t *testing.T) {
	edge := newTestEdge(t)
	srv := net.JoinHostPort(edgeName, strconv.Itoa(edge.port))
	old := probeTarget
	t.Cleanup(func() { probeTarget = old })

	probeTarget = "refuse.test"
	if _, e := probeOne(t.Context(), "127.0.0.1", srv, "tok", 5*time.Second); e != "http 502" {
		t.Fatalf("refused: %q", e)
	}
	probeTarget = "authfail.test"
	if _, e := probeOne(t.Context(), "127.0.0.1", srv, "tok", 5*time.Second); e != "auth" {
		t.Fatalf("auth: %q", e)
	}
	probeTarget = "hang.test"
	start := time.Now()
	if _, e := probeOne(t.Context(), "127.0.0.1", srv, "tok", 400*time.Millisecond); e != "timeout" || time.Since(start) > 3*time.Second {
		t.Fatalf("timeout: %q after %v", e, time.Since(start))
	}
	// Nothing listens: a quick, short error.
	if _, e := probeOne(t.Context(), "127.0.0.1", net.JoinHostPort(edgeName, "1"), "tok", 2*time.Second); e == "" || e == "auth" {
		t.Fatalf("dead edge: %q", e)
	}
}

// The real process: stdin token + list, JSON lines out, probe_done, exit.
func TestProbeProcess(t *testing.T) {
	edge := newTestEdge(t)
	edge.setBackend(probeTarget+":80", probeBackend(t, 204))
	good := net.JoinHostPort(edgeName, strconv.Itoa(edge.port))
	bad := net.JoinHostPort(edgeName, "1")
	cmd := exec.Command(os.Args[0], "--probe", "--ip", "127.0.0.1", "--timeout", "3s", "--test-root", edge.certFile)
	cmd.Env = append(os.Environ(), "FOXY_CORE_MAIN=1")
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill() })
	stdin.Write([]byte(`{"token":"tok"}` + "\n"))
	b, _ := json.Marshal(map[string]any{"probe": []string{good, bad}})
	stdin.Write(append(b, '\n'))

	got := map[string]map[string]any{}
	r := bufio.NewReader(stdout)
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			t.Fatalf("stdout ended before probe_done: %v", err)
		}
		var m map[string]any
		json.Unmarshal([]byte(line), &m)
		if m["type"] == "probe_done" {
			break
		}
		if m["type"] != "probe" {
			t.Fatalf("unexpected %v", m)
		}
		got[m["server"].(string)] = m
	}
	if got[good]["ms"] == nil || got[bad]["error"] == nil {
		t.Fatalf("results %v", got)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("exit: %v", err)
	}
}
