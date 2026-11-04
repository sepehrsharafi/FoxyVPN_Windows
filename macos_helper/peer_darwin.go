//go:build darwin

package main

import (
	"errors"
	"net"
	"syscall"
)

const (
	solLocal     = 0     // SOL_LOCAL
	localPeerPID = 0x002 // LOCAL_PEERPID
)

// peerPID asks the kernel who is on the other end of the unix socket.
func peerPID(c net.Conn) (int, error) {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return 0, errors.New("not a unix connection")
	}
	rc, err := uc.SyscallConn()
	if err != nil {
		return 0, err
	}
	var pid int
	var gerr error
	if err := rc.Control(func(fd uintptr) {
		pid, gerr = syscall.GetsockoptInt(int(fd), solLocal, localPeerPID)
	}); err != nil {
		return 0, err
	}
	return pid, gerr
}
