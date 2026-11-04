package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

const (
	label     = "com.foxyvpn.helper"
	dnsServer = "198.18.0.2"
)

// Paths holds every file the helper touches, so tests can point them at a temp folder.
type Paths struct {
	Dir       string
	Config    string
	State     string
	Log       string
	Tun2socks string
	Socket    string
	Plist     string
	Binary    string
}

func defaultPaths() Paths {
	dir := "/Library/Application Support/FoxyVPN"
	return Paths{
		Dir:       dir,
		Config:    dir + "/helper.json",
		State:     dir + "/state.json",
		Log:       dir + "/helper.log",
		Tun2socks: dir + "/tun2socks",
		Socket:    "/var/run/" + label + ".sock",
		Plist:     "/Library/LaunchDaemons/" + label + ".plist",
		Binary:    "/Library/PrivilegedHelperTools/" + label,
	}
}

// Config is helper.json: where the app lives and which helper version was installed.
type Config struct {
	AppPath string `json:"appPath"`
	Version string `json:"version"`
}

// validAppPath accepts only an absolute path to a ".app" folder.
func validAppPath(p string) error {
	if !strings.HasPrefix(p, "/") {
		return errors.New("the app path must be absolute")
	}
	if strings.ContainsAny(p, "\x00\n\r") {
		return errors.New("the app path contains invalid characters")
	}
	if !strings.HasSuffix(p, ".app") {
		return errors.New("the app path must end in .app")
	}
	return nil
}

func loadConfig(p Paths) (Config, error) {
	var c Config
	b, err := os.ReadFile(p.Config)
	if err != nil {
		return c, err
	}
	if len(b) > 64*1024 {
		return c, errors.New("helper.json is too large")
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return c, fmt.Errorf("helper.json is damaged: %w", err)
	}
	if err := validAppPath(c.AppPath); err != nil {
		return Config{}, err
	}
	return c, nil
}

// writeConfig is used by `foxyvpn-helper --write-config <appPath>` so install.sh never has to
// JSON-escape a path in shell.
func writeConfig(p Paths, appPath string) error {
	appPath = strings.TrimRight(appPath, "/")
	if err := validAppPath(appPath); err != nil {
		return err
	}
	b, err := json.Marshal(Config{AppPath: appPath, Version: HelperVersion})
	if err != nil {
		return err
	}
	return writeFileAtomic(p.Config, append(b, '\n'), 0o644)
}

// writeFileAtomic writes next to the target and renames, so a crash never leaves a half file.
func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	_ = os.Chmod(tmp, mode)
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
