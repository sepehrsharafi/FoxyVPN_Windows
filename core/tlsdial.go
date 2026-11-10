package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	utls "github.com/refraction-networking/utls"
)

const (
	dialTimeout      = 10 * time.Second
	handshakeTimeout = 15 * time.Second
)

// tlsConn is what both TLS stacks give us.
type tlsConn interface {
	net.Conn
}

var (
	// roots is the system pool plus GlobalSign R46/E46 (see roots.go);
	// tests add their own root through extraRoots.
	rootsOnce  sync.Once
	rootsPool  *x509.CertPool
	extraRoots []*x509.Certificate

	sessions   = utls.NewLRUClientSessionCache(64)
	goSessions = tls.NewLRUClientSessionCache(64)
)

func roots() *x509.CertPool {
	rootsOnce.Do(func() {
		pool, err := x509.SystemCertPool()
		if err != nil || pool == nil {
			pool = x509.NewCertPool()
		}
		pool.AppendCertsFromPEM([]byte(globalSignRoots))
		for _, c := range extraRoots {
			pool.AddCert(c)
		}
		rootsPool = pool
	})
	return rootsPool
}

// dialTLS connects to the pinned IP and does the TLS handshake with
// Firefox's ClientHello (uTLS), so the connection looks like a browser to
// every network on the way. If that handshake fails (the connect worked),
// it retries once with crypto/tls, h2 only. Either way h2 must be agreed.
// info is the "tls" text of the connected event.
func dialTLS(ctx context.Context, ip, serverName string, port int, sndbuf int) (c net.Conn, info string, err error) {
	c, info, err = dialOnce(ctx, ip, serverName, port, sndbuf, true)
	var he *handshakeError
	if err != nil && errors.As(err, &he) {
		first := err
		c, info, err = dialOnce(ctx, ip, serverName, port, sndbuf, false)
		if err != nil {
			err = fmt.Errorf("%v; retry with Go TLS: %v", first, err)
		}
	}
	return
}

// handshakeError marks failures after TCP connected.
type handshakeError struct{ err error }

func (e *handshakeError) Error() string { return e.err.Error() }
func (e *handshakeError) Unwrap() error { return e.err }

func dialOnce(ctx context.Context, ip, serverName string, port int, sndbuf int, firefox bool) (net.Conn, string, error) {
	d := net.Dialer{Timeout: dialTimeout, KeepAlive: 30 * time.Second}
	raw, err := d.DialContext(ctx, "tcp4", net.JoinHostPort(ip, fmt.Sprint(port)))
	if err != nil {
		return nil, "", err
	}
	if tcp, ok := raw.(*net.TCPConn); ok {
		_ = tcp.SetNoDelay(true)
		// Optional experiment: a small kernel send buffer keeps small frames
		// (WINDOW_UPDATE, HEADERS) from queueing behind a big upload.
		if sndbuf > 0 {
			_ = tcp.SetWriteBuffer(sndbuf)
		}
	}
	hctx, cancel := context.WithTimeout(ctx, handshakeTimeout)
	defer cancel()

	var conn tlsConn
	var proto string
	var version uint16

	if firefox {
		u := utls.UClient(raw, &utls.Config{
			ServerName:         serverName,
			RootCAs:            roots(),
			MinVersion:         utls.VersionTLS12,
			NextProtos:         []string{"h2", "http/1.1"},
			ClientSessionCache: sessions,
		}, utls.HelloFirefox_Auto)
		if err := u.HandshakeContext(hctx); err != nil {
			raw.Close()
			return nil, "", &handshakeError{fmt.Errorf("TLS handshake (firefox): %w", err)}
		}
		st := u.ConnectionState()
		conn, proto, version = u, st.NegotiatedProtocol, st.Version
	} else {
		g := tls.Client(raw, &tls.Config{
			ServerName:         serverName,
			RootCAs:            roots(),
			MinVersion:         tls.VersionTLS12,
			NextProtos:         []string{"h2"},
			ClientSessionCache: goSessions,
		})
		if err := g.HandshakeContext(hctx); err != nil {
			raw.Close()
			return nil, "", &handshakeError{fmt.Errorf("TLS handshake (go): %w", err)}
		}
		st := g.ConnectionState()
		conn, proto, version = g, st.NegotiatedProtocol, st.Version
	}
	if proto != "h2" {
		conn.Close()
		return nil, "", &handshakeError{fmt.Errorf("server did not agree to HTTP/2 (got %q)", proto)}
	}
	v := "tls1.3"
	if version == tls.VersionTLS12 {
		v = "tls1.2"
	}
	who := "go"
	if firefox {
		who = "firefox"
	}
	return conn, v + " h2 " + who, nil
}
