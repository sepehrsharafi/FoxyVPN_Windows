// foxyvpn-helper is the privileged helper of FoxyVPN for macOS. It runs as a root LaunchDaemon,
// listens on a unix socket and, on request of the FoxyVPN app only, brings a utun tunnel (via
// tun2socks), routes and DNS up and down. Standard library only.
package main

import (
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	paths := defaultPaths()
	args := os.Args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "--version":
			fmt.Println(HelperVersion)
			return
		case "--write-config":
			if len(args) != 2 {
				fmt.Fprintln(os.Stderr, "usage: foxyvpn-helper --write-config <appPath>")
				os.Exit(64)
			}
			if err := writeConfig(paths, args[1]); err != nil {
				fmt.Fprintln(os.Stderr, "could not write helper.json:", err)
				os.Exit(1)
			}
			return
		case "--restore":
			// Used by uninstall.sh when the daemon is not running: undo DNS/routes from state.json.
			log := newLogger(paths.Log)
			newManager(paths, realPlatform(), log).StopAll()
			return
		}
	}
	os.Exit(runDaemon(paths))
}

func runDaemon(paths Paths) int {
	log := newLogger(paths.Log)
	defer log.Close()
	log.Printf("foxyvpn-helper %s starting", HelperVersion)
	mgr := newManager(paths, realPlatform(), log)

	// Undo anything a crash or reboot left behind, and leave if the app is gone.
	func() {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("startup cleanup panic: %v", r)
			}
		}()
		mgr.StopAll()
	}()
	if safeSelfRemove(paths, mgr, log) {
		return 0
	}

	_ = os.Remove(paths.Socket)
	l, err := net.Listen("unix", paths.Socket)
	if err != nil {
		log.Printf("cannot listen on %s: %v", paths.Socket, err)
		return 1
	}
	_ = os.Chmod(paths.Socket, 0o666)
	srv := newServer(paths, mgr, log, peerExeViaPS)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("accept loop panic: %v", r)
			}
		}()
		srv.Serve(l)
	}()

	exit := make(chan int, 1)
	go func() {
		defer func() { _ = recover() }()
		t := time.NewTicker(6 * time.Hour)
		defer t.Stop()
		for range t.C {
			if safeSelfRemove(paths, mgr, log) {
				exit <- 0
				return
			}
		}
	}()

	sig := make(chan os.Signal, 2)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	code := 0
	select {
	case s := <-sig:
		log.Printf("received %v, shutting down", s)
	case code = <-exit:
	}
	_ = l.Close()
	mgr.StopAll()
	_ = os.Remove(paths.Socket)
	return code
}

func safeSelfRemove(paths Paths, mgr *Manager, log *Logger) (done bool) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("self-removal check panic: %v", r)
			done = false
		}
	}()
	return checkSelfRemove(paths, mgr, log)
}
