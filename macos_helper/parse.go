package main

import (
	"errors"
	"fmt"
	"net/netip"
	"path/filepath"
	"strings"
)

// routeInfo is what we need from `route -n get default`.
type routeInfo struct {
	Interface string
	Gateway   string // empty for point-to-point / interface-only routes
}

// parseRouteGet reads the output of `/sbin/route -n get ...`. Example:
//
//	   route to: default
//	destination: default
//	       mask: default
//	    gateway: 192.168.1.1
//	  interface: en0
func parseRouteGet(out string) (routeInfo, error) {
	var ri routeInfo
	for _, line := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		v = strings.TrimSpace(v)
		switch strings.TrimSpace(k) {
		case "interface":
			ri.Interface = v
		case "gateway":
			// Only real IP gateways count; "link#4" or a MAC address means interface-only.
			if a, err := netip.ParseAddr(v); err == nil {
				ri.Gateway = a.WithZone("").String()
			}
		}
	}
	if ri.Interface == "" {
		return ri, errors.New("no default route")
	}
	return ri, nil
}

// parseServices reads `networksetup -listallnetworkservices`: a header line, then one service per
// line, disabled ones prefixed with "*".
func parseServices(out string) []string {
	var res []string
	for i, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r ")
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "*") {
			continue
		}
		if i == 0 && strings.Contains(line, "asterisk") {
			continue
		}
		res = append(res, line)
	}
	return res
}

// parseDNSServers reads `networksetup -getdnsservers <svc>`. A sentence such as "There aren't any
// DNS Servers set on Wi-Fi." means none.
func parseDNSServers(out string) []string {
	var res []string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if a, err := netip.ParseAddr(line); err == nil {
			res = append(res, a.String())
		}
	}
	return res
}

// pickUtun returns the first utunN (lo..hi) that does not exist yet.
func pickUtun(existing []string, lo, hi int) (string, error) {
	have := make(map[string]bool, len(existing))
	for _, n := range existing {
		have[n] = true
	}
	for n := lo; n <= hi; n++ {
		name := fmt.Sprintf("utun%d", n)
		if !have[name] {
			return name, nil
		}
	}
	return "", errors.New("no free network interface name is available")
}

// validateBypass accepts only public-looking IPv4 literals and returns them de-duplicated.
func validateBypass(list []string) ([]string, error) {
	if len(list) > 32 {
		return nil, errors.New("too many bypass addresses")
	}
	seen := map[string]bool{}
	var res []string
	for _, s := range list {
		a, err := netip.ParseAddr(strings.TrimSpace(s))
		if err != nil || !a.Is4() {
			return nil, fmt.Errorf("%q is not an IPv4 address", s)
		}
		b := a.As4()
		switch {
		case a.IsUnspecified(), b[0] == 0, b[0] == 127, a.IsMulticast(), b[0] >= 240,
			b[0] == 198 && (b[1] == 18 || b[1] == 19):
			return nil, fmt.Errorf("%s cannot be used as a bypass address", a)
		}
		if !seen[a.String()] {
			seen[a.String()] = true
			res = append(res, a.String())
		}
	}
	return res, nil
}

func validPort(p int) bool { return p >= 1024 && p <= 65535 }

// peerAllowed reports whether exe lives inside <appPath>/Contents/MacOS/. resolve (may be nil)
// maps a path through symlinks, since /var vs /private/var style differences are common.
func peerAllowed(exe, appPath string, resolve func(string) string) bool {
	if exe == "" || appPath == "" || strings.ContainsRune(exe, 0) {
		return false
	}
	exes := []string{filepath.ToSlash(filepath.Clean(exe))}
	apps := []string{filepath.ToSlash(filepath.Clean(appPath))}
	if resolve != nil {
		if r := resolve(exe); r != "" {
			exes = append(exes, filepath.ToSlash(filepath.Clean(r)))
		}
		if r := resolve(appPath); r != "" {
			apps = append(apps, filepath.ToSlash(filepath.Clean(r)))
		}
	}
	for _, e := range exes {
		for _, a := range apps {
			prefix := strings.TrimRight(a, "/") + "/Contents/MacOS/"
			if strings.HasPrefix(e, prefix) && len(e) > len(prefix) {
				return true
			}
		}
	}
	return false
}
