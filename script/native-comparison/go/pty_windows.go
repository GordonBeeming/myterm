package main

import (
	"context"
	"fmt"
	"github.com/UserExistsError/conpty"
	"golang.org/x/sys/windows"
	"strings"
	"syscall"
)

type windowsPTY struct{ p *conpty.ConPty }

func startPTY(args []string) (sessionPTY, error) {
	escaped := make([]string, len(args))
	for i, a := range args {
		escaped[i] = syscall.EscapeArg(a)
	}
	p, e := conpty.Start(strings.Join(escaped, " "), conpty.ConPtyDimensions(80, 24))
	if e != nil {
		return nil, e
	}
	return &windowsPTY{p}, nil
}
func (p *windowsPTY) Read(b []byte) (int, error)  { return p.p.Read(b) }
func (p *windowsPTY) Write(b []byte) (int, error) { return p.p.Write(b) }
func (p *windowsPTY) Close() error                { return p.p.Close() }
func (p *windowsPTY) Resize(w, h int) error       { return p.p.Resize(w, h) }
func (p *windowsPTY) Wait() error {
	code, e := p.p.Wait(context.Background())
	if e == nil && code != 0 {
		return fmt.Errorf("child exit %d", code)
	}
	return e
}
func (p *windowsPTY) PID() int { return p.p.Pid() }
func (p *windowsPTY) Kill() error {
	h, e := windows.OpenProcess(windows.PROCESS_TERMINATE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(p.PID()))
	if e != nil {
		return e
	}
	defer windows.CloseHandle(h)
	var code uint32
	if e = windows.GetExitCodeProcess(h, &code); e != nil {
		return e
	}
	if code != 259 {
		return nil
	}
	return windows.TerminateProcess(h, 1)
}
