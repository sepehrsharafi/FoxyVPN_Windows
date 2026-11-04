package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxLine    = 64 * 1024
	maxClients = 16
)

// Server speaks newline-delimited JSON on the unix socket.
type Server struct {
	paths   Paths
	mgr     *Manager
	log     *Logger
	peerExe func(net.Conn) (string, error)
	slots   chan struct{}
}

func newServer(paths Paths, mgr *Manager, log *Logger, peerExe func(net.Conn) (string, error)) *Server {
	return &Server{paths: paths, mgr: mgr, log: log, peerExe: peerExe, slots: make(chan struct{}, maxClients)}
}

type client struct {
	conn    net.Conn
	wmu     sync.Mutex
	allowed bool
}

type request struct {
	ID        int      `json:"id"`
	Cmd       string   `json:"cmd"`
	SocksPort int      `json:"socksPort"`
	Bypass    []string `json:"bypass"`
}

// Serve accepts connections until the listener is closed.
func (s *Server) Serve(l net.Listener) {
	for {
		conn, err := l.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(100 * time.Millisecond)
			continue
		}
		select {
		case s.slots <- struct{}{}:
		default:
			_ = conn.Close() // too many clients: bounded memory
			continue
		}
		go func() {
			defer func() { <-s.slots }()
			s.handleConn(conn)
		}()
	}
}

func (s *Server) isAllowed(conn net.Conn) bool {
	cfg, err := loadConfig(s.paths)
	if err != nil {
		return false
	}
	exe, err := s.peerExe(conn)
	if err != nil {
		s.log.Printf("peer check failed: %v", err)
		return false
	}
	ok := peerAllowed(exe, cfg.AppPath, func(p string) string {
		r, err := filepath.EvalSymlinks(p)
		if err != nil {
			return ""
		}
		return r
	})
	if !ok {
		s.log.Printf("rejected a connection from %q", exe)
	}
	return ok
}

func (s *Server) handleConn(conn net.Conn) {
	c := &client{conn: conn}
	defer func() {
		if r := recover(); r != nil {
			s.log.Printf("connection handler panic: %v", r)
		}
		// A closed connection always ends its session (app crash or quit).
		func() {
			defer func() { _ = recover() }()
			s.mgr.Stop(c)
		}()
		_ = conn.Close()
	}()
	c.allowed = s.isAllowed(conn)
	r := bufio.NewReaderSize(conn, 4096)
	for {
		line, err := readLine(r, maxLine)
		if err != nil {
			if errors.Is(err, errLineTooLong) {
				c.reply(map[string]any{"id": 0, "ok": false, "error": "Request too large."})
			}
			return
		}
		if len(strings.TrimSpace(string(line))) == 0 {
			continue
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			c.reply(map[string]any{"id": 0, "ok": false, "error": "Malformed request."})
			continue
		}
		c.reply(s.dispatch(c, &req))
	}
}

var errLineTooLong = errors.New("line too long")

func readLine(r *bufio.Reader, max int) ([]byte, error) {
	var buf []byte
	for {
		frag, isPrefix, err := r.ReadLine()
		if err != nil {
			return nil, err
		}
		if len(buf)+len(frag) > max {
			return nil, errLineTooLong
		}
		buf = append(buf, frag...)
		if !isPrefix {
			return buf, nil
		}
	}
}

func fail(id int, msg string) map[string]any {
	return map[string]any{"id": id, "ok": false, "error": msg}
}

func okReply(id int) map[string]any { return map[string]any{"id": id, "ok": true} }

func infoReply(id int, in *StartInfo) map[string]any {
	m := okReply(id)
	m["interface"] = in.Interface
	m["physicalAddress"] = nilIfEmpty(in.Physical)
	m["gateway"] = nilIfEmpty(in.Gateway)
	return m
}

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func (s *Server) dispatch(c *client, req *request) (res map[string]any) {
	defer func() {
		if r := recover(); r != nil {
			s.log.Printf("command %q panic: %v", req.Cmd, r)
			res = fail(req.ID, "Something went wrong inside FoxyVPN's network helper.")
		}
	}()
	if req.Cmd == "hello" {
		cfg, _ := loadConfig(s.paths)
		m := okReply(req.ID)
		m["version"] = HelperVersion
		m["appPath"] = cfg.AppPath
		return m
	}
	if !c.allowed {
		return fail(req.ID, "Not allowed.")
	}
	switch req.Cmd {
	case "start":
		if !validPort(req.SocksPort) {
			return fail(req.ID, "Invalid proxy port.")
		}
		bypass, err := validateBypass(req.Bypass)
		if err != nil {
			return fail(req.ID, "Invalid bypass list: "+err.Error()+".")
		}
		in, err := s.mgr.Start(c, req.SocksPort, bypass, func(reason string) {
			c.reply(map[string]any{"event": "exited", "reason": reason})
		})
		if err != nil {
			return fail(req.ID, err.Error())
		}
		return infoReply(req.ID, in)
	case "refreshBypass":
		in, err := s.mgr.Refresh(c)
		if err != nil {
			return fail(req.ID, err.Error())
		}
		return infoReply(req.ID, in)
	case "stop":
		s.mgr.Stop(c)
		return okReply(req.ID)
	case "cleanup":
		if err := s.mgr.Cleanup(c); err != nil {
			return fail(req.ID, err.Error())
		}
		return okReply(req.ID)
	}
	return fail(req.ID, "Unknown command.")
}

// reply writes one JSON line; safe to call from any goroutine.
func (c *client) reply(v map[string]any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_, _ = c.conn.Write(append(b, '\n'))
}

// peerExeViaPS finds the peer's executable path (ps prints the full path for comm on macOS).
func peerExeViaPS(conn net.Conn) (string, error) {
	pid, err := peerPID(conn)
	if err != nil {
		return "", err
	}
	if pid <= 0 {
		return "", errors.New("no peer pid")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := runCmd(ctx, "/bin/ps", "-o", "comm=", "-p", strconv.Itoa(pid))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}
