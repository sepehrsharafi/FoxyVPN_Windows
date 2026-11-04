// fakesocks is a tiny SOCKS5 server for the live macOS smoke test. It supports CONNECT (relayed
// to the real destination) and UDP ASSOCIATE (DNS datagrams are forwarded to a real resolver),
// and logs what it sees. Its outgoing sockets are pinned to the physical interface with
// IP_BOUND_IF so they bypass the tunnel (otherwise the traffic would loop into itself).
package main

import (
	"context"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

var (
	ifaceName = flag.String("iface", "", "physical interface to pin outgoing sockets to (e.g. en0)")
	logPath   = flag.String("log", "socks.log", "file that receives one line per CONNECT / DNS query")
	portFile  = flag.String("portfile", "socks.port", "file that receives the listening port")
	resolver  = flag.String("resolver", "1.1.1.1:53", "real DNS server used for UDP port 53")
)

var (
	logMu  sync.Mutex
	logOut *os.File
	ifIdx  int
)

func logf(format string, args ...any) {
	logMu.Lock()
	defer logMu.Unlock()
	fmt.Fprintf(logOut, format+"\n", args...)
}

func main() {
	flag.Parse()
	var err error
	logOut, err = os.OpenFile(*logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		fatal(err)
	}
	if *ifaceName != "" {
		ifc, err := net.InterfaceByName(*ifaceName)
		if err != nil {
			fatal(err)
		}
		ifIdx = ifc.Index
	}
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		fatal(err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	if err := os.WriteFile(*portFile, []byte(fmt.Sprint(port)), 0o644); err != nil {
		fatal(err)
	}
	for {
		c, err := l.Accept()
		if err != nil {
			fatal(err)
		}
		go func() {
			defer func() { _ = recover() }()
			serve(c)
		}()
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "fakesocks:", err)
	os.Exit(1)
}

func serve(c net.Conn) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	hdr := make([]byte, 2)
	if _, err := io.ReadFull(c, hdr); err != nil || hdr[0] != 5 {
		return
	}
	if _, err := io.CopyN(io.Discard, c, int64(hdr[1])); err != nil {
		return
	}
	if _, err := c.Write([]byte{5, 0}); err != nil {
		return
	}
	req := make([]byte, 4)
	if _, err := io.ReadFull(c, req); err != nil || req[0] != 5 {
		return
	}
	host, err := readAddr(c, req[3])
	if err != nil {
		reply(c, 8, nil)
		return
	}
	pb := make([]byte, 2)
	if _, err := io.ReadFull(c, pb); err != nil {
		return
	}
	port := int(binary.BigEndian.Uint16(pb))
	switch req[1] {
	case 1:
		connect(c, host, port)
	case 3:
		udpAssociate(c)
	default:
		reply(c, 7, nil)
	}
}

func readAddr(c net.Conn, atyp byte) (string, error) {
	switch atyp {
	case 1:
		b := make([]byte, 4)
		if _, err := io.ReadFull(c, b); err != nil {
			return "", err
		}
		return net.IP(b).String(), nil
	case 4:
		b := make([]byte, 16)
		if _, err := io.ReadFull(c, b); err != nil {
			return "", err
		}
		return net.IP(b).String(), nil
	case 3:
		n := make([]byte, 1)
		if _, err := io.ReadFull(c, n); err != nil {
			return "", err
		}
		b := make([]byte, n[0])
		if _, err := io.ReadFull(c, b); err != nil {
			return "", err
		}
		return string(b), nil
	}
	return "", errors.New("bad address type")
}

func reply(c net.Conn, code byte, bound *net.UDPAddr) {
	r := []byte{5, code, 0, 1, 0, 0, 0, 0, 0, 0}
	if bound != nil {
		copy(r[4:8], bound.IP.To4())
		binary.BigEndian.PutUint16(r[8:10], uint16(bound.Port))
	}
	_, _ = c.Write(r)
}

func connect(c net.Conn, host string, port int) {
	target := net.JoinHostPort(host, fmt.Sprint(port))
	logf("CONNECT %s", target)
	if net.ParseIP(host) == nil {
		reply(c, 8, nil) // names are never sent by tun2socks; refuse rather than resolve through the tunnel
		return
	}
	d := net.Dialer{Timeout: 10 * time.Second, Control: pin}
	up, err := d.Dial("tcp", target)
	if err != nil {
		logf("CONNECT-FAILED %s: %v", target, err)
		reply(c, 5, nil)
		return
	}
	defer up.Close()
	reply(c, 0, nil)
	_ = c.SetDeadline(time.Time{})
	done := make(chan struct{}, 2)
	pipe := func(dst, src net.Conn) {
		defer func() { _ = recover() }()
		_, _ = io.Copy(dst, src)
		if tc, ok := dst.(*net.TCPConn); ok {
			_ = tc.CloseWrite()
		}
		done <- struct{}{}
	}
	go pipe(up, c)
	go pipe(c, up)
	<-done
	<-done
}

// udpAssociate relays UDP datagrams. Port 53 goes to the real resolver whatever the destination
// (tun2socks sends the tunnel's DNS queries for 198.18.0.2); everything else goes where it says.
func udpAssociate(c net.Conn) {
	_ = c.SetDeadline(time.Time{})
	pc, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		reply(c, 1, nil)
		return
	}
	defer pc.Close()
	up, err := (&net.ListenConfig{Control: pin}).ListenPacket(context.Background(), "udp4", "0.0.0.0:0")
	if err != nil {
		reply(c, 1, nil)
		return
	}
	defer up.Close()
	reply(c, 0, pc.LocalAddr().(*net.UDPAddr))

	var mu sync.Mutex
	var clientAddr net.Addr
	origin := map[string][]byte{} // upstream addr -> SOCKS address header of the original destination
	go func() {
		defer func() { _ = recover() }()
		buf := make([]byte, 65535)
		for {
			n, from, err := up.ReadFrom(buf)
			if err != nil {
				return
			}
			mu.Lock()
			h := origin[from.String()]
			ca := clientAddr
			mu.Unlock()
			if ca == nil || h == nil {
				continue
			}
			out := append(append([]byte{0, 0, 0}, h...), buf[:n]...)
			_, _ = pc.WriteTo(out, ca)
		}
	}()
	go func() { // the association lives as long as the control connection
		defer func() { _ = recover() }()
		_, _ = io.Copy(io.Discard, c)
		pc.Close()
	}()
	buf := make([]byte, 65535)
	for {
		n, from, err := pc.ReadFrom(buf)
		if err != nil {
			return
		}
		mu.Lock()
		clientAddr = from
		mu.Unlock()
		d := buf[:n]
		if len(d) < 10 || d[2] != 0 || d[3] != 1 { // IPv4 destinations only
			continue
		}
		dst := &net.UDPAddr{IP: net.IP(d[4:8]), Port: int(binary.BigEndian.Uint16(d[8:10]))}
		payload := d[10:]
		if dst.Port == 53 {
			if q := qname(payload); q != "" {
				logf("DNS %s", q)
			}
			ra, err := net.ResolveUDPAddr("udp4", *resolver)
			if err != nil {
				continue
			}
			mu.Lock()
			origin[ra.String()] = append([]byte{1}, d[4:10]...)
			mu.Unlock()
			_, _ = up.WriteTo(payload, ra)
			continue
		}
		mu.Lock()
		origin[dst.String()] = append([]byte{1}, d[4:10]...)
		mu.Unlock()
		_, _ = up.WriteTo(payload, dst)
	}
}

// qname extracts the first question name of a DNS query, for the log.
func qname(p []byte) string {
	if len(p) < 13 {
		return ""
	}
	var name []byte
	i := 12
	for i < len(p) && p[i] != 0 {
		l := int(p[i])
		if l > 63 || i+1+l > len(p) {
			return ""
		}
		if len(name) > 0 {
			name = append(name, '.')
		}
		name = append(name, p[i+1:i+1+l]...)
		i += 1 + l
	}
	return string(name)
}
