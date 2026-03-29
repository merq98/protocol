// Cloudflare Worker: WebSocket ↔ TCP relay for REALITY protocol.
// Accepts incoming WebSocket connections, opens a TCP socket to the
// origin REALITY server, and pipes bytes transparently in both
// directions. Cloudflare never sees the inner TLS content.
//
// Free plan limits: 100k requests/day, 10ms CPU per request.
// WebSocket messages after the upgrade handshake are NOT counted
// against the request limit, so long-lived tunnels are fine.

import { connect } from "cloudflare:sockets";

export default {
  async fetch(request, env) {
    const upgradeHeader = request.headers.get("Upgrade");
    if (!upgradeHeader || upgradeHeader.toLowerCase() !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }

    // The origin address is configured via environment variable.
    // Format: "host:port" (e.g. "198.51.100.1:443").
    const origin = env.ORIGIN;
    if (!origin) {
      return new Response("ORIGIN not configured", { status: 500 });
    }

    const [wsClient, wsServer] = Object.values(new WebSocketPair());

    wsServer.accept();

    // Open a TCP socket to the REALITY server.
    const tcpSocket = connect(origin);
    const writer = tcpSocket.writable.getWriter();
    const reader = tcpSocket.readable.getReader();

    // WS → TCP: forward incoming WebSocket messages to the TCP socket.
    wsServer.addEventListener("message", async (event) => {
      try {
        const data =
          event.data instanceof ArrayBuffer
            ? new Uint8Array(event.data)
            : new TextEncoder().encode(event.data);
        await writer.write(data);
      } catch {
        wsServer.close(1011, "tcp write error");
      }
    });

    wsServer.addEventListener("close", async () => {
      try {
        await writer.close();
      } catch {
        // already closed
      }
    });

    wsServer.addEventListener("error", async () => {
      try {
        await writer.close();
      } catch {
        // already closed
      }
    });

    // TCP → WS: forward TCP data back to the WebSocket client.
    (async () => {
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          wsServer.send(value);
        }
        wsServer.close(1000, "tcp closed");
      } catch {
        try {
          wsServer.close(1011, "tcp read error");
        } catch {
          // ws already closed
        }
      }
    })();

    return new Response(null, { status: 101, webSocket: wsClient });
  },
};
