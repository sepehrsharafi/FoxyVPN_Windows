package main

import (
	"context"
	"errors"
	"strings"
	"time"
)

const networksetup = "/usr/sbin/networksetup"

// services lists the enabled network services (disabled ones start with "*").
func (m *Manager) services(ctx context.Context) ([]string, error) {
	out, err := m.pf.run(ctx, networksetup, "-listallnetworkservices")
	if err != nil {
		return nil, err
	}
	return parseServices(out), nil
}

func (m *Manager) getDNS(ctx context.Context, svc string) ([]string, error) {
	out, err := m.pf.run(ctx, networksetup, "-getdnsservers", svc)
	if err != nil {
		return nil, err
	}
	return parseDNSServers(out), nil
}

func (m *Manager) putDNS(ctx context.Context, svc string, servers []string) error {
	args := []string{"-setdnsservers", svc}
	if len(servers) == 0 {
		args = append(args, "empty")
	} else {
		args = append(args, servers...)
	}
	_, err := m.pf.run(ctx, networksetup, args...)
	return err
}

func (m *Manager) flushDNS(ctx context.Context) {
	_, _ = m.pf.run(ctx, "/usr/bin/dscacheutil", "-flushcache")
	_, _ = m.pf.run(ctx, "/usr/bin/killall", "-HUP", "mDNSResponder")
}

// setDNS points every enabled service at the tunnel's resolver, saving the old servers first.
func (m *Manager) setDNS(ctx context.Context, s *session) error {
	svcs, err := m.services(ctx)
	if err != nil || len(svcs) == 0 {
		return errors.New("The network services of this Mac could not be read, so DNS could not be set up.")
	}
	ok := 0
	for _, svc := range svcs {
		old, err := m.getDNS(ctx, svc)
		if err != nil {
			m.log.Printf("could not read DNS of %q (skipped): %v", svc, err)
			continue
		}
		if len(old) == 1 && old[0] == dnsServer {
			old = nil // left over from a crash without state: never "restore" to ourselves
		}
		s.st.DNS = append(s.st.DNS, DNSRec{Service: svc, Servers: old})
		m.save(s)
		if err := m.putDNS(ctx, svc, []string{dnsServer}); err != nil {
			m.log.Printf("could not set DNS of %q: %v", svc, err)
			continue
		}
		ok++
	}
	if ok == 0 {
		return errors.New("DNS could not be set up on any network service.")
	}
	m.flushDNS(ctx)
	return nil
}

// restoreDNS puts the saved servers back, with a few retries: stuck DNS means no internet.
func (m *Manager) restoreDNS(ctx context.Context, d DNSRec) {
	for i := 0; i < 3; i++ {
		err := m.putDNS(ctx, d.Service, d.Servers)
		if err == nil {
			return
		}
		m.log.Printf("restoring DNS of %q failed (try %d): %v", d.Service, i+1, err)
		time.Sleep(500 * time.Millisecond)
	}
}

// sweepDNS is the last safety net: any service still pointing only at 198.18.0.2 (for example
// after a crash that lost state.json) goes back to automatic DNS.
func (m *Manager) sweepDNS() {
	ctx := context.Background()
	svcs, err := m.services(ctx)
	if err != nil {
		return
	}
	fixed := false
	for _, svc := range svcs {
		cur, err := m.getDNS(ctx, svc)
		if err == nil && len(cur) == 1 && cur[0] == dnsServer && !strings.HasPrefix(svc, "-") {
			m.log.Printf("DNS of %q still pointed at the VPN, resetting it", svc)
			m.restoreDNS(ctx, DNSRec{Service: svc})
			fixed = true
		}
	}
	if fixed {
		m.flushDNS(ctx)
	}
}
