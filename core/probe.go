package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Probe mode: `foxy-core --probe --ip <IPv4> [--concurrency 4] [--timeout 5s]`.
//
// stdin:  {"token":"..."}\n then {"probe":["host:port", ...]}\n (more probe
//
//	lines may follow; stdin EOF ends the wait).
//
// stdout: one {"type":"probe","server":"host:port","ms":N} or
//
//	{"type":"probe","server":"...","error":"timeout|auth|<short>"} per server,
//	then {"type":"probe_done"}, then the process exits.
//
// Per server: TLS (Firefox hello, SNI = that host) to the pinned edge IP,
// HTTP/2, one CONNECT to cp.cloudflare.com:80, GET /generate_204, and the time
// from sending the CONNECT to the HTTP status line is the result. The TLS
// handshake to the (shared) edge is not part of it. The token is never logged.

var probeTarget = "cp.cloudflare.com" // a var for tests

const probeTargetPort = 80

// probeDial makes the TLS connection for one probe; replaced in tests.
var probeDial = func(ctx context.Context, ip, host string, port int) (net.Conn, error) {
	c, _, err := dialTLS(ctx, ip, host, port, 0)
	return c, err
}

// probeOne tests one server and returns the delay in ms or a short error
// ("timeout", "auth", or a few words).
func probeOne(parent context.Context, ip, server, token string, timeout time.Duration) (int, string) {
	host, portS, err := net.SplitHostPort(server)
	port, perr := strconv.Atoi(portS)
	if err != nil || perr != nil || host == "" {
		return 0, "bad server"
	}
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	nc, err := probeDial(ctx, ip, host, port)
	if err != nil {
		return 0, probeErr(err, ctx)
	}
	u := newUpstream(host, port, ip, 0, nil)
	cc, err := u.tr.NewClientConn(nc)
	if err != nil {
		nc.Close()
		return 0, probeErr(err, ctx)
	}
	defer cc.Close() // also closes nc

	f := &flows{serverAuthority: server}
	pr, pw := io.Pipe()
	defer pw.Close()
	rctx, rcancel := context.WithCancel(ctx)
	defer rcancel()
	req := f.newRequest(rctx, "TCP", probeTarget, probeTargetPort, "Bearer "+token, pr)

	t0 := time.Now()
	resp, err := cc.RoundTrip(req)
	if err != nil {
		pr.Close()
		return 0, probeErr(err, ctx)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		if _, ok := resp.Header["X-Fastly-Proxy-Auth-Failed"]; ok || resp.StatusCode == 407 || resp.StatusCode == 401 || resp.StatusCode == 403 {
			return 0, "auth"
		}
		return 0, "http " + strconv.Itoa(resp.StatusCode)
	}
	go func() {
		_, _ = io.WriteString(pw, "GET /generate_204 HTTP/1.1\r\nHost: "+probeTarget+"\r\nConnection: close\r\n\r\n")
	}()
	line, err := bufio.NewReaderSize(resp.Body, 512).ReadString('\n')
	ms := int(time.Since(t0).Milliseconds())
	if ctx.Err() != nil {
		return 0, "timeout"
	}
	fld := strings.Fields(line)
	if len(fld) < 2 || !strings.HasPrefix(fld[0], "HTTP/") {
		if err != nil {
			return 0, probeErr(err, ctx)
		}
		return 0, "bad reply"
	}
	if fld[1] != "204" && fld[1] != "200" {
		return 0, "target " + fld[1]
	}
	return max(ms, 1), ""
}

func probeErr(err error, ctx context.Context) string {
	if ctx.Err() != nil || errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	var he *handshakeError
	msg := strings.Join(strings.Fields(err.Error()), " ")
	if len(msg) > 120 {
		msg = msg[:120]
	}
	msg = "connect failed: " + msg
	if errors.As(err, &he) {
		msg = "tls failed"
	} else if strings.Contains(err.Error(), "refused") || strings.Contains(err.Error(), "unreachable") {
		msg = "unreachable"
	} else if strings.Contains(err.Error(), "GOAWAY") || strings.Contains(err.Error(), "RST_STREAM") || strings.Contains(err.Error(), "stream error") {
		msg = "refused"
	}
	return msg
}

// readProbeList reads stdin: the token line, then the first probe line.
func readProbeList(in *bufio.Reader) (token string, servers []string, ok bool) {
	for {
		line, err := in.ReadBytes('\n')
		var m struct {
			Token string   `json:"token"`
			Probe []string `json:"probe"`
		}
		if json.Unmarshal(line, &m) == nil {
			if m.Token != "" {
				token = m.Token
			}
			if m.Probe != nil {
				return token, m.Probe, token != ""
			}
		}
		if err != nil {
			return token, nil, false
		}
	}
}

// runProbe tests every server (at most conc at a time) and emits the results.
func runProbe(ev *events, ip string, conc int, timeout time.Duration, token string, servers []string) {
	sem := make(chan struct{}, min(max(conc, 1), 16))
	var wg sync.WaitGroup
	for _, s := range servers {
		wg.Add(1)
		sem <- struct{}{}
		go func(s string) {
			defer wg.Done()
			defer func() { <-sem }()
			ms, e := probeOne(context.Background(), ip, s, token, timeout)
			m := map[string]any{"type": "probe", "server": s}
			if e != "" {
				m["error"] = e
			} else {
				m["ms"] = ms
			}
			ev.emit(m)
		}(s)
	}
	wg.Wait()
	ev.emit(map[string]any{"type": "probe_done"})
}
