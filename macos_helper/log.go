package main

import (
	"fmt"
	"os"
	"sync"
	"time"
)

const maxLogSize = 1 << 20

// Logger writes a small capped log: rotates at 1 MB and keeps one old file.
type Logger struct {
	mu   sync.Mutex
	path string
	f    *os.File
	size int64
}

func newLogger(path string) *Logger {
	l := &Logger{path: path}
	l.open()
	return l
}

func (l *Logger) open() {
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		l.f = nil
		return
	}
	l.f = f
	l.size = 0
	if fi, err := f.Stat(); err == nil {
		l.size = fi.Size()
	}
}

func (l *Logger) Printf(format string, args ...any) {
	if l == nil {
		return
	}
	line := time.Now().Format("2006-01-02 15:04:05 ") + fmt.Sprintf(format, args...) + "\n"
	if len(line) > 2048 {
		line = line[:2047] + "\n"
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		l.open()
		if l.f == nil {
			return
		}
	}
	if l.size+int64(len(line)) > maxLogSize {
		_ = l.f.Close()
		l.f = nil
		_ = os.Remove(l.path + ".1")
		_ = os.Rename(l.path, l.path+".1")
		l.open()
		if l.f == nil {
			return
		}
	}
	n, _ := l.f.WriteString(line)
	l.size += int64(n)
}

func (l *Logger) Close() {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f != nil {
		_ = l.f.Close()
		l.f = nil
	}
}
