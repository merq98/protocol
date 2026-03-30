package reality

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/pires/go-proxyproto"
	utls "github.com/refraction-networking/utls"
)

var GlobalPostHandshakeRecordsLens sync.Map

func DetectPostHandshakeRecordsLens(config *Config) {
	// Build a list of (dest, serverNames) pairs to probe.
	// If a TargetPool is configured, use all targets; otherwise use the single Dest/ServerNames.
	type destSNI struct {
		Dest        string
		ServerNames map[string]bool
	}
	var pairs []destSNI
	if config.Targets != nil && config.Targets.Len() > 0 {
		for _, d := range config.Targets.AllDests() {
			// Collect all SNIs that map to this dest
			sniMap := make(map[string]bool)
			config.Targets.mu.RLock()
			for _, t := range config.Targets.targets {
				if t.Dest == d {
					for sni := range t.ServerNames {
						sniMap[sni] = true
					}
				}
			}
			config.Targets.mu.RUnlock()
			pairs = append(pairs, destSNI{Dest: d, ServerNames: sniMap})
		}
	} else {
		pairs = append(pairs, destSNI{Dest: config.Dest, ServerNames: config.ServerNames})
	}

	for _, pair := range pairs {
		for sni := range pair.ServerNames {
			for alpn := range 3 { // 0, 1, 2
				key := pair.Dest + " " + sni + " " + strconv.Itoa(alpn)
				if _, loaded := GlobalPostHandshakeRecordsLens.LoadOrStore(key, false); !loaded {
					go func() {
						defer func() {
							val, _ := GlobalPostHandshakeRecordsLens.Load(key)
							if _, ok := val.(bool); ok {
								GlobalPostHandshakeRecordsLens.Store(key, []int{})
							}
						}()
						target, err := net.Dial(config.Type, pair.Dest)
						if err != nil {
							return
						}
						if config.Xver == 1 || config.Xver == 2 {
							if _, err = proxyproto.HeaderProxyFromAddrs(config.Xver, target.LocalAddr(), target.RemoteAddr()).WriteTo(target); err != nil {
								return
							}
						}
						detectConn := &PostHandshakeRecordDetectConn{
							Conn: target,
							Key:  key,
						}
						fingerprint := utls.HelloChrome_Auto
						nextProtos := []string{"h2", "http/1.1"}
						if alpn != 2 {
							fingerprint = utls.HelloGolang
						}
						if alpn == 1 {
							nextProtos = []string{"http/1.1"}
						}
						if alpn == 0 {
							nextProtos = nil
						}
						uConn := utls.UClient(detectConn, &utls.Config{
							ServerName: sni, // needs new loopvar behaviour
							NextProtos: nextProtos,
						}, fingerprint)
						if err = uConn.Handshake(); err != nil {
							return
						}
						io.Copy(io.Discard, uConn)
					}()
				}
			}
		}
	} // end for _, pair
}

type PostHandshakeRecordDetectConn struct {
	net.Conn
	Key     string
	CcsSent bool
}

func (c *PostHandshakeRecordDetectConn) Write(b []byte) (n int, err error) {
	if len(b) >= 3 && bytes.Equal(b[:3], []byte{20, 3, 3}) {
		c.CcsSent = true
	}
	return c.Conn.Write(b)
}

func (c *PostHandshakeRecordDetectConn) Read(b []byte) (n int, err error) {
	if !c.CcsSent {
		return c.Conn.Read(b)
	}
	c.Conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	data, _ := io.ReadAll(c.Conn)
	var postHandshakeRecordsLens []int
	for {
		if len(data) >= 5 && bytes.Equal(data[:3], []byte{23, 3, 3}) {
			length := int(binary.BigEndian.Uint16(data[3:5])) + 5
			postHandshakeRecordsLens = append(postHandshakeRecordsLens, length)
			data = data[length:]
		} else {
			break
		}
	}
	GlobalPostHandshakeRecordsLens.Store(c.Key, postHandshakeRecordsLens)
	return 0, io.EOF
}
