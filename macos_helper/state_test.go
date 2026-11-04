package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestStateRoundTrip(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state.json")
	if st, err := readState(p); st != nil || err != nil {
		t.Fatalf("missing file: %v %v", st, err)
	}
	in := &State{
		Interface: "utun100", Pid: 4242, Tun2socks: "/Library/Application Support/FoxyVPN/tun2socks",
		Routes:    []RouteRec{{"inet", "198.18.0.0/15", "tunnel"}, {"inet6", "::/1", "default"}},
		DNS:       []DNSRec{{"Wi-Fi", nil}, {"USB 10/100 LAN", []string{"1.1.1.1", "2606:4700:4700::1111"}}},
		StartedAt: "2026-01-01T00:00:00Z",
	}
	if err := writeState(p, in); err != nil {
		t.Fatal(err)
	}
	out, err := readState(p)
	if err != nil || out == nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(in.Routes, out.Routes) || out.Interface != "utun100" || out.Pid != 4242 ||
		len(out.DNS) != 2 || !reflect.DeepEqual(out.DNS[1].Servers, in.DNS[1].Servers) {
		t.Errorf("round trip mismatch: %+v", out)
	}
}

func TestStateSanitize(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state.json")
	raw := `{"interface":"utun100","pid":-5,"routes":[
	 {"family":"inet","dest":"10.0.0.0/8","kind":"private"},
	 {"family":"inet","dest":"-n","kind":"x"},
	 {"family":"inet; rm","dest":"10.0.0.0/8","kind":"x"},
	 {"family":"inet6","dest":"::/1","kind":"default"}],
	 "dns":[{"service":"-evil","servers":["1.1.1.1"]},{"service":"","servers":[]},
	 {"service":"Wi-Fi","servers":["198.18.0.2","8.8.8.8","bad"]}]}`
	if err := os.WriteFile(p, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	st, err := readState(p)
	if err != nil || st == nil {
		t.Fatal(err)
	}
	if len(st.Routes) != 2 || st.Routes[0].Dest != "10.0.0.0/8" || st.Routes[1].Dest != "::/1" {
		t.Errorf("routes: %+v", st.Routes)
	}
	if len(st.DNS) != 1 || st.DNS[0].Service != "Wi-Fi" || !reflect.DeepEqual(st.DNS[0].Servers, []string{"8.8.8.8"}) {
		t.Errorf("dns: %+v", st.DNS)
	}
	if st.Pid != 0 {
		t.Errorf("pid: %d", st.Pid)
	}
}

func TestStateCorrupt(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state.json")
	_ = os.WriteFile(p, []byte("{not json"), 0o600)
	if _, err := readState(p); err == nil {
		t.Error("corrupt state must error")
	}
}

func TestConfig(t *testing.T) {
	dir := t.TempDir()
	paths := Paths{Config: filepath.Join(dir, "helper.json")}
	app := `/Applications/My "App" \ FoxyVPN.app`
	if err := writeConfig(paths, app+"/"); err != nil {
		t.Fatal(err)
	}
	c, err := loadConfig(paths)
	if err != nil || c.AppPath != app || c.Version != HelperVersion {
		t.Errorf("config: %+v %v", c, err)
	}
	for _, bad := range []string{"", "relative/F.app", "/Applications/F", "/Applications/F.app\nx"} {
		if err := writeConfig(paths, bad); err == nil {
			t.Errorf("%q should be rejected", bad)
		}
	}
	_ = os.WriteFile(paths.Config, []byte(`{"appPath":"nope"}`), 0o644)
	if _, err := loadConfig(paths); err == nil {
		t.Error("invalid appPath in file must be rejected")
	}
}

func TestShouldSelfRemove(t *testing.T) {
	missing := func(string) error { return os.ErrNotExist }
	present := func(string) error { return nil }
	onlyParent := func(p string) error {
		if p == "/Applications" {
			return nil
		}
		return os.ErrNotExist
	}
	denied := func(string) error { return os.ErrPermission }
	cfg := Config{AppPath: "/Applications/FoxyVPN.app"}
	if shouldSelfRemove(cfg, present) {
		t.Error("app present")
	}
	if !shouldSelfRemove(cfg, onlyParent) {
		t.Error("app gone, parent there: remove")
	}
	if shouldSelfRemove(cfg, missing) {
		t.Error("parent missing too: do not remove")
	}
	if shouldSelfRemove(cfg, denied) {
		t.Error("permission error is not 'gone'")
	}
	if shouldSelfRemove(Config{AppPath: "/Volumes/Disk/FoxyVPN.app"}, onlyParent) {
		t.Error("external volume must not trigger removal")
	}
	if shouldSelfRemove(Config{}, missing) {
		t.Error("empty config")
	}
}

func TestLoggerRotation(t *testing.T) {
	p := filepath.Join(t.TempDir(), "helper.log")
	l := newLogger(p)
	line := strings.Repeat("x", 1500)
	for i := 0; i < 1500; i++ { // ~2.2 MB total
		l.Printf("%s", line)
	}
	l.Close()
	fi, err := os.Stat(p)
	if err != nil || fi.Size() > maxLogSize {
		t.Errorf("log size %v err %v", fi, err)
	}
	if _, err := os.Stat(p + ".1"); err != nil {
		t.Errorf("rotated file missing: %v", err)
	}
}

func TestLineRing(t *testing.T) {
	r := &lineRing{}
	for i := 0; i < 80; i++ {
		_, _ = r.Write([]byte("line " + itoa(i) + "\n"))
	}
	_, _ = r.Write([]byte("partial"))
	tail := r.Tail()
	if len(tail) != 51 || tail[0] != "line 30" || tail[50] != "partial" {
		t.Errorf("tail: len %d first %q last %q", len(tail), tail[0], tail[len(tail)-1])
	}
	_, _ = r.Write([]byte(strings.Repeat("y", 5000) + "\n"))
	for _, l := range r.Tail() {
		if len(l) > 1024 {
			t.Fatal("line not capped")
		}
	}
}
