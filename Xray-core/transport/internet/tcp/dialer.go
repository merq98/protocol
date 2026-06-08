package tcp

import (
	"context"
	gotls "crypto/tls"
	"os"
	"path/filepath"
	"slices"
	"strings"

	goreality "github.com/xtls/reality"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/reality"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/tls"
)

// Dial dials a new TCP connection to the given destination.
func Dial(ctx context.Context, dest net.Destination, streamSettings *internet.MemoryStreamConfig) (stat.Connection, error) {
	errors.LogInfo(ctx, "dialing TCP to ", dest)
	wsRelayTrace("dial tcp dest=" + dest.String())

	// If REALITY with wsRelay is configured, dial WebSocket instead of raw TCP.
	// v2rayN regenerates config.json and drops unknown REALITY fields, so a
	// sidecar file next to xray.exe is also supported for local client setups.
	var conn net.Conn
	var err error
	if relay := wsRelayFromStreamSettings(streamSettings); relay != "" {
		errors.LogInfo(ctx, "using WS relay: ", relay)
		wsRelayTrace("using relay=" + relay)
		conn, err = goreality.DialWS(ctx, relay)
	} else {
		wsRelayTrace("no relay configured")
		conn, err = internet.DialSystem(ctx, dest, streamSettings.SocketSettings)
	}
	if err != nil {
		return nil, err
	}

	if streamSettings.TcpmaskManager != nil {
		newConn, err := streamSettings.TcpmaskManager.WrapConnClient(conn)
		if err != nil {
			conn.Close()
			return nil, errors.New("mask err").Base(err)
		}
		conn = newConn
	}

	if config := tls.ConfigFromStreamSettings(streamSettings); config != nil {
		mitmServerName := session.MitmServerNameFromContext(ctx)
		mitmAlpn11 := session.MitmAlpn11FromContext(ctx)
		var tlsConfig *gotls.Config
		if tls.IsFromMitm(config.ServerName) {
			tlsConfig = config.GetTLSConfig(tls.WithOverrideName(mitmServerName))
		} else {
			tlsConfig = config.GetTLSConfig(tls.WithDestination(dest))
		}

		isFromMitmVerify := false
		if r, ok := tlsConfig.Rand.(*tls.RandCarrier); ok && len(r.VerifyPeerCertByName) > 0 {
			for i, name := range r.VerifyPeerCertByName {
				if tls.IsFromMitm(name) {
					isFromMitmVerify = true
					r.VerifyPeerCertByName[0], r.VerifyPeerCertByName[i] = r.VerifyPeerCertByName[i], r.VerifyPeerCertByName[0]
					r.VerifyPeerCertByName = r.VerifyPeerCertByName[1:]
					after := mitmServerName
					for {
						if len(after) > 0 {
							r.VerifyPeerCertByName = append(r.VerifyPeerCertByName, after)
						}
						_, after, _ = strings.Cut(after, ".")
						if !strings.Contains(after, ".") {
							break
						}
					}
					slices.Reverse(r.VerifyPeerCertByName)
					break
				}
			}
		}
		isFromMitmAlpn := len(tlsConfig.NextProtos) == 1 && tls.IsFromMitm(tlsConfig.NextProtos[0])
		if isFromMitmAlpn {
			if mitmAlpn11 {
				tlsConfig.NextProtos[0] = "http/1.1"
			} else {
				tlsConfig.NextProtos = []string{"h2", "http/1.1"}
			}
		}
		if fingerprint := tls.GetFingerprint(config.Fingerprint); fingerprint != nil {
			conn = tls.UClient(conn, tlsConfig, fingerprint)
			if len(tlsConfig.NextProtos) == 1 && tlsConfig.NextProtos[0] == "http/1.1" { // allow manually specify
				err = conn.(*tls.UConn).WebsocketHandshakeContext(ctx)
			} else {
				err = conn.(*tls.UConn).HandshakeContext(ctx)
			}
		} else {
			conn = tls.Client(conn, tlsConfig)
			err = conn.(*tls.Conn).HandshakeContext(ctx)
		}
		if err != nil {
			if isFromMitmVerify {
				return nil, errors.New("MITM freedom RAW TLS: failed to verify Domain Fronting certificate from " + mitmServerName).Base(err).AtWarning()
			}
			return nil, err
		}
		negotiatedProtocol := conn.(tls.Interface).NegotiatedProtocol()
		if isFromMitmAlpn && !mitmAlpn11 && negotiatedProtocol != "h2" {
			conn.Close()
			return nil, errors.New("MITM freedom RAW TLS: unexpected Negotiated Protocol (" + negotiatedProtocol + ") with " + mitmServerName).AtWarning()
		}
	} else if config := reality.ConfigFromStreamSettings(streamSettings); config != nil {
		if conn, err = reality.UClient(conn, config, ctx, dest); err != nil {
			return nil, err
		}
	}

	tcpSettings := streamSettings.ProtocolSettings.(*Config)
	if tcpSettings.HeaderSettings != nil {
		headerConfig, err := tcpSettings.HeaderSettings.GetInstance()
		if err != nil {
			return nil, errors.New("failed to get header settings").Base(err).AtError()
		}
		auth, err := internet.CreateConnectionAuthenticator(headerConfig)
		if err != nil {
			return nil, errors.New("failed to create header authenticator").Base(err).AtError()
		}
		conn = auth.Client(conn)
	}
	return stat.Connection(conn), nil
}

func wsRelayFromStreamSettings(streamSettings *internet.MemoryStreamConfig) string {
	if rConfig := reality.ConfigFromStreamSettings(streamSettings); rConfig != nil {
		if relay := strings.TrimSpace(rConfig.WsRelay); relay != "" {
			wsRelayTrace("relay from config")
			return relay
		}
	}
	if relay := strings.TrimSpace(os.Getenv("XRAY_WS_RELAY")); relay != "" {
		wsRelayTrace("relay from env")
		return relay
	}
	for _, path := range wsRelaySidecarPaths() {
		data, err := os.ReadFile(path)
		if err != nil {
			wsRelayTrace("sidecar miss " + path + ": " + err.Error())
			continue
		}
		if relay := strings.TrimSpace(string(data)); relay != "" {
			wsRelayTrace("relay from sidecar " + path)
			return relay
		}
		wsRelayTrace("sidecar empty " + path)
	}
	return ""
}

func wsRelaySidecarPaths() []string {
	paths := []string{"wsrelay.txt"}
	if exePath, err := os.Executable(); err == nil {
		paths = append([]string{filepath.Join(filepath.Dir(exePath), "wsrelay.txt")}, paths...)
	}
	return paths
}

func wsRelayTrace(message string) {
	path := "wsrelay-debug.log"
	if exePath, err := os.Executable(); err == nil {
		path = filepath.Join(filepath.Dir(exePath), "wsrelay-debug.log")
	}
	_ = os.WriteFile(path, []byte(message+"\n"), 0644)
}

func init() {
	common.Must(internet.RegisterTransportDialer(protocolName, Dial))
}
