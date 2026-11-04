package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

const cmdTimeout = 10 * time.Second

// runner runs a system tool and returns its combined output. Every call has a timeout.
type runner func(ctx context.Context, name string, args ...string) (string, error)

type capBuffer struct {
	mu  sync.Mutex
	buf []byte
}

func (b *capBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if room := 16*1024 - len(b.buf); room > 0 {
		if len(p) < room {
			room = len(p)
		}
		b.buf = append(b.buf, p[:room]...)
	}
	return len(p), nil
}

func (b *capBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.buf)
}

func cleanEnv() []string {
	return []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "LANG=C"}
}

func runCmd(ctx context.Context, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, cmdTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = cleanEnv()
	var out capBuffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	cmd.WaitDelay = 2 * time.Second
	err := cmd.Run()
	if err != nil {
		if ctx.Err() != nil {
			err = fmt.Errorf("timed out")
		}
		return out.String(), fmt.Errorf("%s: %w", name, err)
	}
	return out.String(), nil
}

// lineRing keeps the last 50 output lines of a child, each capped in length.
type lineRing struct {
	mu    sync.Mutex
	lines []string
	part  []byte
}

func (r *lineRing) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, c := range p {
		if c == '\n' {
			r.push()
			continue
		}
		if len(r.part) < 1024 {
			r.part = append(r.part, c)
		}
	}
	return len(p), nil
}

func (r *lineRing) push() {
	s := strings.TrimSpace(string(r.part))
	r.part = r.part[:0]
	if s == "" {
		return
	}
	r.lines = append(r.lines, s)
	if len(r.lines) > 50 {
		r.lines = append(r.lines[:0], r.lines[len(r.lines)-50:]...)
	}
}

func (r *lineRing) Tail() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	res := append([]string(nil), r.lines...)
	if s := strings.TrimSpace(string(r.part)); s != "" {
		res = append(res, s)
	}
	return res
}

// child is a running tun2socks process.
type child interface {
	Pid() int
	Done() <-chan struct{}
	Terminate()
	Tail() []string
}

type procChild struct {
	cmd  *exec.Cmd
	done chan struct{}
	ring *lineRing
}

func startProc(path string, args []string) (child, error) {
	ring := &lineRing{}
	cmd := exec.Command(path, args...)
	cmd.Env = cleanEnv()
	cmd.Stdout = ring
	cmd.Stderr = ring
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	c := &procChild{cmd: cmd, done: make(chan struct{}), ring: ring}
	go func() {
		defer func() { _ = recover() }()
		defer close(c.done)
		_ = cmd.Wait()
	}()
	return c, nil
}

func (c *procChild) Pid() int              { return c.cmd.Process.Pid }
func (c *procChild) Done() <-chan struct{} { return c.done }
func (c *procChild) Tail() []string        { return c.ring.Tail() }

// Terminate asks politely, then kills after 2 seconds.
func (c *procChild) Terminate() {
	select {
	case <-c.done:
		return
	default:
	}
	_ = c.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-c.done:
		return
	case <-time.After(2 * time.Second):
	}
	_ = c.cmd.Process.Kill()
	select {
	case <-c.done:
	case <-time.After(2 * time.Second):
	}
}

// killPid stops a leftover process by pid (used for stale state only).
func killPid(pid int) {
	p, err := os.FindProcess(pid)
	if err != nil {
		return
	}
	_ = p.Signal(syscall.SIGTERM)
	for i := 0; i < 20; i++ {
		time.Sleep(100 * time.Millisecond)
		if p.Signal(syscall.Signal(0)) != nil {
			return
		}
	}
	_ = p.Kill()
}
