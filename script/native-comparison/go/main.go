// Throwaway candidate probe. It is not a MyTerm server or protocol implementation.
package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	uv "github.com/charmbracelet/ultraviolet"
	ansi "github.com/charmbracelet/x/ansi"
	"image/color"
	"io"
	"net"
	"os"
	"sync"
	"time"

	vt "github.com/charmbracelet/x/vt"
)

type event struct {
	Data       []byte `json:"data"`
	Resize     []int  `json:"resize"`
	Checkpoint bool   `json:"checkpoint"`
}
type trace struct {
	Name   string  `json:"name"`
	Events []event `json:"events"`
}
type snapshot struct {
	Styles  [][]string `json:"styles"`
	Cells   [][]string `json:"cells"`
	Cursor  []int      `json:"cursor"`
	Alt     bool       `json:"alt"`
	Replies []byte     `json:"replies"`
	History int        `json:"history"`
}
type request struct {
	Op   string `json:"op"`
	Data []byte `json:"data"`
	Cols int    `json:"cols"`
	Rows int    `json:"rows"`
}

func colorCode(c color.Color) string {
	switch v := c.(type) {
	case nil:
		return "default"
	case ansi.BasicColor:
		return fmt.Sprintf("idx:%d", v)
	case ansi.IndexedColor:
		return fmt.Sprintf("idx:%d", v)
	default:
		r, g, b, _ := c.RGBA()
		return fmt.Sprintf("rgb:%d,%d,%d", r>>8, g>>8, b>>8)
	}
}

func traces() error {
	var input []trace
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		return err
	}
	output := make(map[string]any)
	for _, t := range input {
		em := vt.NewEmulator(20, 6)
		em.SetScrollbackSize(40)
		var replies bytes.Buffer
		var mu sync.Mutex
		done := make(chan struct{})
		go func() {
			defer close(done)
			b := make([]byte, 4096)
			for {
				n, err := em.Read(b)
				if n > 0 {
					mu.Lock()
					replies.Write(b[:n])
					mu.Unlock()
				}
				if err != nil {
					return
				}
			}
		}()
		snaps := []snapshot{}
		renders := []string{}
		for _, e := range t.Events {
			if len(e.Resize) == 2 {
				em.Resize(e.Resize[0], e.Resize[1])
			}
			if _, err := em.Write(e.Data); err != nil {
				return err
			}
			cells := make([][]string, em.Height())
			styles := make([][]string, em.Height())
			for y := range cells {
				cells[y] = make([]string, em.Width())
				styles[y] = make([]string, em.Width())
				for x := range cells[y] {
					c := em.CellAt(x, y)
					if c != nil {
						styles[y][x] = fmt.Sprintf("%s|%s|%t%t%t%t", colorCode(c.Style.Fg), colorCode(c.Style.Bg), c.Style.Attrs&uv.AttrBold != 0, c.Style.Attrs&uv.AttrItalic != 0, c.Style.Underline != uv.UnderlineNone, c.Style.Attrs&uv.AttrReverse != 0)
					} else {
						styles[y][x] = "default|default|falsefalsefalsefalse"
					}
					if c != nil && c.Content != " " {
						cells[y][x] = c.Content
					}
				}
			}
			// io.Pipe writes complete when the reader consumes each response; lock captures it.
			mu.Lock()
			reply := append([]byte{}, replies.Bytes()...)
			mu.Unlock()
			p := em.CursorPosition()
			snaps = append(snaps, snapshot{Styles: styles, Cells: cells, Cursor: []int{p.X, p.Y}, Alt: em.IsAltScreen(), Replies: reply, History: em.ScrollbackLen()})
			if e.Checkpoint {
				renders = append(renders, em.Render())
			}
		}
		closer, ok := em.InputPipe().(io.Closer)
		if !ok {
			return fmt.Errorf("terminal input pipe is not closeable")
		}
		if err := closer.Close(); err != nil {
			return err
		}
		<-done
		if err := em.Close(); err != nil {
			return err
		}
		mu.Lock()
		finalReplies := append([]byte{}, replies.Bytes()...)
		mu.Unlock()
		output[t.Name] = map[string]any{"snapshots": snaps, "finalReplies": finalReplies, "screenRenders": renders, "replyImplementation": true, "checkpoint": "No full parser/checkpoint export API exercised; Render is a visible-screen rendering only", "images": "No image retention API exercised"}
	}
	return json.NewEncoder(os.Stdout).Encode(output)
}

type sessionPTY interface {
	io.ReadWriteCloser
	Resize(int, int) error
	Wait() error
	PID() int
	Kill() error
}

func session(args []string) error {
	p, err := startPTY(args)
	if err != nil {
		return err
	}
	defer func() {
		if err := p.Kill(); err != nil {
			fmt.Fprintln(os.Stderr, "cleanup kill:", err)
		}
		if err := p.Close(); err != nil {
			fmt.Fprintln(os.Stderr, "cleanup close:", err)
		}
	}()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer listener.Close()
	// A random per-run capability confines this unauthenticated experiment endpoint.
	token := os.Getenv("MYTERM_PROBE_TOKEN")
	if len(token) < 32 {
		return fmt.Errorf("probe token missing")
	}
	var mu sync.Mutex
	var output bytes.Buffer
	var readErr error
	go func() {
		b := make([]byte, 8192)
		for {
			n, e := p.Read(b)
			mu.Lock()
			if output.Len()+n > 1024*1024 {
				readErr = fmt.Errorf("output bound exceeded")
				mu.Unlock()
				return
			}
			output.Write(b[:n])
			if e != nil {
				readErr = e
			}
			mu.Unlock()
			if e != nil {
				return
			}
		}
	}()
	exit := make(chan error, 1)
	go func() { exit <- p.Wait() }()
	watchdog := time.AfterFunc(60*time.Second, func() {
		fmt.Fprintln(os.Stderr, "session watchdog expired")
		if err := listener.Close(); err != nil {
			fmt.Fprintln(os.Stderr, "watchdog listener close:", err)
		}
	})
	defer watchdog.Stop()
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{"address": listener.Addr().String(), "pid": p.PID()}); err != nil {
		return err
	}
	for {
		c, e := listener.Accept()
		if e != nil {
			return e
		}
		if e = c.SetDeadline(time.Now().Add(5 * time.Second)); e != nil {
			c.Close()
			return e
		}
		mu.Lock()
		outputLengthAtAccept := output.Len()
		mu.Unlock()
		var r struct {
			Token string `json:"token"`
			request
		}
		e = json.NewDecoder(io.LimitReader(c, 65536)).Decode(&r)
		if e != nil || r.Token != token {
			sendErr := json.NewEncoder(c).Encode(map[string]string{"error": "invalid token"})
			c.Close()
			if sendErr != nil {
				return sendErr
			}
			continue
		}
		stopping := false
		if e == nil {
			switch r.Op {
			case "write":
				_, e = p.Write(r.Data)
			case "resize":
				if r.Cols < 1 || r.Rows < 1 || r.Cols > 500 || r.Rows > 200 {
					e = fmt.Errorf("invalid geometry")
				} else {
					e = p.Resize(r.Cols, r.Rows)
				}
			case "read":
			case "terminate":
				stopping = true
				e = p.Kill()
				select {
				case <-exit:
				case <-time.After(5 * time.Second):
					e = fmt.Errorf("terminated child wait timeout")
				}
			case "stop":
				stopping = true
				select {
				case e = <-exit:
				case <-time.After(5 * time.Second):
					e = fmt.Errorf("child exit timeout")
				}
			default:
				e = fmt.Errorf("unknown operation")
			}
		}
		mu.Lock()
		data := base64.StdEncoding.EncodeToString(output.Bytes())
		readerStatus := ""
		if readErr != nil {
			readerStatus = readErr.Error()
		}
		mu.Unlock()
		response := map[string]any{"data": data, "pid": p.PID(), "readerStatus": readerStatus, "error": "", "outputLengthAtAccept": outputLengthAtAccept}
		if e != nil {
			response["error"] = e.Error()
		}
		sendErr := json.NewEncoder(c).Encode(response)
		c.Close()
		if sendErr != nil {
			return sendErr
		}
		if stopping {
			return e
		}
	}
}
func main() {
	var err error
	if len(os.Args) > 2 && os.Args[1] == "--session" {
		err = session(os.Args[2:])
	} else if len(os.Args) == 1 {
		err = traces()
	} else {
		err = fmt.Errorf("usage: probe [--session shell args...]")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
