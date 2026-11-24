package main

// Per-app usage: which app moved how many bytes through the VPN.
//
// The kernel already counts the bytes of every socket and knows which interface it uses and
// which process owns it. Apple's own nettop and Activity Monitor read those counters through
// the kernel control socket "com.apple.network.statistics" (XNU bsd/net/ntstat.h, ntstat.c).
// The helper is root, so it sees every process. It keeps only the sockets whose interface is
// the tunnel's utun: those are exactly the apps' VPN traffic (foxy-core and tun2socks use the
// physical interface and loopback). Nothing here touches the tunnel; if any of it fails, the
// VPN works exactly as before and the app just has no per-app list.
//
// This file is the platform-independent part (message parsing, counting, app names), so it is
// tested everywhere. appusage_darwin.go talks to the kernel.
//
// Layouts (checked against ntstat.h of xnu-8020 (macOS 12) to xnu-12377 (macOS 26); the
// fields used here never moved, newer releases only appended at the end):
//
//	nstat_msg_hdr        { u64 context; u32 type; u16 length; u16 flags; }            16 bytes
//	nstat_msg_src_update { hdr; u64 srcref; u64 event_flags; nstat_counts counts;
//	                       u32 provider; u8 reserved[4]; u8 data[]; }                 data at 152
//	nstat_counts         { u64 rxpackets, rxbytes, txpackets, txbytes, ... }         112 bytes
//	nstat_tcp_descriptor (TCP kernel/userland, QUIC): ifindex@72 pid@116 epid@120
//	                     local sockaddr@124 pname[64]@196
//	nstat_udp_descriptor: local sockaddr@56 remote@84 ifindex@112 pid@128 pname[64]@132 epid@196
//
// Messages may arrive several in one datagram, back to back, each sized by hdr.length.

import (
	"encoding/binary"
	"path"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	nstatMsgSuccess   = 0
	nstatMsgError     = 1
	nstatMsgAddAll    = 1002
	nstatMsgGetUpdate = 1007
	nstatMsgRemoved   = 10002
	nstatMsgUpdate    = 10006

	nstatProviderTCPKernel   = 2
	nstatProviderTCPUserland = 3
	nstatProviderUDPKernel   = 4
	nstatProviderUDPUserland = 5
	nstatProviderQUIC        = 8

	nstatSrcRefAll = ^uint64(0)

	nstatHdrFlagClosing = 1 << 2

	// Filter bits of nstat_msg_add_all_srcs.
	nstatFilterSuppressSrcAdded   = 0x0000000000100000 // no SRC_ADDED; also turns on final updates
	nstatFilterProviderNoZeroByte = 0x0000000000400000 // sockets that never moved a byte stay quiet

	nstatHdrLen        = 16
	nstatUpdateDataOff = 152
	nstatAddAllLen     = 56
	nstatQueryLen      = 24

	tcpDescMin = 260 // through pname
	udpDescMin = 200 // through epid

	afInet  = 2
	afInet6 = 30

	// A flood of sockets (a port scan, a torrent client) must not grow memory without end.
	maxTrackedFlows = 200000
	maxPendingApps  = 2000
)

// usageProviders are the sources subscribed to. QUIC is left out on purpose: its bytes are
// also those of the UDP socket underneath, which is counted already.
var usageProviders = []uint32{nstatProviderTCPKernel, nstatProviderTCPUserland, nstatProviderUDPKernel, nstatProviderUDPUserland}

// flowUpdate is one socket's cumulative counters and owner, from an SRC_UPDATE message.
type flowUpdate struct {
	srcref  uint64
	closing bool
	rx, tx  uint64
	ifindex uint32
	pid     uint32
	epid    uint32
	pname   string
}

// nstatMessage is one decoded message. kind is the message type; update is set for
// SRC_UPDATE (ok is false when its descriptor was not understood); errno for ERROR.
type nstatMessage struct {
	kind    uint32
	context uint64
	flags   uint16
	srcref  uint64
	update  flowUpdate
	ok      bool
	errno   uint32
}

// splitNstat calls fn for every message in one datagram. It stops at anything malformed.
func splitNstat(buf []byte, fn func(nstatMessage)) {
	le := binary.LittleEndian
	for len(buf) >= nstatHdrLen {
		n := int(le.Uint16(buf[12:14]))
		if n < nstatHdrLen || n > len(buf) {
			return
		}
		msg := buf[:n]
		buf = buf[n:]
		m := nstatMessage{kind: le.Uint32(msg[8:12]), context: le.Uint64(msg[0:8]), flags: le.Uint16(msg[14:16])}
		switch m.kind {
		case nstatMsgError:
			if len(msg) >= nstatHdrLen+4 {
				m.errno = le.Uint32(msg[16:20])
			}
		case nstatMsgRemoved:
			if len(msg) >= nstatHdrLen+8 {
				m.srcref = le.Uint64(msg[16:24])
			}
		case nstatMsgUpdate:
			if len(msg) >= nstatUpdateDataOff {
				m.srcref = le.Uint64(msg[16:24])
				m.update, m.ok = parseUpdate(msg)
			}
		}
		fn(m)
	}
}

// parseUpdate reads an SRC_UPDATE whose header is known to be complete.
func parseUpdate(msg []byte) (flowUpdate, bool) {
	le := binary.LittleEndian
	u := flowUpdate{
		srcref:  le.Uint64(msg[16:24]),
		closing: le.Uint16(msg[14:16])&nstatHdrFlagClosing != 0,
		rx:      le.Uint64(msg[40:48]),
		tx:      le.Uint64(msg[56:64]),
	}
	provider := le.Uint32(msg[144:148])
	d := msg[nstatUpdateDataOff:]
	switch provider {
	case nstatProviderTCPKernel, nstatProviderTCPUserland, nstatProviderQUIC:
		if len(d) < tcpDescMin || !validSockaddr(d[124:]) {
			return u, false
		}
		u.ifindex = le.Uint32(d[72:76])
		u.pid = le.Uint32(d[116:120])
		u.epid = le.Uint32(d[120:124])
		u.pname = cString(d[196:260])
	case nstatProviderUDPKernel, nstatProviderUDPUserland:
		if len(d) < udpDescMin || (!validSockaddr(d[56:]) && !validSockaddr(d[84:])) {
			return u, false
		}
		u.ifindex = le.Uint32(d[112:116])
		u.pid = le.Uint32(d[128:132])
		u.pname = cString(d[132:196])
		u.epid = le.Uint32(d[196:200])
	default:
		return u, false
	}
	return u, true
}

// validSockaddr: a sockaddr_in (len 16, AF_INET) or sockaddr_in6 (len 28, AF_INET6). This is
// how a descriptor whose layout is not the expected one is recognised and skipped.
func validSockaddr(b []byte) bool {
	if len(b) < 2 {
		return false
	}
	return (b[0] == 16 && b[1] == afInet) || (b[0] == 28 && b[1] == afInet6)
}

func cString(b []byte) string {
	if i := strings.IndexByte(string(b), 0); i >= 0 {
		b = b[:i]
	}
	return strings.ToValidUTF8(string(b), "")
}

func addAllRequest(context uint64, provider uint32) []byte {
	b := make([]byte, nstatAddAllLen)
	le := binary.LittleEndian
	le.PutUint64(b[0:8], context)
	le.PutUint32(b[8:12], nstatMsgAddAll)
	le.PutUint16(b[12:14], nstatAddAllLen)
	le.PutUint64(b[16:24], nstatFilterSuppressSrcAdded|nstatFilterProviderNoZeroByte)
	// events (24:32) 0, provider, target_pid 0, target_uuid zero: every process.
	le.PutUint32(b[32:36], provider)
	return b
}

func getUpdateRequest(context uint64) []byte {
	b := make([]byte, nstatQueryLen)
	le := binary.LittleEndian
	le.PutUint64(b[0:8], context)
	le.PutUint32(b[8:12], nstatMsgGetUpdate)
	le.PutUint16(b[12:14], nstatQueryLen)
	le.PutUint64(b[16:24], nstatSrcRefAll)
	return b
}

// AppTotal is what one app moved through the tunnel since the last take.
type AppTotal struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Up   uint64 `json:"up"`
	Down uint64 `json:"down"`
}

// appIdentity turns an executable path into the app it belongs to: the outermost .app bundle
// ("/Applications/Google Chrome.app" for every Chrome helper inside it), else "system:<name>"
// for a program outside any bundle (daemons, command line tools), else "other".
func appIdentity(exe, pname string) (id, name string) {
	if exe != "" {
		if i := strings.Index(exe, ".app/"); i > 0 {
			bundle := exe[:i+4]
			return bundle, strings.TrimSuffix(path.Base(bundle), ".app")
		}
		if strings.HasSuffix(exe, ".app") {
			return exe, strings.TrimSuffix(path.Base(exe), ".app")
		}
		base := path.Base(exe)
		return "system:" + base, base
	}
	if pname != "" {
		return "system:" + pname, pname
	}
	return "other", ""
}

type appRef struct{ id, name string }

type pidEntry struct {
	ref  appRef
	path string
	at   time.Time
}

// appResolver finds the app behind a socket's process, with a short cache per pid.
type appResolver struct {
	exePath func(pid uint32) string // "" when the process is gone or unknown
	now     func() time.Time
	cache   map[uint32]pidEntry
}

const pidCacheTTL = 2 * time.Minute

func newAppResolver(exePath func(uint32) string) *appResolver {
	return &appResolver{exePath: exePath, now: time.Now, cache: map[uint32]pidEntry{}}
}

func (r *appResolver) lookup(pid uint32, pname string) (appRef, bool) {
	if pid == 0 {
		return appRef{}, false
	}
	now := r.now()
	if e, ok := r.cache[pid]; ok && now.Sub(e.at) < pidCacheTTL {
		return e.ref, e.path != ""
	}
	p := r.exePath(pid)
	id, name := appIdentity(p, pname)
	ref := appRef{id, name}
	if len(r.cache) > 4096 {
		r.cache = map[uint32]pidEntry{}
	}
	r.cache[pid] = pidEntry{ref: ref, path: p, at: now}
	return ref, p != ""
}

// resolve prefers the effective (delegated) process: when Safari's networking runs in a WebKit
// helper, or a download runs in nsurlsessiond, the kernel names the app it works for as epid.
func (r *appResolver) resolve(pid, epid uint32, pname string) appRef {
	if epid != 0 && epid != pid {
		if ref, ok := r.lookup(epid, ""); ok {
			return ref
		}
	}
	ref, _ := r.lookup(pid, pname)
	if ref.id == "" {
		return appRef{id: "other"}
	}
	return ref
}

type flowState struct{ rx, tx uint64 }

// usageTracker turns cumulative per-socket counters into per-app byte deltas on one interface.
// A socket seen for the first time counts from zero: the utun is created for the session, so
// every socket on it moved all of its bytes through the VPN.
type usageTracker struct {
	mu      sync.Mutex
	ifindex uint32
	resolve func(pid, epid uint32, pname string) appRef
	flows   map[uint64]flowState
	pending map[string]*AppTotal
}

func newUsageTracker(ifindex uint32, resolve func(pid, epid uint32, pname string) appRef) *usageTracker {
	return &usageTracker{ifindex: ifindex, resolve: resolve, flows: map[uint64]flowState{}, pending: map[string]*AppTotal{}}
}

func (t *usageTracker) handle(m nstatMessage) {
	switch m.kind {
	case nstatMsgUpdate:
		if m.ok {
			t.update(m.update)
		} else if m.flags&nstatHdrFlagClosing != 0 {
			t.forget(m.srcref)
		}
	case nstatMsgRemoved:
		t.forget(m.srcref)
	}
}

func (t *usageTracker) forget(ref uint64) {
	t.mu.Lock()
	delete(t.flows, ref)
	t.mu.Unlock()
}

func (t *usageTracker) update(u flowUpdate) {
	t.mu.Lock()
	defer t.mu.Unlock()
	old := t.flows[u.srcref]
	var dRx, dTx uint64
	if u.rx > old.rx {
		dRx = u.rx - old.rx
	}
	if u.tx > old.tx {
		dTx = u.tx - old.tx
	}
	if u.closing {
		delete(t.flows, u.srcref)
	} else {
		if len(t.flows) >= maxTrackedFlows {
			if _, known := t.flows[u.srcref]; !known {
				return
			}
		}
		t.flows[u.srcref] = flowState{rx: max(u.rx, old.rx), tx: max(u.tx, old.tx)}
	}
	if u.ifindex != t.ifindex || (dRx == 0 && dTx == 0) {
		return
	}
	ref := t.resolve(u.pid, u.epid, u.pname)
	a := t.pending[ref.id]
	if a == nil {
		if len(t.pending) >= maxPendingApps {
			ref = appRef{id: "other"}
			a = t.pending[ref.id]
		}
		if a == nil {
			a = &AppTotal{ID: ref.id, Name: ref.name}
			t.pending[ref.id] = a
		}
	}
	a.Down += dRx
	a.Up += dTx
}

// take returns what was counted since the last take, busiest first.
func (t *usageTracker) take() []AppTotal {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]AppTotal, 0, len(t.pending))
	for _, a := range t.pending {
		out = append(out, *a)
	}
	t.pending = map[string]*AppTotal{}
	sort.Slice(out, func(i, j int) bool { return out[i].Up+out[i].Down > out[j].Up+out[j].Down })
	return out
}

// usageMonitor is a running per-app counter for one tunnel interface.
type usageMonitor interface {
	// Take polls the kernel once more and returns the per-app bytes since the last Take.
	Take() ([]AppTotal, error)
	Close()
}
