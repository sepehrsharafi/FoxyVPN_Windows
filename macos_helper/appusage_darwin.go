//go:build darwin

package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

const (
	nstatControlName = "com.apple.network.statistics"
	sysprotoControl  = 2 // SYSPROTO_CONTROL (sys/sys_domain.h)
)

// ntstatMonitor holds one connection to the kernel's network statistics control.
type ntstatMonitor struct {
	fd      int
	tracker *usageTracker
	log     *Logger

	nextCtx atomic.Uint64
	wmu     sync.Mutex // one write at a time
	mu      sync.Mutex
	waiters map[uint64]chan uint32 // context -> errno (0 = success)
	closed  atomic.Bool
	done    chan struct{}
	once    sync.Once
}

// startAppUsage starts counting per-app bytes on the interface called iface (the utun).
func startAppUsage(iface string, log *Logger) (usageMonitor, error) {
	ifc, err := net.InterfaceByName(iface)
	if err != nil {
		return nil, fmt.Errorf("interface %s: %w", iface, err)
	}
	fd, err := unix.Socket(unix.AF_SYSTEM, unix.SOCK_DGRAM, sysprotoControl)
	if err != nil {
		return nil, fmt.Errorf("socket: %w", err)
	}
	info := &unix.CtlInfo{}
	copy(info.Name[:], nstatControlName)
	if err := unix.IoctlCtlInfo(fd, info); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("CTLIOCGINFO: %w", err)
	}
	if err := unix.Connect(fd, &unix.SockaddrCtl{ID: info.Id, Unit: 0}); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("connect: %w", err)
	}
	// Reads wake up regularly so Close never waits on a blocked read.
	_ = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &unix.Timeval{Sec: 0, Usec: 300000})
	_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_RCVBUF, 1<<20)

	res := newAppResolver(exePath)
	m := &ntstatMonitor{
		fd:      fd,
		tracker: newUsageTracker(uint32(ifc.Index), res.resolve),
		log:     log,
		waiters: map[uint64]chan uint32{},
		done:    make(chan struct{}),
	}
	go m.readLoop()

	subscribed := 0
	for _, p := range usageProviders {
		errno, err := m.request(addAllRequest(m.nextCtx.Add(1), p))
		switch {
		case err != nil:
			m.Close()
			return nil, err
		case errno != 0:
			log.Printf("app usage: provider %d not available (errno %d)", p, errno)
		default:
			subscribed++
		}
	}
	if subscribed == 0 {
		m.Close()
		return nil, errors.New("no network statistics provider accepted the subscription")
	}
	log.Printf("app usage: counting on %s (index %d), %d providers", iface, ifc.Index, subscribed)
	return m, nil
}

// request sends one message and waits for its SUCCESS / ERROR (matched by context).
func (m *ntstatMonitor) request(msg []byte) (uint32, error) {
	ctx := binary.LittleEndian.Uint64(msg[0:8])
	ch := make(chan uint32, 1)
	m.mu.Lock()
	m.waiters[ctx] = ch
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		delete(m.waiters, ctx)
		m.mu.Unlock()
	}()
	m.wmu.Lock()
	_, err := unix.Write(m.fd, msg)
	m.wmu.Unlock()
	if err != nil {
		return 0, fmt.Errorf("write: %w", err)
	}
	select {
	case errno := <-ch:
		return errno, nil
	case <-m.done:
		return 0, errors.New("closed")
	case <-time.After(3 * time.Second):
		return 0, errors.New("no answer from the kernel")
	}
}

func (m *ntstatMonitor) readLoop() {
	defer m.once.Do(func() { close(m.done) })
	buf := make([]byte, 64*1024)
	for !m.closed.Load() {
		n, err := unix.Read(m.fd, buf)
		if err != nil {
			if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EINTR) || errors.Is(err, unix.ENOBUFS) {
				continue
			}
			if !m.closed.Load() {
				m.log.Printf("app usage: read failed, stopping: %v", err)
			}
			return
		}
		if n == 0 {
			return
		}
		splitNstat(buf[:n], m.handle)
	}
}

func (m *ntstatMonitor) handle(msg nstatMessage) {
	switch msg.kind {
	case nstatMsgSuccess, nstatMsgError:
		m.mu.Lock()
		ch := m.waiters[msg.context]
		m.mu.Unlock()
		if ch != nil {
			select {
			case ch <- msg.errno:
			default:
			}
		}
	default:
		m.tracker.handle(msg)
	}
}

func (m *ntstatMonitor) Take() ([]AppTotal, error) {
	if m.closed.Load() {
		return nil, errors.New("closed")
	}
	select {
	case <-m.done:
		return m.tracker.take(), errors.New("stopped")
	default:
	}
	// Fresh counters for every live socket; closed ones were reported as they closed.
	if errno, err := m.request(getUpdateRequest(m.nextCtx.Add(1))); err != nil || errno != 0 {
		m.log.Printf("app usage: poll failed (errno %d): %v", errno, err)
	}
	return m.tracker.take(), nil
}

func (m *ntstatMonitor) Close() {
	if m.closed.Swap(true) {
		return
	}
	select {
	case <-m.done:
	case <-time.After(time.Second):
	}
	unix.Close(m.fd)
}

// exePath is the executable of a running process, from kern.procargs2 (what ps uses): an int32
// argc, then the executable path, NUL-terminated. "" when the process is gone.
func exePath(pid uint32) string {
	b, err := unix.SysctlRaw("kern.procargs2", int(pid))
	if err != nil || len(b) < 5 {
		return ""
	}
	b = b[4:]
	if i := bytes.IndexByte(b, 0); i >= 0 {
		b = b[:i]
	}
	if len(b) == 0 || b[0] != '/' {
		return ""
	}
	return string(b)
}
