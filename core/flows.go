package main

import (
	"bufio"
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	headerTimeout = 10 * time.Second // client's request line

	maxAttempts = 3 // tries on fresh connections when one was closing
)

var replyTimeout = 20 * time.Second // CONNECT until response headers (a var for tests)

// flows serves the loopback line protocol (see ENGINE_SPEC.md): one request
// line per TCP connection, one reply line, then raw bytes both ways.
type flows struct {
	up     *upstream
	secret string
	token  atomic.Pointer[string]
	// serverAuthority is host:port of the edge: the :authority of CONNECT-UDP.
	serverAuthority string
}

func (f *flows) setToken(t string) { f.token.Store(&t) }

func (f *flows) serve(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go f.handle(c)
	}
}

func (f *flows) handle(c net.Conn) {
	defer c.Close()
	if t, ok := c.(*net.TCPConn); ok {
		_ = t.SetNoDelay(true)
	}
	_ = c.SetReadDeadline(time.Now().Add(headerTimeout))
	r := bufio.NewReaderSize(c, 4096)
	line, err := r.ReadSlice('\n')
	if err != nil {
		return
	}
	fld := strings.Fields(string(line))
	if len(fld) != 4 || subtle.ConstantTimeCompare([]byte(fld[0]), []byte(f.secret)) != 1 {
		return // not the app: say nothing
	}
	kind, host, portS := fld[1], fld[2], fld[3]
	port, perr := strconv.Atoi(portS)
	if (kind != "TCP" && kind != "UDP") || perr != nil || port < 1 || port > 65535 || strings.ContainsAny(host, "/?#@[]\\%") {
		writeLine(c, "ERR 0 - bad request")
		return
	}
	_ = c.SetReadDeadline(time.Time{})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	resp, pw, oe := f.openStream(ctx, cancel, kind, host, port)
	if oe != nil {
		writeLine(c, oe.line())
		return
	}
	defer resp.Body.Close()
	if !writeLine(c, "OK") {
		pw.CloseWithError(io.ErrClosedPipe)
		return
	}
	bridge(c, r, resp.Body, pw, cancel, nil, nil)
}

// Copy buffers: upload is bounded by the HTTP/2 frame size on the other end
// of the pipe, download by what the stream has buffered. Pooled, so a flow
// costs no allocation.
const (
	upBufSize   = 64 << 10
	downBufSize = 128 << 10
)

var (
	upBufs   = sync.Pool{New: func() any { b := make([]byte, upBufSize); return &b }}
	downBufs = sync.Pool{New: func() any { b := make([]byte, downBufSize); return &b }}
)

// copyCount copies src to dst through buf and adds the bytes written to ctr
// (may be nil). A clean end of src is nil.
func copyCount(dst io.Writer, src io.Reader, buf []byte, ctr *atomic.Int64) error {
	for {
		n, rerr := src.Read(buf)
		if n > 0 {
			w, werr := dst.Write(buf[:n])
			if ctr != nil && w > 0 {
				ctr.Add(int64(w))
			}
			if werr != nil {
				return werr
			}
		}
		if rerr != nil {
			if rerr == io.EOF {
				return nil
			}
			return rerr
		}
	}
}

// halfCloseIdle: once the client has half-closed, a stream that receives no
// download bytes for this long is cancelled (safety net against an edge that
// never ends the stream). Any downstream byte resets the timer.
var halfCloseIdle = 5 * time.Minute

// idleBody stamps the time of the last downstream read that returned data.
type idleBody struct {
	io.Reader
	last *atomic.Int64 // unix nanos
}

func (b idleBody) Read(p []byte) (int, error) {
	n, err := b.Reader.Read(p)
	if n > 0 {
		b.last.Store(time.Now().UnixNano())
	}
	return n, err
}

// bridge copies both ways. Client EOF ends the request body (END_STREAM)
// while the response keeps flowing; response EOF becomes a half-close of the
// client socket. A failure on either side cancels the stream, which makes
// x/net send RST_STREAM (in the right order, after HEADERS). up and down
// (may be nil) count the payload bytes moved.
func bridge(c net.Conn, in io.Reader, body io.Reader, pw *io.PipeWriter, cancel context.CancelFunc, up, down *atomic.Int64) {
	var lastDown atomic.Int64
	var halfClosed atomic.Bool
	lastDown.Store(time.Now().UnixNano())
	body = idleBody{body, &lastDown}
	done := make(chan struct{})
	defer close(done)
	idle := halfCloseIdle
	go func() {
		tk := time.NewTicker(max(idle/4, time.Millisecond))
		defer tk.Stop()
		for {
			select {
			case <-done:
				return
			case <-tk.C:
				if halfClosed.Load() && time.Since(time.Unix(0, lastDown.Load())) > idle {
					cancel()
					return
				}
			}
		}
	}()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		bp := upBufs.Get().(*[]byte)
		err := copyCount(pw, in, *bp, up)
		upBufs.Put(bp)
		if err == nil {
			pw.Close() // client EOF: our half-close
			halfClosed.Store(true)
			return
		}
		pw.CloseWithError(err)
		if !errors.Is(err, io.ErrClosedPipe) && !errors.Is(err, os.ErrDeadlineExceeded) {
			cancel() // client socket broke (reset)
		}
	}()

	bp := downBufs.Get().(*[]byte)
	err := copyCount(c, body, *bp, down)
	downBufs.Put(bp)
	// The stream is over: end it.
	cancel()
	pw.CloseWithError(io.ErrClosedPipe)
	if err != nil {
		// The stream broke (reset, connection lost) or the client stopped
		// reading: close the client socket now so it sees the failure.
		c.Close()
	} else {
		// Clean end: half-close, and give a client that keeps its side open
		// a moment before we close.
		if tcp, ok := c.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		}
		_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
	}
	wg.Wait()
}

// trackBody notes whether x/net started reading the request body; if not,
// the request never reached the wire and may be retried on another
// connection.
type trackBody struct {
	io.ReadCloser
	started atomic.Bool
}

func (b *trackBody) Read(p []byte) (int, error) {
	b.started.Store(true)
	return b.ReadCloser.Read(p)
}

// openError is why a stream could not be opened. status is the edge's HTTP
// status (407 when it sent x-fastly-proxy-auth-failed), or 0 for engine and
// transport errors.
type openError struct {
	status      int
	proxyStatus string // "-" when none; spaces replaced by "_"
	msg         string
}

func (e *openError) line() string {
	return fmt.Sprintf("ERR %d %s %s", e.status, e.proxyStatus, e.msg)
}

// authProblem: the edge did not accept our token.
func (e *openError) authProblem() bool {
	return e.status == 401 || e.status == 403 || e.status == 407
}

// openStream sends the CONNECT / CONNECT-UDP request and returns the 2xx
// response plus the writer for the request body. Shared by the line
// protocol, the SOCKS server and the DoH client. Cancelling ctx ends the
// stream.
func (f *flows) openStream(ctx context.Context, cancel context.CancelFunc, kind, host string, port int) (*http.Response, *io.PipeWriter, *openError) {
	tokp := f.token.Load()
	if tokp == nil || *tokp == "" {
		return nil, nil, &openError{0, "-", "no token"}
	}
	auth := "Bearer " + *tokp

	var timedOut atomic.Bool
	timer := time.AfterFunc(replyTimeout, func() { timedOut.Store(true); cancel() })
	defer timer.Stop()

	for attempt := 1; ; attempt++ {
		pc, err := f.up.get(ctx)
		if err != nil {
			return nil, nil, errOf(err, timedOut.Load())
		}
		pr, pw := io.Pipe()
		body := &trackBody{ReadCloser: pr}
		req := f.newRequest(ctx, kind, host, port, auth, body)
		resp, err := pc.cc.RoundTrip(req)
		if err != nil {
			pr.Close()
			if attempt < maxAttempts && !body.started.Load() && retryable(err) && ctx.Err() == nil {
				continue
			}
			return nil, nil, errOf(err, timedOut.Load())
		}
		if resp.StatusCode/100 != 2 {
			defer resp.Body.Close()
			pr.Close()
			status := resp.StatusCode
			// Fastly says "bad token" with a header; Dart renews the pass on 407.
			if _, ok := resp.Header["X-Fastly-Proxy-Auth-Failed"]; ok {
				status = 407
			}
			ps := "-"
			if v := resp.Header.Get("Proxy-Status"); v != "" {
				ps = strings.ReplaceAll(strings.Join(strings.Fields(v), " "), " ", "_")
			}
			msg := http.StatusText(resp.StatusCode)
			if msg == "" {
				msg = "HTTP " + strconv.Itoa(resp.StatusCode)
			}
			return nil, nil, &openError{status, ps, msg}
		}
		return resp, pw, nil
	}
}

func (f *flows) newRequest(ctx context.Context, kind, host string, port int, auth string, body io.ReadCloser) *http.Request {
	hp := net.JoinHostPort(host, strconv.Itoa(port)) // brackets IPv6
	req := &http.Request{
		Method: http.MethodConnect,
		// Empty User-Agent: x/net then omits it (it would add Go-http-client).
		Header:        http.Header{"Proxy-Authorization": {auth}, "User-Agent": {""}},
		Body:          body,
		ContentLength: -1,
		Proto:         "HTTP/2.0", ProtoMajor: 2,
	}
	if kind == "TCP" {
		req.Host = hp
		req.URL = &url.URL{Host: hp}
	} else {
		// RFC 9298 over extended CONNECT (RFC 8441/9220). x/net sends
		// :protocol when the header ":protocol" is present (set through the
		// map: it is not a valid canonical header name).
		raw := connectUDPPath(host, port)
		path, _ := url.PathUnescape(raw)
		req.Host = f.serverAuthority
		req.URL = &url.URL{Scheme: "https", Host: f.serverAuthority, Path: path, RawPath: raw}
		req.Header[":protocol"] = []string{"connect-udp"}
		req.Header["Capsule-Protocol"] = []string{"?1"}
	}
	return req.WithContext(ctx)
}

// connectUDPPath mirrors connectUdpPath in lib/tunnel/udp_relay.dart:
// IPv6 colons become %3A, names are percent-encoded like Dart's
// Uri.encodeComponent.
func connectUDPPath(host string, port int) string {
	var t string
	if strings.Contains(host, ":") {
		t = strings.ReplaceAll(host, ":", "%3A")
	} else {
		var b strings.Builder
		for i := 0; i < len(host); i++ {
			ch := host[i]
			if ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || strings.IndexByte("-_.!~*'()", ch) >= 0 {
				b.WriteByte(ch)
			} else {
				fmt.Fprintf(&b, "%%%02X", ch)
			}
		}
		t = b.String()
	}
	return fmt.Sprintf("/.well-known/masque/udp/%s/%d/", t, port)
}

// retryable: the request was refused before it was sent because the
// connection is closing, full or closed; a new connection can take it.
func retryable(err error) bool {
	s := err.Error()
	return strings.Contains(s, "graceful shutdown GOAWAY") ||
		strings.Contains(s, "client conn not usable") ||
		strings.Contains(s, "client conn is closed") ||
		strings.Contains(s, "client conn could not be established")
}

func errOf(err error, timedOut bool) *openError {
	if timedOut || errors.Is(err, context.DeadlineExceeded) {
		return &openError{0, "-", "timeout"}
	}
	msg := strings.Join(strings.Fields(err.Error()), " ")
	if len(msg) > 200 {
		msg = msg[:200]
	}
	return &openError{0, "-", msg}
}

func writeLine(c net.Conn, s string) bool {
	_ = c.SetWriteDeadline(time.Now().Add(headerTimeout))
	_, err := io.WriteString(c, s+"\n")
	_ = c.SetWriteDeadline(time.Time{})
	return err == nil
}
