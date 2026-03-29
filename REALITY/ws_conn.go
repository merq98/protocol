package reality

import (
	"context"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"nhooyr.io/websocket"
)

// WSConn wraps a WebSocket connection behind the net.Conn interface.
// This allows the REALITY client to tunnel through a Cloudflare Worker
// relay transparently — upper layers see a normal TCP-like stream.
type WSConn struct {
	ws  *websocket.Conn
	url string

	// Read buffering: WebSocket is message-oriented, net.Conn is a stream.
	readMu sync.Mutex
	reader io.Reader

	// Deadlines (best-effort via context cancellation).
	readDeadline  time.Time
	writeDeadline time.Time
	deadlineMu    sync.Mutex

	localAddr  net.Addr
	remoteAddr net.Addr
}

// DialWS establishes a WebSocket connection to the relay Worker
// and returns a net.Conn. The url should be "wss://relay.example.com"
// or "ws://..." for testing.
func DialWS(ctx context.Context, url string) (net.Conn, error) {
	ws, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		Subprotocols: []string{"binary"},
	})
	if err != nil {
		return nil, fmt.Errorf("ws dial: %w", err)
	}
	// Free plan: messages can be up to 1MB. Set a generous read limit.
	ws.SetReadLimit(1 << 20)

	return &WSConn{
		ws:         ws,
		url:        url,
		localAddr:  wsAddr("ws-local"),
		remoteAddr: wsAddr(url),
	}, nil
}

func (c *WSConn) Read(b []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()

	for {
		if c.reader != nil {
			n, err := c.reader.Read(b)
			if n > 0 || err != io.EOF {
				return n, err
			}
			c.reader = nil
		}

		ctx := c.readContext()
		_, reader, err := c.ws.Reader(ctx)
		if err != nil {
			return 0, err
		}
		c.reader = reader
	}
}

func (c *WSConn) Write(b []byte) (int, error) {
	ctx := c.writeContext()
	err := c.ws.Write(ctx, websocket.MessageBinary, b)
	if err != nil {
		return 0, err
	}
	return len(b), nil
}

func (c *WSConn) Close() error {
	return c.ws.Close(websocket.StatusNormalClosure, "")
}

func (c *WSConn) LocalAddr() net.Addr  { return c.localAddr }
func (c *WSConn) RemoteAddr() net.Addr { return c.remoteAddr }

func (c *WSConn) SetDeadline(t time.Time) error {
	c.deadlineMu.Lock()
	c.readDeadline = t
	c.writeDeadline = t
	c.deadlineMu.Unlock()
	return nil
}

func (c *WSConn) SetReadDeadline(t time.Time) error {
	c.deadlineMu.Lock()
	c.readDeadline = t
	c.deadlineMu.Unlock()
	return nil
}

func (c *WSConn) SetWriteDeadline(t time.Time) error {
	c.deadlineMu.Lock()
	c.writeDeadline = t
	c.deadlineMu.Unlock()
	return nil
}

func (c *WSConn) readContext() context.Context {
	c.deadlineMu.Lock()
	d := c.readDeadline
	c.deadlineMu.Unlock()

	if d.IsZero() {
		return context.Background()
	}
	ctx, cancel := context.WithDeadline(context.Background(), d)
	_ = cancel // GC will collect; caller doesn't hold reference long
	return ctx
}

func (c *WSConn) writeContext() context.Context {
	c.deadlineMu.Lock()
	d := c.writeDeadline
	c.deadlineMu.Unlock()

	if d.IsZero() {
		return context.Background()
	}
	ctx, cancel := context.WithDeadline(context.Background(), d)
	_ = cancel
	return ctx
}

// wsAddr implements net.Addr for WebSocket connections.
type wsAddr string

func (a wsAddr) Network() string { return "ws" }
func (a wsAddr) String() string  { return string(a) }
