// foxy-core: the data plane of FoxyVPN. One process per VPN session; it
// holds an HTTP/2 connection (TLS with Firefox's ClientHello) to Mozilla's
// VPN edge (Fastly MASQUE) and carries every TCP and UDP flow of the app as
// a CONNECT / CONNECT-UDP stream on it. The app talks to us over stdin
// (token), stdout (events) and a loopback socket (flows); see flows.go.
//
// Build and test with -tags http2legacy: on Go 1.27+ x/net/http2 otherwise
// wraps net/http's own HTTP/2 client, which rejects the :protocol header
// that CONNECT-UDP needs. The tag selects the x/net client on every Go version.
//
// We only ever connect to the pinned edge IP we are given. Sign-in and
// passes stay in the app.
package main

import (
	"bufio"
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"net"
	"os"
	"strconv"
	"time"
)

func main() {
	server := flag.String("server", "", "edge host:port (SNI and :authority of CONNECT-UDP)")
	ip := flag.String("ip", "", "pinned IPv4 of the edge")
	sndbuf := flag.Int("sndbuf", 0, "kernel send buffer in bytes (0 = OS default)")
	socks := flag.Bool("socks", false, "serve SOCKS5 (CONNECT, UDP ASSOCIATE) on 127.0.0.1")
	socksPort := flag.Int("socks-port", 0, "SOCKS5 port (0 = any)")
	testRoot := flag.String("test-root", "", "") // hidden: extra trusted root PEM file, for tests only
	flag.Parse()

	host, portS, err := net.SplitHostPort(*server)
	port, perr := strconv.Atoi(portS)
	if err != nil || perr != nil || net.ParseIP(*ip) == nil {
		fmt.Fprintln(os.Stderr, "usage: foxy-core --server host:port --ip IPv4 [--sndbuf N] [--socks [--socks-port N]]")
		os.Exit(2)
	}
	if *testRoot != "" {
		if pemBytes, err := os.ReadFile(*testRoot); err == nil {
			if blk, _ := pem.Decode(pemBytes); blk != nil {
				if c, err := x509.ParseCertificate(blk.Bytes); err == nil {
					extraRoots = append(extraRoots, c)
				}
			}
		}
	}

	ev := newEvents(os.Stdout)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		os.Exit(1)
	}
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		fmt.Fprintln(os.Stderr, "no randomness:", err)
		os.Exit(1)
	}
	secret := hex.EncodeToString(b)

	up := newUpstream(host, port, *ip, *sndbuf, ev)
	f := &flows{up: up, secret: secret, serverAuthority: *server}
	socksLn, sp := (net.Listener)(nil), 0
	if *socks {
		var err error
		socksLn, err = net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(*socksPort)))
		if err != nil {
			fmt.Fprintln(os.Stderr, "socks listen:", err)
			os.Exit(1)
		}
		sp = socksLn.Addr().(*net.TCPAddr).Port
	}
	ev.listening(ln.Addr().(*net.TCPAddr).Port, secret, sp)

	// The token comes first, and nothing connects before it.
	in := bufio.NewReader(os.Stdin)
	if !readToken(in, f) {
		os.Exit(0)
	}
	up.start()
	go f.serve(ln)
	if socksLn != nil {
		st := &stats{}
		go st.run(ev, time.Second)
		go newSocksServer(f, ev, st).serve(socksLn)
	}
	// Later lines replace the token for new streams. EOF: the app quit or
	// crashed; exit at once (the OS closes every socket).
	for readToken(in, f) {
	}
	os.Exit(0)
}

// readToken reads one {"token":"..."} line. false on EOF. The token is never
// logged. Lines that are not a token are ignored.
func readToken(in *bufio.Reader, f *flows) bool {
	for {
		line, err := in.ReadBytes('\n')
		var m struct {
			Token string `json:"token"`
		}
		if json.Unmarshal(line, &m) == nil && m.Token != "" {
			f.setToken(m.Token)
			return true
		}
		if err != nil {
			return false
		}
	}
}
