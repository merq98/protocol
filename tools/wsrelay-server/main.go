// wsrelay-server — self-hosted WebSocket to TCP relay for REALITY clients.
//
// Run behind Caddy/nginx TLS termination on VPS-2. Each WebSocket connection
// opens one TCP session to the origin REALITY server and relays bytes
// transparently in both directions.
//
// Usage:
//   wsrelay-server -listen 127.0.0.1:10080 -origin 37.220.83.19:443
package main

import (
	"context"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"nhooyr.io/websocket"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:10080", "HTTP listen address")
	origin := flag.String("origin", "", "TCP origin host:port (e.g. 37.220.83.19:443)")
	path := flag.String("path", "/ws", "WebSocket path")
	flag.Parse()

	if strings.TrimSpace(*origin) == "" {
		log.Fatal("ERROR: -origin is required\nUsage: wsrelay-server -listen 127.0.0.1:10080 -origin 37.220.83.19:443")
	}

	normalizedPath := *path
	if !strings.HasPrefix(normalizedPath, "/") {
		normalizedPath = "/" + normalizedPath
	}

	mux := http.NewServeMux()
	mux.HandleFunc(normalizedPath, func(w http.ResponseWriter, r *http.Request) {
		handleWebSocket(w, r, *origin)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == normalizedPath {
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("wsrelay-server: use WebSocket on " + normalizedPath + "\n"))
	})

	log.Printf("Listening on http://%s%s -> tcp://%s", *listen, normalizedPath, *origin)
	if err := http.ListenAndServe(*listen, mux); err != nil {
		log.Fatalf("listen: %v", err)
	}
}

func handleWebSocket(w http.ResponseWriter, r *http.Request, origin string) {
	wsConn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		Subprotocols: []string{"binary"},
	})
	if err != nil {
		log.Printf("websocket accept: %v", err)
		return
	}
	defer wsConn.Close(websocket.StatusNormalClosure, "")

	wsConn.SetReadLimit(-1)

	dialer := net.Dialer{Timeout: 15 * time.Second}
	tcpConn, err := dialer.Dial("tcp", origin)
	if err != nil {
		log.Printf("tcp dial %s: %v", origin, err)
		_ = wsConn.Close(websocket.StatusTryAgainLater, "origin unreachable")
		return
	}
	defer tcpConn.Close()

	log.Printf("relay opened: %s -> %s", r.RemoteAddr, origin)

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		defer cancel()
		buf := make([]byte, 32*1024)
		for {
			n, readErr := tcpConn.Read(buf)
			if n > 0 {
				if writeErr := wsConn.Write(ctx, websocket.MessageBinary, buf[:n]); writeErr != nil {
					return
				}
			}
			if readErr != nil {
				if readErr != io.EOF {
					log.Printf("tcp read: %v", readErr)
				}
				return
			}
		}
	}()

	go func() {
		defer wg.Done()
		defer cancel()
		for {
			_, data, readErr := wsConn.Read(ctx)
			if readErr != nil {
				if readErr != context.Canceled {
					code := websocket.CloseStatus(readErr)
					if code != websocket.StatusNormalClosure && code != websocket.StatusGoingAway {
						log.Printf("ws read: %v", readErr)
					}
				}
				return
			}
			if len(data) == 0 {
				continue
			}
			if _, writeErr := tcpConn.Write(data); writeErr != nil {
				log.Printf("tcp write: %v", writeErr)
				return
			}
		}
	}()

	wg.Wait()
	log.Printf("relay closed: %s -> %s", r.RemoteAddr, origin)
}
