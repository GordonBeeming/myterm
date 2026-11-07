//go:build !windows

package main

import (
	"errors"
	"github.com/creack/pty"
	"os"
	"os/exec"
)

type unixPTY struct {
	file *os.File
	cmd  *exec.Cmd
}

func startPTY(args []string) (sessionPTY, error) {
	c := exec.Command(args[0], args[1:]...)
	c.Env = append(os.Environ(), "TERM=xterm-256color")
	f, e := pty.StartWithSize(c, &pty.Winsize{Cols: 80, Rows: 24})
	if e != nil {
		return nil, e
	}
	return &unixPTY{f, c}, nil
}
func (p *unixPTY) Read(b []byte) (int, error)  { return p.file.Read(b) }
func (p *unixPTY) Write(b []byte) (int, error) { return p.file.Write(b) }
func (p *unixPTY) Close() error                { return p.file.Close() }
func (p *unixPTY) Resize(w, h int) error {
	return pty.Setsize(p.file, &pty.Winsize{Cols: uint16(w), Rows: uint16(h)})
}
func (p *unixPTY) Wait() error { return p.cmd.Wait() }
func (p *unixPTY) PID() int    { return p.cmd.Process.Pid }
func (p *unixPTY) Kill() error {
	e := p.cmd.Process.Kill()
	if errors.Is(e, os.ErrProcessDone) {
		return nil
	}
	return e
}
