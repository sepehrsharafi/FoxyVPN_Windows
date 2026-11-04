package main

import (
	"reflect"
	"strings"
	"testing"
)

const routeWithGateway = `   route to: default
destination: default
       mask: default
    gateway: 192.168.1.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
 recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
       0         0         0         0         0         0      1500         0
`

const routeInterfaceOnly = `   route to: default
destination: default
       mask: default
  interface: utun4
      flags: <UP,DONE,STATIC,GLOBAL>
 recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
       0         0         0         0         0         0      1380         0
`

const routeLinkGateway = `   route to: default
destination: default
       mask: default
    gateway: link#14
  interface: ppp0
      flags: <UP,DONE,STATIC>
`

const routeV6 = `   route to: default
destination: default
       mask: default
    gateway: fe80::1%en0
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
`

func TestParseRouteGet(t *testing.T) {
	cases := []struct {
		name, in string
		want     routeInfo
		wantErr  bool
	}{
		{"gateway", routeWithGateway, routeInfo{"en0", "192.168.1.1"}, false},
		{"interface only", routeInterfaceOnly, routeInfo{"utun4", ""}, false},
		{"link gateway", routeLinkGateway, routeInfo{"ppp0", ""}, false},
		{"v6 gateway zone stripped", routeV6, routeInfo{"en0", "fe80::1"}, false},
		{"not in table", "route: writing to routing socket: not in table\nroute: no such process\n", routeInfo{}, true},
		{"empty", "", routeInfo{}, true},
	}
	for _, c := range cases {
		got, err := parseRouteGet(c.in)
		if (err != nil) != c.wantErr {
			t.Errorf("%s: err = %v, wantErr %v", c.name, err, c.wantErr)
		}
		if !c.wantErr && got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}

func TestParseServices(t *testing.T) {
	in := "An asterisk (*) denotes that a network service is disabled.\nUSB 10/100/1000 LAN\nWi-Fi\n*Thunderbolt Bridge\niPhone USB\n\n"
	want := []string{"USB 10/100/1000 LAN", "Wi-Fi", "iPhone USB"}
	if got := parseServices(in); !reflect.DeepEqual(got, want) {
		t.Errorf("got %q want %q", got, want)
	}
	// No header: a real first service must not be thrown away.
	if got := parseServices("Wi-Fi\n*Bluetooth PAN\n"); !reflect.DeepEqual(got, []string{"Wi-Fi"}) {
		t.Errorf("headerless: %q", got)
	}
	if got := parseServices("An asterisk (*) denotes that a network service is disabled.\n"); len(got) != 0 {
		t.Errorf("header only: %q", got)
	}
	// CRLF-safe
	if got := parseServices("An asterisk (*) denotes that a network service is disabled.\r\nWi-Fi\r\n"); !reflect.DeepEqual(got, []string{"Wi-Fi"}) {
		t.Errorf("crlf: %q", got)
	}
}

func TestParseDNSServers(t *testing.T) {
	if got := parseDNSServers("There aren't any DNS Servers set on Wi-Fi.\n"); len(got) != 0 {
		t.Errorf("none case: %q", got)
	}
	if got := parseDNSServers("1.1.1.1\n8.8.8.8\n"); !reflect.DeepEqual(got, []string{"1.1.1.1", "8.8.8.8"}) {
		t.Errorf("two servers: %q", got)
	}
	if got := parseDNSServers("2606:4700:4700::1111\n192.168.1.1\n"); !reflect.DeepEqual(got, []string{"2606:4700:4700::1111", "192.168.1.1"}) {
		t.Errorf("v6: %q", got)
	}
	if got := parseDNSServers("** Error: The parameters were not valid.\n"); len(got) != 0 {
		t.Errorf("error text: %q", got)
	}
}

func TestPickUtun(t *testing.T) {
	got, err := pickUtun([]string{"lo0", "en0", "utun0", "utun1", "utun100"}, 100, 199)
	if err != nil || got != "utun101" {
		t.Errorf("got %q %v", got, err)
	}
	got, _ = pickUtun(nil, 100, 199)
	if got != "utun100" {
		t.Errorf("empty: %q", got)
	}
	var all []string
	for i := 100; i <= 199; i++ {
		all = append(all, "utun"+strings.TrimSpace(itoa(i)))
	}
	if _, err := pickUtun(all, 100, 199); err == nil {
		t.Error("expected error when all are taken")
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	s := ""
	for i > 0 {
		s = string(rune('0'+i%10)) + s
		i /= 10
	}
	return s
}

func TestValidateBypass(t *testing.T) {
	good, err := validateBypass([]string{"203.0.113.9", " 8.8.8.8 ", "203.0.113.9", "169.254.1.1"})
	if err != nil || !reflect.DeepEqual(good, []string{"203.0.113.9", "8.8.8.8", "169.254.1.1"}) {
		t.Errorf("good: %v %v", good, err)
	}
	bad := []string{"", "abc", "1.2.3", "0.0.0.0", "0.1.2.3", "127.0.0.1", "198.18.0.2", "198.19.255.1",
		"224.0.0.1", "239.255.255.250", "240.0.0.1", "255.255.255.255", "::1", "2001:db8::1", "::ffff:1.2.3.4",
		"1.2.3.4/32", "1.2.3.4%en0", "-1.2.3.4"}
	for _, b := range bad {
		if _, err := validateBypass([]string{b}); err == nil {
			t.Errorf("%q should be rejected", b)
		}
	}
	// 198.17 and 198.20 are fine (only 198.18/15 is ours).
	if _, err := validateBypass([]string{"198.17.0.1", "198.20.0.1"}); err != nil {
		t.Errorf("198.17/198.20 rejected: %v", err)
	}
	many := make([]string, 33)
	for i := range many {
		many[i] = "8.8.8." + itoa(i+1)
	}
	if _, err := validateBypass(many); err == nil {
		t.Error("33 entries should be rejected")
	}
	if _, err := validateBypass(many[:32]); err != nil {
		t.Errorf("32 entries: %v", err)
	}
}

func TestValidPort(t *testing.T) {
	for p, want := range map[int]bool{0: false, 80: false, 1023: false, 1024: true, 54321: true, 65535: true, 65536: false, -1: false} {
		if validPort(p) != want {
			t.Errorf("port %d", p)
		}
	}
}

func TestPeerAllowed(t *testing.T) {
	app := "/Applications/FoxyVPN.app"
	ok := []string{
		"/Applications/FoxyVPN.app/Contents/MacOS/FoxyVPN",
		"/Applications/FoxyVPN.app/Contents/MacOS/foxyvpn-smoke-client",
	}
	for _, e := range ok {
		if !peerAllowed(e, app, nil) {
			t.Errorf("%q should be allowed", e)
		}
	}
	bad := []string{
		"",
		"/Applications/FoxyVPN.app/Contents/MacOS/",
		"/Applications/FoxyVPN.app/Contents/MacOS",
		"/Applications/FoxyVPN.app/Contents/Resources/helper/foxyvpn-helper",
		"/Applications/FoxyVPN.app/Contents/MacOS/../Resources/evil",
		"/Applications/FoxyVPN.app.evil/Contents/MacOS/FoxyVPN",
		"/Applications/FoxyVPN.appx/Contents/MacOS/FoxyVPN",
		"/tmp/Applications/FoxyVPN.app/Contents/MacOS/FoxyVPN",
		"/usr/bin/curl",
		"Applications/FoxyVPN.app/Contents/MacOS/FoxyVPN/../../../../evil",
	}
	for _, e := range bad {
		if peerAllowed(e, app, nil) {
			t.Errorf("%q must be rejected", e)
		}
	}
	if peerAllowed("/Applications/FoxyVPN.app/Contents/MacOS/FoxyVPN", "", nil) {
		t.Error("empty app path must reject")
	}
	// Paths with spaces and quotes.
	weird := `/Users/a b/My "Apps"/FoxyVPN.app`
	if !peerAllowed(weird+"/Contents/MacOS/FoxyVPN", weird, nil) {
		t.Error("spaces and quotes")
	}
	// Symlinked prefix (/var -> /private/var).
	resolve := func(p string) string {
		return strings.Replace(p, "/var/", "/private/var/", 1)
	}
	if !peerAllowed("/private/var/x/F.app/Contents/MacOS/F", "/var/x/F.app", resolve) {
		t.Error("resolved app path")
	}
	if !peerAllowed("/var/x/F.app/Contents/MacOS/F", "/private/var/x/F.app", resolve) {
		t.Error("resolved exe path")
	}
	// A trailing slash on the app path is tolerated.
	if !peerAllowed("/Applications/FoxyVPN.app/Contents/MacOS/FoxyVPN", "/Applications/FoxyVPN.app/", nil) {
		t.Error("trailing slash")
	}
}
