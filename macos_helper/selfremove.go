package main

import (
	"context"
	"errors"
	"os"
	"path"
	"strings"
	"time"
)

// shouldSelfRemove decides whether the app is really gone (dragged to the Trash). Unreadable
// config, an app on an unmounted /Volumes disk, or any stat error other than "does not exist"
// never counts as gone.
func shouldSelfRemove(cfg Config, stat func(string) error) bool {
	if validAppPath(cfg.AppPath) != nil || strings.HasPrefix(cfg.AppPath, "/Volumes/") {
		return false
	}
	if err := stat(cfg.AppPath); !errors.Is(err, os.ErrNotExist) {
		return false
	}
	// Its parent folder must still exist, otherwise a whole disk may just be missing.
	return stat(path.Dir(cfg.AppPath)) == nil
}

func osStat(p string) error {
	_, err := os.Stat(p)
	return err
}

// checkSelfRemove removes the helper completely when the app is gone. It returns true if it did
// (the caller then exits).
func checkSelfRemove(paths Paths, mgr *Manager, log *Logger) bool {
	cfg, err := loadConfig(paths)
	if err != nil || !shouldSelfRemove(cfg, osStat) {
		return false
	}
	log.Printf("the app %q is gone: removing the helper", cfg.AppPath)
	mgr.Shutdown()
	for _, p := range []string{paths.Tun2socks, paths.Config, paths.State, paths.Log + ".1",
		paths.Plist, paths.Socket, paths.Binary} {
		_ = os.Remove(p)
	}
	log.Close()
	_ = os.Remove(paths.Log)
	_ = os.Remove(paths.Dir) // only succeeds when empty
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, _ = runCmd(ctx, "/bin/launchctl", "remove", label)
	return true
}
