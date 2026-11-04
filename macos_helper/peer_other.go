//go:build !darwin

package main

import (
	"errors"
	"net"
)

// The helper only runs on macOS; this stub keeps the package buildable for tests elsewhere.
func peerPID(c net.Conn) (int, error) {
	return 0, errors.New("peer check is only available on macOS")
}
