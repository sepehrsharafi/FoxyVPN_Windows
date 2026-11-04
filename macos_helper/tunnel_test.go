package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeChild struct {
	done chan struct{}
	once sync.Once
	pf   *fakePlatform
}

func (c *fakeChild) Pid() int              { return 4242 }
func (c *fakeChild) Done() <-chan struct{} { return c.done }
func (c *fakeChild) Tail() []string        { return []string{"fake tun2socks last line"} }
func (c *fakeChild) Terminate() {
	c.once.Do(func() { close(c.done) })
	c.pf.removeIface("utun100")
}

type fakePlatform struct {
	mu        sync.Mutex
	calls     []string
	ifaces    []string
	dns       map[string][]string // current DNS per service
	services  string
	failRoute string // substring of a route add that fails
	noDefault bool
	v6Default bool
	childDead bool
	child     *fakeChild
	stale     []int
}

func newFake() *fakePlatform {
	return &fakePlatform{
		ifaces:   []string{"lo0", "en0"},
		dns:      map[string][]string{"Wi-Fi": nil, "USB LAN": {"1.1.1.1", "8.8.8.8"}},
		services: "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Bluetooth PAN\nUSB LAN\n",
	}
}

func (f *fakePlatform) removeIface(n string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, i := range f.ifaces {
		if i != n {
			out = append(out, i)
		}
	}
	f.ifaces = out
}

func (f *fakePlatform) callsString() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return strings.Join(f.calls, "\n")
}

func (f *fakePlatform) run(ctx context.Context, name string, args ...string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	line := name + " " + strings.Join(args, " ")
	f.calls = append(f.calls, line)
	switch {
	case strings.HasSuffix(name, "route") && len(args) >= 3 && args[1] == "get" && args[2] == "default":
		if f.noDefault {
			return "route: writing to routing socket: not in table\n", errors.New("exit 1")
		}
		return routeWithGateway, nil
	case strings.HasSuffix(name, "route") && len(args) >= 4 && args[1] == "get" && args[2] == "-inet6":
		if f.v6Default {
			return routeV6, nil
		}
		return "route: writing to routing socket: not in table\n", errors.New("exit 1")
	case strings.HasSuffix(name, "route") && len(args) > 1 && args[1] == "add":
		if f.failRoute != "" && strings.Contains(line, f.failRoute) {
			if strings.Contains(f.failRoute, "EXISTS") {
				return "add net: gateway x: File exists\n", errors.New("exit 1")
			}
			return "route: writing to routing socket: Network is unreachable\n", errors.New("exit 1")
		}
		return "add net\n", nil
	case strings.HasSuffix(name, "networksetup"):
		switch args[0] {
		case "-listallnetworkservices":
			return f.services, nil
		case "-getdnsservers":
			s := f.dns[args[1]]
			if len(s) == 0 {
				return "There aren't any DNS Servers set on " + args[1] + ".\n", nil
			}
			return strings.Join(s, "\n") + "\n", nil
		case "-setdnsservers":
			if args[2] == "empty" {
				f.dns[args[1]] = nil
			} else {
				f.dns[args[1]] = append([]string(nil), args[2:]...)
			}
			return "", nil
		}
	case strings.HasSuffix(name, "ps"):
		return "/Library/Application Support/FoxyVPN/tun2socks\n", nil
	}
	return "", nil
}

func (f *fakePlatform) platform() platform {
	return platform{
		run: f.run,
		ifaces: func() ([]string, error) {
			f.mu.Lock()
			defer f.mu.Unlock()
			return append([]string(nil), f.ifaces...), nil
		},
		ifaceAddr: func(n string) string {
			if n == "en0" {
				return "192.168.1.50"
			}
			return ""
		},
		start: func(path string, args []string) (child, error) {
			f.mu.Lock()
			defer f.mu.Unlock()
			f.calls = append(f.calls, "START "+path+" "+strings.Join(args, " "))
			c := &fakeChild{done: make(chan struct{}), pf: f}
			f.child = c
			if !f.childDead {
				f.ifaces = append(f.ifaces, args[1])
			} else {
				c.once.Do(func() { close(c.done) })
			}
			return c, nil
		},
		killStale: func(pid int) {
			f.mu.Lock()
			f.stale = append(f.stale, pid)
			f.mu.Unlock()
		},
		exists: func(string) bool { return true },
	}
}

func newTestManager(t *testing.T, f *fakePlatform) (*Manager, Paths) {
	dir := t.TempDir()
	p := Paths{Dir: dir, State: filepath.Join(dir, "state.json"), Config: filepath.Join(dir, "helper.json"),
		Tun2socks: "/Library/Application Support/FoxyVPN/tun2socks"}
	return newManager(p, f.platform(), nil), p
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

func TestStartStopHappyPath(t *testing.T) {
	f := newFake()
	m, p := newTestManager(t, f)
	owner := &client{}
	info, err := m.Start(owner, 51234, []string{"203.0.113.9"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if info.Interface != "utun100" || info.Physical != "192.168.1.50" || info.Gateway != "192.168.1.1" {
		t.Errorf("info: %+v", info)
	}
	calls := f.callsString()
	for _, want := range []string{
		"START /Library/Application Support/FoxyVPN/tun2socks --device utun100 --mtu 1500 --proxy socks5://127.0.0.1:51234 --loglevel warn",
		"/sbin/ifconfig utun100 inet 198.18.0.1 198.18.0.1 netmask 255.254.0.0 mtu 1500 up",
		"/sbin/route -n add -inet 198.18.0.0/15 -interface utun100",
		"/sbin/route -n add -inet 203.0.113.9/32 192.168.1.1",
		"/sbin/route -n add -inet 10.0.0.0/8 192.168.1.1",
		"/sbin/route -n add -inet 100.64.0.0/10 192.168.1.1",
		"/sbin/route -n add -inet 0.0.0.0/1 -interface utun100",
		"/sbin/route -n add -inet 128.0.0.0/1 -interface utun100",
		"/sbin/route -n add -inet6 ::/1 -interface utun100",
		"/sbin/route -n add -inet6 8000::/1 -interface utun100",
		"networksetup -setdnsservers Wi-Fi 198.18.0.2",
		"networksetup -setdnsservers USB LAN 198.18.0.2",
		"/usr/bin/dscacheutil -flushcache",
	} {
		if !strings.Contains(calls, want) {
			t.Errorf("missing call %q in:\n%s", want, calls)
		}
	}
	if strings.Contains(calls, "Bluetooth") {
		t.Error("disabled service must be skipped")
	}
	st, _ := readState(p.State)
	if st == nil || st.Interface != "utun100" || st.Pid != 4242 || len(st.Routes) != 10 || len(st.DNS) != 2 {
		t.Errorf("state: %+v", st)
	}
	// Second client is refused.
	if _, err := m.Start(&client{}, 51235, nil, nil); err == nil || !strings.Contains(err.Error(), "Another FoxyVPN window") {
		t.Errorf("second client: %v", err)
	}
	m.Stop(owner)
	if fileExists(p.State) {
		t.Error("state.json must be removed after stop")
	}
	if len(f.dns["Wi-Fi"]) != 0 || strings.Join(f.dns["USB LAN"], ",") != "1.1.1.1,8.8.8.8" {
		t.Errorf("DNS not restored: %v", f.dns)
	}
	calls = f.callsString()
	if !strings.Contains(calls, "/sbin/route -n delete -inet 0.0.0.0/1") || !strings.Contains(calls, "-setdnsservers Wi-Fi empty") {
		t.Errorf("teardown calls missing:\n%s", calls)
	}
	select {
	case <-f.child.done:
	default:
		t.Error("tun2socks not terminated")
	}
	m.Stop(owner) // idempotent
	m.Stop(&client{})
}

func TestStartNoDefaultRoute(t *testing.T) {
	f := newFake()
	f.noDefault = true
	m, p := newTestManager(t, f)
	_, err := m.Start(&client{}, 51234, nil, nil)
	if err == nil || err.Error() != "No internet connection." {
		t.Errorf("err = %v", err)
	}
	if strings.Contains(f.callsString(), "START") || fileExists(p.State) {
		t.Error("nothing should have been started")
	}
}

func TestStartRouteFailureRollsBack(t *testing.T) {
	f := newFake()
	f.failRoute = "-inet 128.0.0.0/1"
	m, p := newTestManager(t, f)
	_, err := m.Start(&client{}, 51234, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "128.0.0.0/1") {
		t.Fatalf("err = %v", err)
	}
	calls := f.callsString()
	if !strings.Contains(calls, "/sbin/route -n delete -inet 0.0.0.0/1") {
		t.Errorf("0/1 not rolled back:\n%s", calls)
	}
	if strings.Contains(calls, "-setdnsservers") {
		t.Error("DNS must not be touched when routes failed")
	}
	if fileExists(p.State) {
		t.Error("state.json must be gone")
	}
	select {
	case <-f.child.done:
	default:
		t.Error("tun2socks must be stopped")
	}
}

func TestIPv6Policy(t *testing.T) {
	// v6 routes fail, Mac has no v6 default: start succeeds.
	f := newFake()
	f.failRoute = "-inet6"
	m, _ := newTestManager(t, f)
	if _, err := m.Start(&client{}, 51234, nil, nil); err != nil {
		t.Errorf("no v6 default should succeed: %v", err)
	}
	// v6 routes fail and the Mac has a v6 default: must fail so nothing leaks.
	f = newFake()
	f.failRoute = "-inet6"
	f.v6Default = true
	m, _ = newTestManager(t, f)
	_, err := m.Start(&client{}, 51234, nil, nil)
	if err == nil || err.Error() != "IPv6 could not be routed through the VPN." {
		t.Errorf("err = %v", err)
	}
}

func TestPrivateRouteExistsIsNotRecorded(t *testing.T) {
	f := newFake()
	f.failRoute = "EXISTS" // matches nothing in a real line; use targeted failing below
	f.failRoute = ""
	m, p := newTestManager(t, f)
	// Make 10.0.0.0/8 report "File exists" by wrapping run.
	pf := f.platform()
	orig := pf.run
	pf.run = func(ctx context.Context, name string, args ...string) (string, error) {
		if len(args) > 3 && args[1] == "add" && args[3] == "10.0.0.0/8" {
			f.mu.Lock()
			f.calls = append(f.calls, name+" "+strings.Join(args, " "))
			f.mu.Unlock()
			return "add net 10.0.0.0: gateway 192.168.1.1: File exists\n", errors.New("exit 1")
		}
		return orig(ctx, name, args...)
	}
	m.pf = pf
	if _, err := m.Start(&client{}, 51234, nil, nil); err != nil {
		t.Fatal(err)
	}
	st, _ := readState(p.State)
	for _, r := range st.Routes {
		if r.Dest == "10.0.0.0/8" {
			t.Error("a pre-existing route must not be recorded (we must not delete it)")
		}
	}
	m.Stop(m.cur.owner)
	if strings.Contains(f.callsString(), "delete -inet 10.0.0.0/8") {
		t.Error("deleted a route we did not add")
	}
}

func TestTun2socksDiesStartFails(t *testing.T) {
	f := newFake()
	f.childDead = true
	m, p := newTestManager(t, f)
	_, err := m.Start(&client{}, 51234, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "stopped right after starting") ||
		!strings.Contains(err.Error(), "fake tun2socks last line") {
		t.Errorf("err = %v", err)
	}
	if fileExists(p.State) {
		t.Error("state.json must be gone")
	}
}

func TestExitedEvent(t *testing.T) {
	f := newFake()
	m, p := newTestManager(t, f)
	got := make(chan string, 1)
	if _, err := m.Start(&client{}, 51234, nil, func(r string) { got <- r }); err != nil {
		t.Fatal(err)
	}
	f.child.Terminate() // tun2socks dies on its own
	select {
	case r := <-got:
		if !strings.Contains(r, "stopped unexpectedly") {
			t.Errorf("reason: %q", r)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no exited event")
	}
	if fileExists(p.State) || len(f.dns["USB LAN"]) != 2 {
		t.Errorf("not cleaned up: %v", f.dns)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cur != nil {
		t.Error("session should be cleared")
	}
}

func TestStaleStateRestore(t *testing.T) {
	f := newFake()
	m, p := newTestManager(t, f)
	f.dns["Wi-Fi"] = []string{dnsServer}
	f.dns["USB LAN"] = []string{dnsServer}
	st := &State{Interface: "utun100", Pid: 777, Tun2socks: p.Tun2socks,
		Routes: []RouteRec{{"inet", "0.0.0.0/1", "default"}},
		DNS:    []DNSRec{{"Wi-Fi", nil}, {"USB LAN", []string{"9.9.9.9"}}}}
	if err := writeState(p.State, st); err != nil {
		t.Fatal(err)
	}
	if err := m.Cleanup(&client{}); err != nil {
		t.Fatal(err)
	}
	if len(f.dns["Wi-Fi"]) != 0 || strings.Join(f.dns["USB LAN"], ",") != "9.9.9.9" {
		t.Errorf("DNS: %v", f.dns)
	}
	if fileExists(p.State) {
		t.Error("state not removed")
	}
	if len(f.stale) != 1 || f.stale[0] != 777 {
		t.Errorf("stale pid not killed: %v", f.stale)
	}
	if !strings.Contains(f.callsString(), "/sbin/route -n delete -inet 0.0.0.0/1") {
		t.Error("route not deleted")
	}
}

func TestSweepDNSWithoutState(t *testing.T) {
	f := newFake()
	m, _ := newTestManager(t, f)
	f.dns["Wi-Fi"] = []string{dnsServer}
	if err := m.Cleanup(&client{}); err != nil {
		t.Fatal(err)
	}
	if len(f.dns["Wi-Fi"]) != 0 {
		t.Errorf("DNS still poisoned: %v", f.dns)
	}
	if strings.Join(f.dns["USB LAN"], ",") != "1.1.1.1,8.8.8.8" {
		t.Error("an unrelated service was modified")
	}
}

func TestStalePidOfOtherProgramNotKilled(t *testing.T) {
	f := newFake()
	m, p := newTestManager(t, f)
	pf := f.platform()
	orig := pf.run
	pf.run = func(ctx context.Context, name string, args ...string) (string, error) {
		if strings.HasSuffix(name, "ps") {
			return "/usr/bin/something-else\n", nil
		}
		return orig(ctx, name, args...)
	}
	m.pf = pf
	_ = writeState(p.State, &State{Interface: "utun100", Pid: 777, Tun2socks: p.Tun2socks})
	m.StopAll()
	if len(f.stale) != 0 {
		t.Error("killed a process that is not our tun2socks")
	}
}

func TestCleanupRefusedForOtherOwner(t *testing.T) {
	f := newFake()
	m, _ := newTestManager(t, f)
	if _, err := m.Start(&client{}, 51234, nil, nil); err != nil {
		t.Fatal(err)
	}
	if err := m.Cleanup(&client{}); err == nil {
		t.Error("cleanup must be refused while another client is connected")
	}
	if m.cur == nil {
		t.Error("live session was disturbed")
	}
}

func TestRefreshMovesBypass(t *testing.T) {
	f := newFake()
	m, _ := newTestManager(t, f)
	o := &client{}
	if _, err := m.Start(o, 51234, []string{"203.0.113.9"}, nil); err != nil {
		t.Fatal(err)
	}
	// Network changes: new gateway.
	pf := f.platform()
	orig := pf.run
	pf.run = func(ctx context.Context, name string, args ...string) (string, error) {
		if len(args) >= 3 && args[1] == "get" && args[2] == "default" {
			return strings.Replace(routeWithGateway, "192.168.1.1", "10.1.1.1", 1), nil
		}
		return orig(ctx, name, args...)
	}
	m.pf = pf
	info, err := m.Refresh(o)
	if err != nil || info.Gateway != "10.1.1.1" {
		t.Fatalf("%+v %v", info, err)
	}
	calls := f.callsString()
	if !strings.Contains(calls, "route -n delete -inet 203.0.113.9/32") || !strings.Contains(calls, "route -n add -inet 203.0.113.9/32 10.1.1.1") {
		t.Errorf("bypass not moved:\n%s", calls)
	}
	if _, err := m.Refresh(&client{}); err == nil {
		t.Error("refresh from a non-owner must fail")
	}
}
