package main

import (
	"errors"
	"testing"
	"time"
)

type fakeUsage struct {
	apps   []AppTotal
	closed chan struct{}
}

func (f *fakeUsage) Take() ([]AppTotal, error) { a := f.apps; f.apps = nil; return a, nil }
func (f *fakeUsage) Close()                    { close(f.closed) }

func TestManagerAppUsage(t *testing.T) {
	f := newFake()
	pf := f.platform()
	mon := &fakeUsage{apps: []AppTotal{{ID: "/Applications/Safari.app", Name: "Safari", Up: 1, Down: 2}}, closed: make(chan struct{})}
	started := make(chan string, 1)
	pf.appUsage = func(iface string, _ *Logger) (usageMonitor, error) { started <- iface; return mon, nil }
	_, p := newTestManager(t, f)
	m := newManager(p, pf, nil)
	owner, other := &client{}, &client{}
	if _, err := m.Start(owner, 51234, nil, nil); err != nil {
		t.Fatal(err)
	}
	if iface := <-started; iface != "utun100" {
		t.Fatalf("counting on %q", iface)
	}
	var apps []AppTotal
	var running bool
	for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if apps, running = m.TakeAppUsage(owner); running {
			break
		}
	}
	if !running || len(apps) != 1 || apps[0].Name != "Safari" || apps[0].Down != 2 {
		t.Fatalf("take = %+v, %v", apps, running)
	}
	if apps, running = m.TakeAppUsage(other); running || apps != nil {
		t.Fatal("another client read the owner's usage")
	}
	m.Stop(owner)
	select {
	case <-mon.closed:
	case <-time.After(2 * time.Second):
		t.Fatal("monitor not closed at teardown")
	}
	if _, running = m.TakeAppUsage(owner); running {
		t.Fatal("usage still running after stop")
	}
}

func TestManagerAppUsageUnavailableKeepsTunnel(t *testing.T) {
	f := newFake()
	pf := f.platform()
	done := make(chan struct{})
	pf.appUsage = func(string, *Logger) (usageMonitor, error) { defer close(done); return nil, errors.New("no ntstat") }
	_, p := newTestManager(t, f)
	m := newManager(p, pf, nil)
	owner := &client{}
	if _, err := m.Start(owner, 51234, nil, nil); err != nil {
		t.Fatal(err)
	}
	<-done
	if _, running := m.TakeAppUsage(owner); running {
		t.Fatal("running without a monitor")
	}
	m.Stop(owner)
}
