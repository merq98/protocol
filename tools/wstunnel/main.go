// wstunnel — local TCP ↔ WebSocket relay for tunneling REALITY through Cloudflare Workers.
//
// Usage:
//   wstunnel -listen 127.0.0.1:1443 -remote wss://reality-relay.YOUR.workers.dev
//
// Each incoming TCP connection opens a new WebSocket to the remote,
// and bytes are relayed bidirectionally. The Cloudflare Worker then
// forwards the WebSocket data as raw TCP to the REALITY server.
package main

import (
	"context"
	"flag"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	"nhooyr.io/websocket"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:1443", "local TCP listen address")
	remote := flag.String("remote", "", "WebSocket URL (wss://reality-relay.xxx.workers.dev)")
	flag.Parse()

	if *remote == "" {
		log.Fatal("ERROR: -remote is required\nUsage: wstunnel -listen 127.0.0.1:1443 -remote wss://your-worker.workers.dev")
	}

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Printf("Listening on %s → %s", *listen, *remote)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go handleConn(conn, *remote)
	}
}

func handleConn(tcpConn net.Conn, wsURL string) {
	defer tcpConn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	wsConn, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{
		HTTPHeader: http.Header{
			"User-Agent": []string{"Mozilla/5.0"},
		},
	})
	cancel()
	if err != nil {
		log.Printf("ws dial: %v", err)
		return
	}
	defer wsConn.CloseNow()

	// Remove default read limit (64KB) — REALITY packets can be larger
	wsConn.SetReadLimit(-1)

	ctx, cancel = context.WithCancel(context.Background())
	defer cancel()

	var wg sync.WaitGroup
	wg.Add(2)

	// TCP → WebSocket
	go func() {
		defer wg.Done()
		defer cancel()
		buf := make([]byte, 32*1024)
		for {
			n, err := tcpConn.Read(buf)
			if n > 0 {
				if wErr := wsConn.Write(ctx, websocket.MessageBinary, buf[:n]); wErr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()

	// WebSocket → TCP
	go func() {
		defer wg.Done()
		defer cancel()
		for {
			_, data, err := wsConn.Read(ctx)
			if err != nil {
				return
			}
			if _, wErr := tcpConn.Write(data); wErr != nil {
				return
			}
		}
	}()

	wg.Wait()
}
