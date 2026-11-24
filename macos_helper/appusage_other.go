//go:build !darwin

package main

import "errors"

// Per-app counting needs the macOS kernel; elsewhere (tests) there is none.
func startAppUsage(iface string, log *Logger) (usageMonitor, error) {
	return nil, errors.New("per-app usage needs macOS")
}
