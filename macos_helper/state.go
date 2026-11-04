package main

import (
	"encoding/json"
	"errors"
	"net/netip"
	"os"
	"strings"
)

// RouteRec is a route we added and must delete again.
type RouteRec struct {
	Family string `json:"family"` // "inet" or "inet6"
	Dest   string `json:"dest"`   // prefix like 10.0.0.0/8
	Kind   string `json:"kind"`   // tunnel, bypass, private, default
}

// DNSRec is one network service and the DNS servers it had before we touched it.
type DNSRec struct {
	Service string   `json:"service"`
	Servers []string `json:"servers"` // empty = automatic
}

// State is written before every change so a crash can be undone at the next helper start.
type State struct {
	Interface string     `json:"interface"`
	Pid       int        `json:"pid"`
	Tun2socks string     `json:"tun2socks"`
	Routes    []RouteRec `json:"routes"`
	DNS       []DNSRec   `json:"dns"`
	StartedAt string     `json:"startedAt"`
}

// readState returns (nil, nil) when there is no state file.
func readState(path string) (*State, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if len(b) > 1<<20 {
		return nil, errors.New("state.json is too large")
	}
	var st State
	if err := json.Unmarshal(b, &st); err != nil {
		return nil, err
	}
	st.sanitize()
	return &st, nil
}

func writeState(path string, st *State) error {
	b, err := json.Marshal(st)
	if err != nil {
		return err
	}
	return writeFileAtomic(path, b, 0o600)
}

// sanitize drops anything that is not a route or DNS entry we could have written, so a damaged
// state file can never make us run something odd as root.
func (st *State) sanitize() {
	var routes []RouteRec
	for _, r := range st.Routes {
		if r.Family != "inet" && r.Family != "inet6" {
			continue
		}
		if _, err := netip.ParsePrefix(r.Dest); err != nil {
			continue
		}
		routes = append(routes, r)
	}
	st.Routes = routes
	var dns []DNSRec
	for _, d := range st.DNS {
		if d.Service == "" || strings.HasPrefix(d.Service, "-") {
			continue
		}
		var servers []string
		for _, s := range d.Servers {
			if a, err := netip.ParseAddr(s); err == nil && a.String() != dnsServer {
				servers = append(servers, a.String())
			}
		}
		d.Servers = servers
		dns = append(dns, d)
	}
	st.DNS = dns
	if st.Pid < 0 {
		st.Pid = 0
	}
}
