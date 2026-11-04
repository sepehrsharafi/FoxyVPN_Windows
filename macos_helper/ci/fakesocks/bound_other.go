//go:build !darwin

package main

import (
	"syscall"
)

// Only macOS pins sockets; elsewhere this keeps the program compiling for vet.
func pin(network, address string, c syscall.RawConn) error { return nil }
