// foxy-tls: the TLS layer of FoxyVPN's connection to Mozilla's VPN servers
// (Fastly), started by the Windows app next to foxyvpn.exe.
//
// Dart's TLS client cannot change its ClientHello, which tells every network
// on the way that this is not a browser. This helper does the TLS handshake
// with Firefox's ClientHello (uTLS) and then only copies bytes: the app still
// speaks HTTP/2 itself, over a plain local connection to this helper.
//
// It only ever connects to the address the app names (the pinned IPv4 of
// Mozilla's server). Nothing else, no relay, goes through it.
//
// Protocol:
//   - Started with no arguments. Prints "FOXYTLS <port> <secret>\n" on stdout
//     once it listens on 127.0.0.1:<port>. Exits when its stdin closes (the
//     app quit or crashed).
//   - Per local connection, the app first sends one line:
//     "<secret> <ip> <port> <server name>\n".
//     The helper answers "OK <tls version> <alpn>\n" once TLS is up and h2 was
//     agreed (then copies bytes both ways), or "ERR <message>\n" and closes.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	utls "github.com/refraction-networking/utls"
)

const (
	dialTimeout      = 10 * time.Second
	handshakeTimeout = 15 * time.Second
	headerTimeout    = 10 * time.Second
)

var (
	roots    *x509.CertPool
	sessions = utls.NewLRUClientSessionCache(64)
	secret   string
)

func main() {
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		pool = x509.NewCertPool()
	}
	pool.AppendCertsFromPEM([]byte(globalSignRoots))
	roots = pool

	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		fmt.Fprintln(os.Stderr, "no randomness:", err)
		os.Exit(1)
	}
	secret = hex.EncodeToString(buf)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		os.Exit(1)
	}
	fmt.Printf("FOXYTLS %d %s\n", ln.Addr().(*net.TCPAddr).Port, secret)

	// The app holds our stdin open for as long as it wants us.
	go func() {
		_, _ = io.Copy(io.Discard, os.Stdin)
		os.Exit(0)
	}()

	for {
		c, err := ln.Accept()
		if err != nil {
			fmt.Fprintln(os.Stderr, "accept:", err)
			os.Exit(1)
		}
		go serve(c)
	}
}

func serve(local net.Conn) {
	defer local.Close()
	_ = local.SetDeadline(time.Now().Add(headerTimeout))
	r := bufio.NewReaderSize(local, 512)
	line, err := r.ReadString('\n')
	if err != nil {
		return
	}
	f := strings.Fields(line)
	if len(f) != 4 || subtle.ConstantTimeCompare([]byte(f[0]), []byte(secret)) != 1 {
		return // not the app: say nothing
	}
	ip := net.ParseIP(f[1])
	port, perr := strconv.Atoi(f[2])
	if ip == nil || perr != nil || port <= 0 || port > 65535 {
		reply(local, "ERR bad request")
		return
	}
	_ = local.SetDeadline(time.Time{})

	remote, tlsInfo, err := connect(ip, port, f[3])
	if err != nil {
		reply(local, "ERR "+oneLine(err.Error()))
		return
	}
	defer remote.Close()
	if !reply(local, "OK "+tlsInfo) {
		return
	}
	pipe(local, r, remote)
}

func connect(ip net.IP, port int, name string) (net.Conn, string, error) {
	d := net.Dialer{Timeout: dialTimeout, KeepAlive: 30 * time.Second}
	raw, err := d.Dial("tcp4", net.JoinHostPort(ip.String(), strconv.Itoa(port)))
	if err != nil {
		return nil, "", err
	}
	if tcp, ok := raw.(*net.TCPConn); ok {
		_ = tcp.SetNoDelay(true)
	}
	conn := utls.UClient(raw, &utls.Config{
		ServerName:         name,
		RootCAs:            roots,
		MinVersion:         utls.VersionTLS12,
		NextProtos:         []string{"h2", "http/1.1"},
		ClientSessionCache: sessions,
	}, utls.HelloFirefox_Auto)
	ctx, cancel := context.WithTimeout(context.Background(), handshakeTimeout)
	defer cancel()
	if err := conn.HandshakeContext(ctx); err != nil {
		_ = raw.Close()
		return nil, "", fmt.Errorf("TLS handshake: %w", err)
	}
	st := conn.ConnectionState()
	if st.NegotiatedProtocol != "h2" {
		_ = conn.Close()
		return nil, "", errors.New("server did not agree to HTTP/2 (got " + st.NegotiatedProtocol + ")")
	}
	version := "tls1.3"
	if st.Version == utls.VersionTLS12 {
		version = "tls1.2"
	}
	resumed := "new"
	if st.DidResume {
		resumed = "resumed"
	}
	return conn, version + " " + st.NegotiatedProtocol + " " + resumed, nil
}

func reply(c net.Conn, s string) bool {
	_ = c.SetWriteDeadline(time.Now().Add(headerTimeout))
	_, err := io.WriteString(c, s+"\n")
	_ = c.SetWriteDeadline(time.Time{})
	return err == nil
}

// pipe copies both ways; the end of one direction is passed on as a
// half-close where possible, and both close once both directions are done.
func pipe(local net.Conn, localIn *bufio.Reader, remote net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(remote, localIn)
		if cw, ok := remote.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		} else {
			_ = remote.Close()
		}
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(local, remote)
		if tcp, ok := local.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		} else {
			_ = local.Close()
		}
	}()
	wg.Wait()
}

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
