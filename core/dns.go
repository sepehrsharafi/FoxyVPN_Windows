package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// DNS over HTTPS (RFC 8484) to Cloudflare, with the HTTPS connection carried
// through the tunnel as a CONNECT stream, so lookups do not leak and work
// although the edge prohibits UDP port 53. Mirrors lib/tunnel/dns.dart.

var dohHost = "cloudflare-dns.com" // a var for tests

const (
	dohTimeout     = 8 * time.Second
	dnsCacheMax    = 512
	dnsCacheMaxTTL = time.Hour
)

type dohClient struct {
	f    *flows
	ev   *events
	host string
	hc   *http.Client

	mu    sync.Mutex
	cache map[string]dnsEntry
}

type dnsEntry struct {
	answer  []byte
	expires time.Time
}

// newDoHClient: pool nil = the system pool plus GlobalSign.
func newDoHClient(f *flows, ev *events, host string, pool *x509.CertPool) *dohClient {
	if pool == nil {
		pool = roots()
	}
	d := &dohClient{f: f, ev: ev, host: host, cache: map[string]dnsEntry{}}
	d.hc = &http.Client{Transport: &http.Transport{
		Proxy:               nil,
		DialContext:         d.dial,
		ForceAttemptHTTP2:   true, // one connection carries many queries
		MaxIdleConns:        8,
		MaxIdleConnsPerHost: 4,
		IdleConnTimeout:     30 * time.Second,
		TLSHandshakeTimeout: dohTimeout,
		DisableCompression:  true,
		TLSClientConfig:     &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
	}}
	return d
}

// dial opens a CONNECT stream to addr (cloudflare-dns.com:443) and wraps it
// as a net.Conn. The stream must outlive ctx (the dial's context ends once the
// connection is made), so it gets its own context that ctx only cancels while
// the stream is still being opened.
func (d *dohClient) dial(ctx context.Context, _, addr string) (net.Conn, error) {
	host, portS, err := net.SplitHostPort(addr)
	port, perr := strconv.Atoi(portS)
	if err != nil || perr != nil {
		return nil, fmt.Errorf("bad address %q", addr)
	}
	sctx, scancel := context.WithCancel(context.Background())
	stop := context.AfterFunc(ctx, scancel)
	resp, pw, oe := d.f.openStream(sctx, scancel, "TCP", host, port)
	if !stop() { // ctx ended first: the stream was cancelled with it
		scancel()
		if resp != nil {
			resp.Body.Close()
			pw.CloseWithError(io.ErrClosedPipe)
		}
		return nil, ctx.Err()
	}
	if oe != nil {
		scancel()
		if oe.authProblem() {
			d.ev.authFailed()
		}
		return nil, errors.New(oe.line())
	}
	return &streamConn{body: resp.Body, pw: pw, cancel: scancel}, nil
}

// streamConn presents a CONNECT stream as a net.Conn. Deadlines are no-ops:
// the DoH client bounds every request with a context, and Close ends the
// stream and unblocks Read.
type streamConn struct {
	body   io.ReadCloser
	pw     *io.PipeWriter
	cancel context.CancelFunc
	once   sync.Once
}

func (c *streamConn) Read(p []byte) (int, error)  { return c.body.Read(p) }
func (c *streamConn) Write(p []byte) (int, error) { return c.pw.Write(p) }
func (c *streamConn) Close() error {
	c.once.Do(func() {
		c.cancel()
		c.pw.CloseWithError(io.ErrClosedPipe)
		c.body.Close()
	})
	return nil
}
func (c *streamConn) LocalAddr() net.Addr              { return streamAddr{} }
func (c *streamConn) RemoteAddr() net.Addr             { return streamAddr{} }
func (c *streamConn) SetDeadline(time.Time) error      { return nil }
func (c *streamConn) SetReadDeadline(time.Time) error  { return nil }
func (c *streamConn) SetWriteDeadline(time.Time) error { return nil }

type streamAddr struct{}

func (streamAddr) Network() string { return "tunnel" }
func (streamAddr) String() string  { return "tunnel" }

// resolve returns the wire-format answer for query: from the cache, else from
// DoH (two attempts), else a SERVFAIL. An error only for a malformed query.
func (d *dohClient) resolve(query []byte) ([]byte, error) {
	key, ok := dnsCacheKey(query)
	if !ok {
		return nil, errors.New("malformed DNS query")
	}
	now := time.Now()
	d.mu.Lock()
	if e, hit := d.cache[key]; hit {
		if e.expires.After(now) {
			a := bytes.Clone(e.answer)
			d.mu.Unlock()
			a[0], a[1] = query[0], query[1]
			return a, nil
		}
		delete(d.cache, key)
	}
	d.mu.Unlock()

	var answer []byte
	for attempt := 0; attempt < 2 && answer == nil; attempt++ {
		if a, err := d.post(query); err == nil {
			answer = a
		}
	}
	if answer == nil {
		return servfail(query), nil
	}
	if ttl, ok := dnsCacheableTTL(answer); ok {
		d.mu.Lock()
		if len(d.cache) >= dnsCacheMax {
			for k := range d.cache { // random victim
				delete(d.cache, k)
				break
			}
		}
		d.cache[key] = dnsEntry{answer, now.Add(ttl)}
		d.mu.Unlock()
	}
	return answer, nil
}

func (d *dohClient) post(query []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), dohTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+d.host+"/dns-query", bytes.NewReader(query))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/dns-message")
	req.Header.Set("Accept", "application/dns-message")
	resp, err := d.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("DoH HTTP %d", resp.StatusCode)
	}
	if len(body) < 12 {
		return nil, errors.New("short DoH answer")
	}
	return body, nil
}

// servfail is a SERVFAIL reply that echoes the question of q.
func servfail(q []byte) []byte {
	if len(q) < 12 {
		return make([]byte, 12)
	}
	end, ok := dnsQuestionEnd(q)
	if !ok {
		end = 12
	}
	r := bytes.Clone(q[:end])
	r[2] = 0x80 | (q[2] & 0x01) // QR, keep RD
	r[3] = 0x80 | 0x02          // RA, SERVFAIL
	for i := 6; i < 12; i++ {   // no answer/authority/additional records
		r[i] = 0
	}
	return r
}

// dnsQuestionEnd is the offset just past the first question.
func dnsQuestionEnd(m []byte) (int, bool) {
	if len(m) < 12 || binary.BigEndian.Uint16(m[4:]) < 1 {
		return 0, false
	}
	n, ok := dnsSkipName(m, 12)
	if !ok || n+4 > len(m) {
		return 0, false
	}
	return n + 4, true
}

func dnsSkipName(m []byte, off int) (int, bool) {
	for off < len(m) {
		l := int(m[off])
		if l == 0 {
			return off + 1, true
		}
		if l&0xC0 == 0xC0 {
			if off+2 <= len(m) {
				return off + 2, true
			}
			return 0, false
		}
		off += 1 + l
	}
	return 0, false
}

// dnsCacheKey: RD flag plus the lowercased question (name, type, class); the
// ID and other flags are excluded.
func dnsCacheKey(q []byte) (string, bool) {
	end, ok := dnsQuestionEnd(q)
	if !ok {
		return "", false
	}
	k := make([]byte, 0, end-11)
	k = append(k, q[2]&1)
	for _, b := range q[12:end] {
		if b >= 'A' && b <= 'Z' {
			b += 32
		}
		k = append(k, b)
	}
	return string(k), true
}

// dnsCacheableTTL: a NOERROR answer with records is cached for its smallest
// TTL, capped.
func dnsCacheableTTL(m []byte) (time.Duration, bool) {
	if len(m) < 12 {
		return 0, false
	}
	truncated := m[2]&0x02 != 0
	rcode := m[3] & 0x0f
	answers := int(binary.BigEndian.Uint16(m[6:]))
	if truncated || rcode != 0 || answers == 0 {
		return 0, false
	}
	off, ok := dnsQuestionEnd(m)
	if !ok {
		return 0, false
	}
	minTTL := uint32(dnsCacheMaxTTL / time.Second)
	for i := 0; i < answers; i++ {
		ne, ok := dnsSkipName(m, off)
		if !ok || ne+10 > len(m) {
			return 0, false
		}
		if ttl := binary.BigEndian.Uint32(m[ne+4:]); ttl < minTTL {
			minTTL = ttl
		}
		off = ne + 10 + int(binary.BigEndian.Uint16(m[ne+8:]))
	}
	if minTTL == 0 {
		return 0, false
	}
	return time.Duration(minTTL) * time.Second, true
}
