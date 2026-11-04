// client is the test client of the live macOS smoke test. It talks to the helper's socket and must
// be run from inside the app bundle (the helper checks the caller's path).
//
//	client hello  <socket>
//	client session <socket> <socksPort> <bypassCSV> <readyFile> <releaseFile> stop|crash
//
// "session" starts the tunnel, writes the reply to readyFile, waits until releaseFile exists and
// then either sends "stop" (stop) or just exits without it (crash, like an app crash).
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

type conn struct {
	c  net.Conn
	r  *bufio.Reader
	id int
}

func dial(path string) *conn {
	c, err := net.DialTimeout("unix", path, 5*time.Second)
	if err != nil {
		die("cannot connect to the helper socket: %v", err)
	}
	return &conn{c: c, r: bufio.NewReaderSize(c, 1<<16)}
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "client: "+format+"\n", args...)
	os.Exit(1)
}

// call sends one request and returns the raw reply line plus the decoded object. Events that
// arrive in between are skipped.
func (c *conn) call(req map[string]any) (string, map[string]any) {
	c.id++
	req["id"] = c.id
	b, _ := json.Marshal(req)
	_ = c.c.SetDeadline(time.Now().Add(40 * time.Second))
	if _, err := c.c.Write(append(b, '\n')); err != nil {
		die("write: %v", err)
	}
	for {
		line, err := c.r.ReadString('\n')
		if err != nil {
			die("read: %v", err)
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			die("bad reply %q", line)
		}
		if _, isEvent := m["event"]; isEvent {
			continue
		}
		return strings.TrimSpace(line), m
	}
}

func main() {
	if len(os.Args) < 3 {
		die("usage: client hello <socket> | session <socket> <port> <bypassCSV> <ready> <release> stop|crash")
	}
	switch os.Args[1] {
	case "hello":
		c := dial(os.Args[2])
		line, m := c.call(map[string]any{"cmd": "hello"})
		fmt.Println(line)
		if m["ok"] != true {
			os.Exit(1)
		}
	case "probe":
		// Sends "cleanup" and prints the reply whatever it is (used to check the peer check).
		c := dial(os.Args[2])
		line, _ := c.call(map[string]any{"cmd": "cleanup"})
		fmt.Println(line)
	case "session":
		if len(os.Args) != 8 {
			die("session needs 6 arguments")
		}
		port, err := strconv.Atoi(os.Args[3])
		if err != nil {
			die("bad port")
		}
		var bypass []string
		for _, s := range strings.Split(os.Args[4], ",") {
			if s = strings.TrimSpace(s); s != "" {
				bypass = append(bypass, s)
			}
		}
		c := dial(os.Args[2])
		line, m := c.call(map[string]any{"cmd": "cleanup"})
		if m["ok"] != true {
			die("cleanup failed: %s", line)
		}
		line, m = c.call(map[string]any{"cmd": "start", "socksPort": port, "bypass": bypass})
		if m["ok"] != true {
			_ = os.WriteFile(os.Args[5], []byte("ERROR "+line+"\n"), 0o644)
			die("start failed: %s", line)
		}
		// With the tunnel's 0/1 routes up, the helper must still find the real
		// default route (the app calls this before every upstream reconnect).
		startPhys := m["physicalAddress"]
		rline, rm := c.call(map[string]any{"cmd": "refreshBypass"})
		if rm["ok"] != true || rm["physicalAddress"] != startPhys {
			_ = os.WriteFile(os.Args[5], []byte("ERROR refreshBypass: "+rline+"\n"), 0o644)
			die("refreshBypass failed or changed the physical address: %s (start said %v)", rline, startPhys)
		}
		fmt.Println("refreshed:", rline)
		if err := os.WriteFile(os.Args[5], []byte(line+"\n"), 0o644); err != nil {
			die("ready file: %v", err)
		}
		fmt.Println("started:", line)
		deadline := time.Now().Add(120 * time.Second)
		for {
			if _, err := os.Stat(os.Args[6]); err == nil {
				break
			}
			if time.Now().After(deadline) {
				die("timed out waiting for the release file")
			}
			time.Sleep(100 * time.Millisecond)
		}
		if os.Args[7] == "stop" {
			line, m = c.call(map[string]any{"cmd": "stop"})
			if m["ok"] != true {
				die("stop failed: %s", line)
			}
			fmt.Println("stopped:", line)
		} else {
			fmt.Println("exiting without stop (simulated crash)")
		}
		os.Exit(0) // no graceful close either way
	default:
		die("unknown mode %q", os.Args[1])
	}
}
