//go:build darwin

package main

import (
	"strings"
	"syscall"
)

// pin binds the socket to the physical interface (IP_BOUND_IF = 25 at IPPROTO_IP,
// IPV6_BOUND_IF = 125 at IPPROTO_IPV6), so it ignores the tunnel's default routes.
func pin(network, address string, c syscall.RawConn) error {
	if ifIdx == 0 {
		return nil
	}
	var serr error
	err := c.Control(func(fd uintptr) {
		if strings.HasSuffix(network, "6") {
			serr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IPV6, 125, ifIdx)
		} else {
			serr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, 25, ifIdx)
		}
	})
	if err != nil {
		return err
	}
	return serr
}
