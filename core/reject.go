package main

import (
	"strings"
	"sync"
	"time"
)

// rejectCache remembers destinations the edge refused (it prohibits most UDP
// ports), so apps that retry (QUIC falls back to TCP after a while) do not
// open a stream per packet. Shared by all associations. Mirrors
// UdpRejectionCache in lib/tunnel/udp_relay.dart.
type rejectCache struct {
	mu         sync.Mutex
	until      map[string]time.Time
	maxEntries int
	now        func() time.Time
}

const (
	rejectTTL           = 5 * time.Minute
	transientFailureTTL = 10 * time.Second
)

func newRejectCache() *rejectCache {
	return &rejectCache{until: map[string]time.Time{}, maxEntries: 1024, now: time.Now}
}

func (c *rejectCache) isRejected(key string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.until) == 0 {
		return false
	}
	t, ok := c.until[key]
	if !ok {
		return false
	}
	if t.After(c.now()) {
		return true
	}
	delete(c.until, key)
	return false
}

func (c *rejectCache) reject(key string, d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	c.until[key] = now.Add(d)
	if len(c.until) > c.maxEntries {
		// Drop expired entries first, then whatever expires soonest.
		for k, t := range c.until {
			if !t.After(now) {
				delete(c.until, k)
			}
		}
		for len(c.until) > c.maxEntries {
			var oldest string
			var ot time.Time
			for k, t := range c.until {
				if oldest == "" || t.Before(ot) {
					oldest, ot = k, t
				}
			}
			delete(c.until, oldest)
		}
	}
}

// rejectLifetime mirrors udpRejectionLifetime in udp_relay.dart: a refusal
// that will not change (the destination address is prohibited, or the port
// is not one of the few the edge allows) lasts five minutes, any other
// refusal (busy edge) only a few seconds.
func rejectLifetime(port int, proxyStatus string) time.Duration {
	permanent := strings.Contains(proxyStatus, "destination_ip_prohibited") ||
		!(port == 80 || port == 443 || port == 3478)
	if permanent {
		return rejectTTL
	}
	return transientFailureTTL
}
