package main

import (
	"encoding/binary"
	"testing"
)

// fakeUpdate builds an SRC_UPDATE exactly as ntstat.h lays it out.
func fakeUpdate(srcref uint64, provider uint32, flags uint16, rx, tx uint64, ifindex, pid, epid uint32, pname string) []byte {
	le := binary.LittleEndian
	descLen := tcpDescMin + 72 // newer kernels append fields: must still parse
	if provider == nstatProviderUDPKernel || provider == nstatProviderUDPUserland {
		descLen = udpDescMin + 40
	}
	b := make([]byte, nstatUpdateDataOff+descLen)
	le.PutUint32(b[8:12], nstatMsgUpdate)
	le.PutUint16(b[12:14], uint16(len(b)))
	le.PutUint16(b[14:16], flags)
	le.PutUint64(b[16:24], srcref)
	le.PutUint64(b[40:48], rx)
	le.PutUint64(b[56:64], tx)
	le.PutUint32(b[144:148], provider)
	d := b[nstatUpdateDataOff:]
	switch provider {
	case nstatProviderUDPKernel, nstatProviderUDPUserland:
		d[56], d[57] = 16, afInet
		le.PutUint32(d[112:116], ifindex)
		le.PutUint32(d[128:132], pid)
		copy(d[132:196], pname)
		le.PutUint32(d[196:200], epid)
	default:
		d[124], d[125] = 28, afInet6
		le.PutUint32(d[72:76], ifindex)
		le.PutUint32(d[116:120], pid)
		le.PutUint32(d[120:124], epid)
		copy(d[196:260], pname)
	}
	return b
}

func TestSplitNstatParsesAggregatedMessages(t *testing.T) {
	buf := append(fakeUpdate(7, nstatProviderTCPKernel, 0, 1000, 200, 42, 501, 0, "curl"),
		fakeUpdate(8, nstatProviderUDPUserland, nstatHdrFlagClosing, 30, 40, 42, 600, 601, "WebKit")...)
	ok := make([]byte, nstatHdrLen)
	binary.LittleEndian.PutUint64(ok[0:8], 99)
	binary.LittleEndian.PutUint16(ok[12:14], nstatHdrLen)
	buf = append(buf, ok...)

	var got []nstatMessage
	splitNstat(buf, func(m nstatMessage) { got = append(got, m) })
	if len(got) != 3 {
		t.Fatalf("got %d messages, want 3", len(got))
	}
	u := got[0].update
	if !got[0].ok || u.srcref != 7 || u.rx != 1000 || u.tx != 200 || u.ifindex != 42 || u.pid != 501 || u.pname != "curl" || u.closing {
		t.Fatalf("tcp update = %+v ok=%v", u, got[0].ok)
	}
	u = got[1].update
	if !got[1].ok || u.srcref != 8 || u.rx != 30 || u.tx != 40 || u.pid != 600 || u.epid != 601 || u.pname != "WebKit" || !u.closing {
		t.Fatalf("udp update = %+v ok=%v", u, got[1].ok)
	}
	if got[2].kind != nstatMsgSuccess || got[2].context != 99 {
		t.Fatalf("success = %+v", got[2])
	}
}

func TestSplitNstatStopsAtMalformed(t *testing.T) {
	b := fakeUpdate(1, nstatProviderTCPKernel, 0, 1, 1, 1, 1, 0, "x")
	binary.LittleEndian.PutUint16(b[12:14], uint16(len(b)+10)) // claims more than there is
	n := 0
	splitNstat(b, func(nstatMessage) { n++ })
	splitNstat(b[:10], func(nstatMessage) { n++ })
	if n != 0 {
		t.Fatalf("parsed %d malformed messages", n)
	}
}

func TestParseUpdateRejectsUnknownLayout(t *testing.T) {
	b := fakeUpdate(1, nstatProviderTCPKernel, 0, 1, 1, 1, 1, 0, "x")
	d := b[nstatUpdateDataOff:]
	d[124], d[125] = 0, 0 // the sockaddr is not where it should be
	var m nstatMessage
	splitNstat(b, func(x nstatMessage) { m = x })
	if m.ok {
		t.Fatal("a descriptor without a valid sockaddr was accepted")
	}
	short := fakeUpdate(1, nstatProviderTCPKernel, 0, 1, 1, 1, 1, 0, "x")[:nstatUpdateDataOff+100]
	binary.LittleEndian.PutUint16(short[12:14], uint16(len(short)))
	splitNstat(short, func(x nstatMessage) { m = x })
	if m.ok {
		t.Fatal("a short descriptor was accepted")
	}
}

func TestRequestsLayout(t *testing.T) {
	le := binary.LittleEndian
	a := addAllRequest(5, nstatProviderUDPKernel)
	if len(a) != 56 || le.Uint64(a[0:8]) != 5 || le.Uint32(a[8:12]) != nstatMsgAddAll || le.Uint16(a[12:14]) != 56 ||
		le.Uint32(a[32:36]) != nstatProviderUDPKernel || le.Uint64(a[16:24])&nstatFilterSuppressSrcAdded == 0 {
		t.Fatalf("add all = %x", a)
	}
	q := getUpdateRequest(6)
	if len(q) != 24 || le.Uint32(q[8:12]) != nstatMsgGetUpdate || le.Uint64(q[16:24]) != nstatSrcRefAll {
		t.Fatalf("get update = %x", q)
	}
}

func TestAppIdentity(t *testing.T) {
	cases := []struct{ exe, pname, id, name string }{
		{"/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", "", "/Applications/Google Chrome.app", "Google Chrome"},
		{"/System/Applications/Mail.app/Contents/MacOS/Mail", "", "/System/Applications/Mail.app", "Mail"},
		{"/usr/sbin/mDNSResponder", "mDNSResponder", "system:mDNSResponder", "mDNSResponder"},
		{"", "nsurlsessiond", "system:nsurlsessiond", "nsurlsessiond"},
		{"", "", "other", ""},
	}
	for _, c := range cases {
		id, name := appIdentity(c.exe, c.pname)
		if id != c.id || name != c.name {
			t.Errorf("appIdentity(%q) = %q, %q; want %q, %q", c.exe, id, name, c.id, c.name)
		}
	}
}

func TestResolverPrefersDelegatingApp(t *testing.T) {
	paths := map[uint32]string{
		10: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
		20: "/Applications/Safari.app/Contents/MacOS/Safari",
	}
	calls := 0
	r := newAppResolver(func(pid uint32) string { calls++; return paths[pid] })
	if got := r.resolve(10, 20, "com.apple.WebK"); got.id != "/Applications/Safari.app" || got.name != "Safari" {
		t.Fatalf("delegated = %+v", got)
	}
	if got := r.resolve(10, 0, "com.apple.WebK"); got.id != "system:com.apple.WebKit.Networking" {
		t.Fatalf("own = %+v", got)
	}
	// The epid is gone: fall back to the socket's own process.
	if got := r.resolve(10, 30, "x"); got.id != "system:com.apple.WebKit.Networking" {
		t.Fatalf("gone epid = %+v", got)
	}
	before := calls
	r.resolve(10, 20, "")
	if calls != before {
		t.Fatal("cached pids were looked up again")
	}
}

func TestTrackerCountsOnlyTheTunnel(t *testing.T) {
	tr := newUsageTracker(42, func(pid, epid uint32, pname string) appRef {
		return appRef{id: "app" + pname, name: pname}
	})
	feed := func(b []byte) { splitNstat(b, tr.handle) }

	feed(fakeUpdate(1, nstatProviderTCPKernel, 0, 1000, 100, 42, 1, 0, "A"))
	feed(fakeUpdate(2, nstatProviderTCPKernel, 0, 5000, 500, 4, 2, 0, "B")) // physical interface
	feed(fakeUpdate(3, nstatProviderUDPKernel, 0, 300, 30, 42, 3, 0, "A"))
	got := tr.take()
	if len(got) != 1 || got[0].ID != "appA" || got[0].Down != 1300 || got[0].Up != 130 {
		t.Fatalf("first take = %+v", got)
	}

	// Cumulative counters: only the growth counts. A counter going down adds nothing.
	feed(fakeUpdate(1, nstatProviderTCPKernel, 0, 1500, 100, 42, 1, 0, "A"))
	feed(fakeUpdate(3, nstatProviderUDPKernel, 0, 200, 60, 42, 3, 0, "A"))
	got = tr.take()
	if len(got) != 1 || got[0].Down != 500 || got[0].Up != 30 {
		t.Fatalf("second take = %+v", got)
	}

	// The final update of a closing socket counts, then the socket is forgotten.
	feed(fakeUpdate(1, nstatProviderTCPKernel, nstatHdrFlagClosing, 1600, 110, 42, 1, 0, "A"))
	if _, ok := tr.flows[1]; ok {
		t.Fatal("closed flow still tracked")
	}
	got = tr.take()
	if len(got) != 1 || got[0].Down != 100 || got[0].Up != 10 {
		t.Fatalf("closing take = %+v", got)
	}

	// SRC_REMOVED forgets too.
	rem := make([]byte, 24)
	binary.LittleEndian.PutUint32(rem[8:12], nstatMsgRemoved)
	binary.LittleEndian.PutUint16(rem[12:14], 24)
	binary.LittleEndian.PutUint64(rem[16:24], 3)
	feed(rem)
	if _, ok := tr.flows[3]; ok {
		t.Fatal("removed flow still tracked")
	}
	if got = tr.take(); len(got) != 0 {
		t.Fatalf("empty take = %+v", got)
	}
}
