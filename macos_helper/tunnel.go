package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// tun2socks v2.7.0 on macOS (checked against the v2.7.0 source):
//   - engine/parse.go parseDevice(): a --device value without "://" gets "tun://" prepended, so
//     `--device utun100` and `--device tun://utun100` are the same thing. parseTUN (parse_unix.go)
//     passes the host part to tun.Open(name, mtu).
//   - core/device/tun/tun_wireguard.go (!linux) + tun_wireguard_unix.go call wireguard-go's
//     tun.CreateTUN(name, mtu). On darwin that accepts only "utun" (kernel picks the number) or
//     "utun<N>" (fmt.Sscanf "utun%d", error "Interface name must be utun[0-9]*" otherwise), so the
//     name has to be utunN. N maps to the kernel unit N+1.
//   - Nothing in tun2socks assigns addresses or routes: it only creates the utun, sets the MTU and
//     reads/writes packets. Address, netmask and routes are the helper's job (ifconfig / route).
//   - Flags used: --device, --mtu, --proxy socks5://host:port, --loglevel (stdlib flag package, so
//     one or two dashes both work).

const (
	utunLo        = 100
	utunHi        = 199
	startBudget   = 20 * time.Second
	ifaceWait     = 5 * time.Second
	errNoInternet = "No internet connection."
)

var (
	privateRanges = []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"}
	errAnotherWin = errors.New("Another FoxyVPN window is already connected.")
	errRestarting = errors.New("FoxyVPN's network helper is restarting. Try again.")
)

// platform is everything the manager needs from the operating system (faked in tests).
type platform struct {
	run       runner
	ifaces    func() ([]string, error)
	ifaceAddr func(name string) string // first IPv4 of an interface, "" if none
	start     func(path string, args []string) (child, error)
	killStale func(pid int)
	exists    func(path string) bool
}

func realPlatform() platform {
	return platform{
		run: runCmd,
		ifaces: func() ([]string, error) {
			l, err := net.Interfaces()
			if err != nil {
				return nil, err
			}
			names := make([]string, 0, len(l))
			for _, i := range l {
				names = append(names, i.Name)
			}
			return names, nil
		},
		ifaceAddr: func(name string) string {
			ifc, err := net.InterfaceByName(name)
			if err != nil {
				return ""
			}
			addrs, err := ifc.Addrs()
			if err != nil {
				return ""
			}
			for _, a := range addrs {
				if ipn, ok := a.(*net.IPNet); ok {
					if v4 := ipn.IP.To4(); v4 != nil {
						return v4.String()
					}
				}
			}
			return ""
		},
		start:     startProc,
		killStale: killPid,
		exists: func(p string) bool {
			_, err := os.Stat(p)
			return err == nil
		},
	}
}

// StartInfo is the reply to start / refreshBypass.
type StartInfo struct {
	Interface string
	Physical  string
	Gateway   string
}

type session struct {
	owner    any
	st       State
	ch       child
	onExit   func(string)
	quit     chan struct{}
	quitOnce sync.Once
	iface    string // physical interface name
	gateway  string
	physical string
	bypass   []string
}

func (s *session) stopWatch() { s.quitOnce.Do(func() { close(s.quit) }) }

// Manager owns the single live tunnel session. All state changes happen under mu.
type Manager struct {
	mu    sync.Mutex
	paths Paths
	pf    platform
	log   *Logger
	cur   *session
	// stopping is set once the helper is on its way out: no new tunnel may start.
	stopping bool
}

func newManager(paths Paths, pf platform, log *Logger) *Manager {
	return &Manager{paths: paths, pf: pf, log: log}
}

func (m *Manager) save(s *session) {
	if err := writeState(m.paths.State, &s.st); err != nil {
		m.log.Printf("could not write state.json: %v", err)
	}
}

func (m *Manager) ifaceNames() []string {
	n, err := m.pf.ifaces()
	if err != nil {
		return nil
	}
	return n
}

func hasName(list []string, n string) bool {
	for _, x := range list {
		if x == n {
			return true
		}
	}
	return false
}

// defaultRoute reads the physical default route (not affected by our 0/1 + 128/1 routes).
func (m *Manager) defaultRoute(ctx context.Context) (routeInfo, error) {
	out, _ := m.pf.run(ctx, "/sbin/route", "-n", "get", "default")
	ri, err := parseRouteGet(out)
	if err != nil {
		return ri, errors.New(errNoInternet)
	}
	return ri, nil
}

// Start brings the tunnel up. The caller (server) passes already validated input.
func (m *Manager) Start(owner any, port int, bypass []string, onExit func(string)) (*StartInfo, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stopping {
		return nil, errRestarting
	}
	if m.cur != nil {
		if m.cur.owner != owner {
			return nil, errAnotherWin
		}
		m.teardownLocked()
	}
	// Anything left behind by a crashed run goes first.
	m.restoreStaleLocked()

	ctx, cancel := context.WithTimeout(context.Background(), startBudget)
	defer cancel()

	s := &session{owner: owner, onExit: onExit, quit: make(chan struct{}), bypass: bypass}
	if err := m.setup(ctx, s, port); err != nil {
		m.log.Printf("start failed: %v", err)
		m.teardownSession(s)
		return nil, err
	}
	m.cur = s
	go m.watch(s)
	m.log.Printf("tunnel up on %s (gateway %q, physical interface %s)", s.st.Interface, s.gateway, s.iface)
	return s.info(), nil
}

func (s *session) info() *StartInfo {
	return &StartInfo{Interface: s.st.Interface, Physical: s.physical, Gateway: s.gateway}
}

func (m *Manager) setup(ctx context.Context, s *session, port int) error {
	// 1. Default route, read before anything changes.
	ri, err := m.defaultRoute(ctx)
	if err != nil {
		return err
	}
	s.iface, s.gateway = ri.Interface, ri.Gateway
	s.physical = m.pf.ifaceAddr(ri.Interface)

	if !m.pf.exists(m.paths.Tun2socks) {
		return errors.New("FoxyVPN's network helper is damaged (its network engine is missing). Please reinstall FoxyVPN.")
	}

	// 3. Free utun name.
	name, err := pickUtun(m.ifaceNames(), utunLo, utunHi)
	if err != nil {
		return err
	}
	s.st = State{Interface: name, Tun2socks: m.paths.Tun2socks, StartedAt: time.Now().UTC().Format(time.RFC3339)}
	m.save(s) // 2. state first, so a crash from here on can be undone

	// 4. tun2socks.
	args := []string{"--device", name, "--mtu", "1500",
		"--proxy", "socks5://127.0.0.1:" + strconv.Itoa(port), "--loglevel", "warn"}
	ch, err := m.pf.start(m.paths.Tun2socks, args)
	if err != nil {
		return fmt.Errorf("The VPN engine could not be started: %v", err)
	}
	s.ch = ch
	s.st.Pid = ch.Pid()
	m.save(s)
	if err := m.waitIface(ctx, s, name); err != nil {
		return err
	}

	// 5. Addresses.
	if out, err := m.pf.run(ctx, "/sbin/ifconfig", name, "inet", "198.18.0.1", "198.18.0.1",
		"netmask", "255.254.0.0", "mtu", "1500", "up"); err != nil {
		return fmt.Errorf("The VPN network interface could not be configured: %s", lastLine(out, err))
	}
	if _, err := m.pf.run(ctx, "/sbin/ifconfig", name, "inet6", "fd66:6f78:7976::1", "prefixlen", "64"); err != nil {
		m.log.Printf("ifconfig inet6 failed (ignored): %v", err)
	}

	// 6. Routes.
	if err := m.addRoute(ctx, s, "inet", "198.18.0.0/15", "tunnel", viaTun(name), true); err != nil {
		return err
	}
	if err := m.addPhysicalRoutes(ctx, s); err != nil {
		return err
	}
	for _, d := range []string{"0.0.0.0/1", "128.0.0.0/1"} {
		if err := m.addRoute(ctx, s, "inet", d, "default", viaTun(name), true); err != nil {
			return err
		}
	}
	if err := m.addV6Routes(ctx, s); err != nil {
		return err
	}

	// 7. DNS.
	return m.setDNS(ctx, s)
}

func viaTun(name string) []string { return []string{"-interface", name} }

func (s *session) via() []string {
	if s.gateway != "" {
		return []string{s.gateway}
	}
	return []string{"-interface", s.iface}
}

// addPhysicalRoutes adds bypass hosts and private ranges via the physical network. Failures are
// only logged: a missing bypass must not stop the VPN from starting.
func (m *Manager) addPhysicalRoutes(ctx context.Context, s *session) error {
	for _, ip := range s.bypass {
		if err := m.addRoute(ctx, s, "inet", ip+"/32", "bypass", s.via(), false); err != nil {
			m.log.Printf("bypass route %s failed: %v", ip, err)
		}
	}
	if s.gateway != "" {
		for _, p := range privateRanges {
			if err := m.addRoute(ctx, s, "inet", p, "private", s.via(), false); err != nil {
				m.log.Printf("private route %s failed: %v", p, err)
			}
		}
	}
	return nil
}

// addRoute records the route, adds it, and drops the record again if it was not ours. When
// required is false a failure is logged by the caller and not fatal; "File exists" never is.
func (m *Manager) addRoute(ctx context.Context, s *session, family, dest, kind string, via []string, required bool) error {
	rec := RouteRec{Family: family, Dest: dest, Kind: kind}
	s.st.Routes = append(s.st.Routes, rec)
	m.save(s)
	args := append([]string{"-n", "add", "-" + family, dest}, via...)
	out, err := m.pf.run(ctx, "/sbin/route", args...)
	if err == nil {
		return nil
	}
	s.st.Routes = s.st.Routes[:len(s.st.Routes)-1]
	m.save(s)
	if !required && strings.Contains(out, "File exists") {
		return nil
	}
	if required && strings.Contains(out, "File exists") && dest == "198.18.0.0/15" {
		return nil // the kernel already made it from the interface netmask
	}
	return fmt.Errorf("A network route could not be added (%s %s): %s", family, dest, lastLine(out, err))
}

func (m *Manager) addV6Routes(ctx context.Context, s *session) error {
	var failed error
	for _, d := range []string{"::/1", "8000::/1"} {
		if err := m.addRoute(ctx, s, "inet6", d, "default", viaTun(s.st.Interface), true); err != nil {
			failed = err
		}
	}
	if failed == nil {
		return nil
	}
	m.log.Printf("IPv6 routes failed: %v", failed)
	out, err := m.pf.run(ctx, "/sbin/route", "-n", "get", "-inet6", "default")
	if err == nil {
		if ri, perr := parseRouteGet(out); perr == nil && !strings.HasPrefix(ri.Interface, "utun") {
			return errors.New("IPv6 could not be routed through the VPN.")
		}
	}
	return nil // no IPv6 on this Mac: nothing can leak
}

func (m *Manager) waitIface(ctx context.Context, s *session, name string) error {
	deadline := time.Now().Add(ifaceWait)
	for {
		if hasName(m.ifaceNames(), name) {
			return nil
		}
		select {
		case <-s.ch.Done():
			return fmt.Errorf("The VPN engine stopped right after starting. %s", tailMsg(s.ch))
		case <-ctx.Done():
			return errors.New("Connecting took too long.")
		case <-time.After(50 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("The VPN network interface did not appear. %s", tailMsg(s.ch))
		}
	}
}

func tailMsg(c child) string {
	t := c.Tail()
	if len(t) == 0 {
		return ""
	}
	return "Last message: " + t[len(t)-1]
}

func lastLine(out string, err error) string {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if l := strings.TrimSpace(lines[len(lines)-1]); l != "" {
		return l
	}
	return err.Error()
}

// Refresh re-detects the default route and repairs bypass/private routes if the network changed.
func (m *Manager) Refresh(owner any) (*StartInfo, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stopping {
		return nil, errRestarting
	}
	s := m.cur
	if s == nil || s.owner != owner {
		return nil, errors.New("Not connected.")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	ri, err := m.defaultRoute(ctx)
	if err != nil {
		return nil, err
	}
	if ri.Interface != s.iface || ri.Gateway != s.gateway {
		m.log.Printf("default route changed: %s/%s -> %s/%s", s.iface, s.gateway, ri.Interface, ri.Gateway)
		m.deleteRoutes(ctx, s, func(r RouteRec) bool { return r.Kind == "bypass" || r.Kind == "private" })
		s.iface, s.gateway = ri.Interface, ri.Gateway
	}
	s.physical = m.pf.ifaceAddr(s.iface)
	// Re-add whatever is missing (existing routes answer "File exists").
	have := map[string]bool{}
	for _, r := range s.st.Routes {
		have[r.Dest] = true
	}
	for _, ip := range s.bypass {
		if !have[ip+"/32"] {
			_ = m.addRoute(ctx, s, "inet", ip+"/32", "bypass", s.via(), false)
		}
	}
	if s.gateway != "" {
		for _, p := range privateRanges {
			if !have[p] {
				_ = m.addRoute(ctx, s, "inet", p, "private", s.via(), false)
			}
		}
	}
	// A network adapter plugged in during the session gets the tunnel's DNS too.
	if svcs, err := m.services(ctx); err == nil {
		known := map[string]bool{}
		for _, d := range s.st.DNS {
			known[d.Service] = true
		}
		added := false
		for _, svc := range svcs {
			if known[svc] {
				continue
			}
			if err := m.applyDNS(ctx, s, svc); err != nil {
				m.log.Printf("%v", err)
			}
			added = true
		}
		if added {
			m.flushDNS(ctx)
		}
	}
	m.save(s)
	return s.info(), nil
}

func (m *Manager) deleteRoutes(ctx context.Context, s *session, match func(RouteRec) bool) {
	var keep []RouteRec
	for _, r := range s.st.Routes {
		if match(r) {
			_, _ = m.pf.run(ctx, "/sbin/route", "-n", "delete", "-"+r.Family, r.Dest)
		} else {
			keep = append(keep, r)
		}
	}
	s.st.Routes = keep
}

// Stop tears down this owner's session (idempotent).
func (m *Manager) Stop(owner any) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cur != nil && m.cur.owner == owner {
		m.teardownLocked()
	}
}

// Cleanup restores leftovers from a crashed run. It refuses while another client is connected.
func (m *Manager) Cleanup(owner any) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cur != nil {
		if m.cur.owner != owner {
			return errAnotherWin
		}
		m.teardownLocked()
	}
	m.restoreStaleLocked()
	return nil
}

// StopAll is for shutdown (SIGTERM) and --restore: undo everything regardless of owner.
func (m *Manager) StopAll() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.teardownLocked()
	m.restoreStaleLocked()
}

// Shutdown is StopAll for a helper that is about to exit: it also refuses any later start.
func (m *Manager) Shutdown() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stopping = true
	m.teardownLocked()
	m.restoreStaleLocked()
}

func (m *Manager) teardownLocked() {
	s := m.cur
	if s == nil {
		return
	}
	m.cur = nil
	m.teardownSession(s)
}

func (m *Manager) teardownSession(s *session) {
	s.stopWatch()
	m.restore(s.st, s.ch)
	m.log.Printf("tunnel down (%s)", s.st.Interface)
}

// restoreStaleLocked undoes whatever state.json describes (nothing live must be running).
func (m *Manager) restoreStaleLocked() {
	st, err := readState(m.paths.State)
	if err != nil {
		m.log.Printf("state.json unreadable, removing it: %v", err)
		_ = os.Remove(m.paths.State)
	}
	if st != nil {
		m.log.Printf("restoring leftovers from an earlier run (%s)", st.Interface)
		m.restore(*st, nil)
	}
	m.sweepDNS()
}

// restore undoes DNS, routes and the tun2socks process, then deletes state.json.
func (m *Manager) restore(st State, ch child) {
	ctx := context.Background()
	dnsFailed := false
	for _, d := range st.DNS {
		if !m.restoreDNS(ctx, d) {
			dnsFailed = true
		}
	}
	if len(st.DNS) > 0 {
		m.flushDNS(ctx)
	}
	for i := len(st.Routes) - 1; i >= 0; i-- {
		r := st.Routes[i]
		_, _ = m.pf.run(ctx, "/sbin/route", "-n", "delete", "-"+r.Family, r.Dest)
	}
	if ch != nil {
		ch.Terminate()
	} else if st.Pid > 1 && st.Tun2socks != "" {
		out, _ := m.pf.run(ctx, "/bin/ps", "-o", "comm=", "-p", strconv.Itoa(st.Pid))
		if strings.TrimSpace(out) == st.Tun2socks {
			m.pf.killStale(st.Pid)
		}
	}
	_ = os.Remove(m.paths.State)
	if dnsFailed {
		m.sweepDNS() // whatever is still at the tunnel's resolver goes back to automatic
	}
}

// watch ends the session when tun2socks dies or the interface disappears.
func (m *Manager) watch(s *session) {
	defer func() {
		if r := recover(); r != nil {
			m.log.Printf("watch panic: %v", r)
		}
	}()
	t := time.NewTicker(2 * time.Second)
	defer t.Stop()
	var reason string
loop:
	for {
		select {
		case <-s.quit:
			return
		case <-s.ch.Done():
			reason = "The VPN engine stopped unexpectedly. " + tailMsg(s.ch)
			break loop
		case <-t.C:
			if names, err := m.pf.ifaces(); err == nil && !hasName(names, s.st.Interface) {
				reason = "The VPN network interface disappeared."
				break loop
			}
		}
	}
	m.mu.Lock()
	if m.cur != s {
		m.mu.Unlock()
		return
	}
	m.log.Printf("tunnel ended on its own: %s", reason)
	m.teardownLocked()
	cb := s.onExit
	m.mu.Unlock()
	if cb != nil {
		cb(strings.TrimSpace(reason))
	}
}
