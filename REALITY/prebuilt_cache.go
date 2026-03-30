package reality

import (
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"slices"
	"sync"
	"time"

	utls "github.com/refraction-networking/utls"
)

// PrebuiltResponse holds a cached TLS handshake response from a target.
// It contains enough data to instantly reply to non-authenticated probers
// without connecting to the real target, eliminating the RTT doubling that
// DPI can detect.
type PrebuiltResponse struct {
	// Raw TLS records: ServerHello + CCS + Encrypted Extensions + Certificate
	// + CertificateVerify + Finished (+ optional NewSessionTicket)
	RawRecords []byte

	// Parsed Server Hello message
	Hello *serverHelloMsg

	// Lengths of each handshake record type (same indexing as types[]):
	// [0]=ServerHello, [1]=CCS, [2]=EncExt, [3]=Cert, [4]=CertVerify, [5]=Finished, [6]=NST
	HandshakeLens [7]int

	// When this entry was captured
	CapturedAt time.Time
}

// PrebuiltCache stores pre-captured TLS handshake responses from targets,
// keyed by "dest:port sni". Entries are periodically refreshed.
type PrebuiltCache struct {
	mu      sync.RWMutex
	entries map[string]*PrebuiltResponse

	// RefreshInterval controls how often cached responses are refreshed.
	// Default: 10 minutes.
	RefreshInterval time.Duration

	// MaxAge is the maximum age of a cached response before it's considered stale.
	// Default: 30 minutes.
	MaxAge time.Duration

	stopCh chan struct{}
}

type prebuiltPair struct {
	Dest string
	SNI  string
}

const minPrebuiltRefreshDelay = 5 * time.Second

// NewPrebuiltCache creates a new cache with the given refresh interval.
func NewPrebuiltCache(refreshInterval, maxAge time.Duration) *PrebuiltCache {
	if refreshInterval <= 0 {
		refreshInterval = 10 * time.Minute
	}
	if maxAge <= 0 {
		maxAge = 30 * time.Minute
	}
	return &PrebuiltCache{
		entries:         make(map[string]*PrebuiltResponse),
		RefreshInterval: refreshInterval,
		MaxAge:          maxAge,
		stopCh:          make(chan struct{}),
	}
}

// cacheKey builds a lookup key from dest and SNI.
func cacheKey(dest, sni string) string {
	return dest + " " + sni
}

// Get returns a cached response if it exists and is not stale.
func (pc *PrebuiltCache) Get(dest, sni string) *PrebuiltResponse {
	pc.mu.RLock()
	defer pc.mu.RUnlock()
	resp, ok := pc.entries[cacheKey(dest, sni)]
	if !ok {
		return nil
	}
	if time.Since(resp.CapturedAt) > pc.MaxAge {
		return nil
	}
	return resp
}

// Store saves a captured response.
func (pc *PrebuiltCache) Store(dest, sni string, resp *PrebuiltResponse) {
	pc.mu.Lock()
	defer pc.mu.Unlock()
	pc.entries[cacheKey(dest, sni)] = resp
}

// Warm probes a target and captures its TLS handshake response.
// This performs a real TLS handshake to the target, captures the raw
// server-to-client records, then stores the result.
func (pc *PrebuiltCache) Warm(networkType, dest, sni string, show bool) error {
	resp, err := captureTargetHandshake(networkType, dest, sni, show)
	if err != nil {
		return err
	}
	pc.Store(dest, sni, resp)
	return nil
}

// WarmAll probes all targets from a config (both single and pool targets).
func (pc *PrebuiltCache) WarmAll(config *Config) {
	pairs := collectPrebuiltPairs(config)

	var wg sync.WaitGroup
	for _, p := range pairs {
		wg.Add(1)
		go func(dest, sni string) {
			defer wg.Done()
			if err := pc.Warm(config.Type, dest, sni, config.Show); err != nil {
				if config.Show {
					fmt.Printf("REALITY prebuilt: failed to warm %v/%v: %v\n", dest, sni, err)
				}
			} else if config.Show {
				fmt.Printf("REALITY prebuilt: warmed %v/%v\n", dest, sni)
			}
		}(p.Dest, p.SNI)
	}
	wg.Wait()
}

// StartRefresh begins a background goroutine that periodically refreshes
// cached entries in a staggered order to avoid periodic outbound bursts.
func (pc *PrebuiltCache) StartRefresh(config *Config) {
	go func() {
		for {
			pairs := collectPrebuiltPairs(config)
			if len(pairs) == 0 {
				if !pc.waitForRefresh(pc.jitteredRefreshDelay(pc.RefreshInterval)) {
					return
				}
				continue
			}

			rand.Shuffle(len(pairs), func(i, j int) {
				pairs[i], pairs[j] = pairs[j], pairs[i]
			})

			baseDelay := pc.RefreshInterval / time.Duration(len(pairs))
			if baseDelay < minPrebuiltRefreshDelay {
				baseDelay = minPrebuiltRefreshDelay
			}

			for _, pair := range pairs {
				if !pc.waitForRefresh(pc.jitteredRefreshDelay(baseDelay)) {
					return
				}
				if err := pc.Warm(config.Type, pair.Dest, pair.SNI, config.Show); err != nil {
					if config.Show {
						fmt.Printf("REALITY prebuilt: failed to refresh %v/%v: %v\n", pair.Dest, pair.SNI, err)
					}
				} else if config.Show {
					fmt.Printf("REALITY prebuilt: refreshed %v/%v\n", pair.Dest, pair.SNI)
				}
			}
		}
	}()
}

// Stop halts the background refresh.
func (pc *PrebuiltCache) Stop() {
	select {
	case <-pc.stopCh:
	default:
		close(pc.stopCh)
	}
}

func collectPrebuiltPairs(config *Config) []prebuiltPair {
	unique := make(map[string]prebuiltPair)

	if config.Targets != nil && config.Targets.Len() > 0 {
		config.Targets.mu.RLock()
		for _, t := range config.Targets.targets {
			for sni := range t.ServerNames {
				pair := prebuiltPair{Dest: t.Dest, SNI: sni}
				unique[cacheKey(pair.Dest, pair.SNI)] = pair
			}
		}
		config.Targets.mu.RUnlock()
	} else if config.Dest != "" {
		for sni := range config.ServerNames {
			pair := prebuiltPair{Dest: config.Dest, SNI: sni}
			unique[cacheKey(pair.Dest, pair.SNI)] = pair
		}
	}

	pairs := make([]prebuiltPair, 0, len(unique))
	for _, pair := range unique {
		pairs = append(pairs, pair)
	}
	slices.SortFunc(pairs, func(a, b prebuiltPair) int {
		if a.Dest == b.Dest {
			return compareStrings(a.SNI, b.SNI)
		}
		return compareStrings(a.Dest, b.Dest)
	})
	return pairs
}

func (pc *PrebuiltCache) waitForRefresh(delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()

	select {
	case <-timer.C:
		return true
	case <-pc.stopCh:
		return false
	}
}

func (pc *PrebuiltCache) jitteredRefreshDelay(base time.Duration) time.Duration {
	if base <= 0 {
		base = minPrebuiltRefreshDelay
	}
	spread := time.Duration(float64(base) * 0.35)
	if spread < time.Second {
		spread = time.Second
	}
	delay := base + time.Duration((2*rand.Float64()-1)*float64(spread))
	if delay < minPrebuiltRefreshDelay {
		return minPrebuiltRefreshDelay
	}
	return delay
}

func compareStrings(a, b string) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

// captureTargetHandshake connects to a target and captures the raw TLS
// server-to-client handshake records.
func captureTargetHandshake(networkType, dest, sni string, show bool) (*PrebuiltResponse, error) {
	conn, err := net.DialTimeout(networkType, dest, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", dest, err)
	}

	// Use a capture wrapper to read raw bytes from the target
	capture := &captureConn{Conn: conn}

	uConn := utls.UClient(capture, &utls.Config{
		ServerName:         sni,
		InsecureSkipVerify: true,
		NextProtos:         []string{"h2", "http/1.1"},
	}, utls.HelloChrome_Auto)

	uConn.SetDeadline(time.Now().Add(15 * time.Second))
	if err := uConn.Handshake(); err != nil {
		conn.Close()
		return nil, fmt.Errorf("handshake with %s/%s: %w", dest, sni, err)
	}

	// Read any post-handshake data (NewSessionTicket, etc.)
	postBuf := make([]byte, 8192)
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	io.ReadFull(conn, postBuf) // ignore error — we just want whatever is available
	conn.Close()

	rawRecords := capture.Captured()
	if len(rawRecords) == 0 {
		return nil, fmt.Errorf("no records captured from %s/%s", dest, sni)
	}

	resp := &PrebuiltResponse{
		RawRecords: rawRecords,
		CapturedAt: time.Now(),
	}

	// Parse raw records to extract handshake lengths and Server Hello
	if err := resp.parseRecords(show); err != nil {
		return nil, err
	}

	return resp, nil
}

// parseRecords walks the raw TLS records to extract handshake lengths
// and parse the Server Hello message.
func (pr *PrebuiltResponse) parseRecords(show bool) error {
	data := pr.RawRecords
	recordIdx := 0

	for len(data) > recordHeaderLen && recordIdx < 7 {
		// Each TLS record: type(1) + version(2) + length(2) + payload
		recType := data[0]
		recLen := int(data[3])<<8 | int(data[4])
		totalLen := recordHeaderLen + recLen

		if totalLen > len(data) {
			break
		}

		switch recordIdx {
		case 0: // Server Hello
			if recType != byte(recordTypeHandshake) || data[5] != typeServerHello {
				return fmt.Errorf("expected ServerHello, got type=%d", recType)
			}
			pr.Hello = new(serverHelloMsg)
			if !pr.Hello.unmarshal(data[recordHeaderLen:totalLen]) {
				return fmt.Errorf("failed to unmarshal ServerHello")
			}
			if pr.Hello.vers != VersionTLS12 || pr.Hello.supportedVersion != VersionTLS13 {
				return fmt.Errorf("target not TLS 1.3 (vers=%x, supported=%x)", pr.Hello.vers, pr.Hello.supportedVersion)
			}
		case 1: // Change Cipher Spec
			if recType != byte(recordTypeChangeCipherSpec) {
				return fmt.Errorf("expected CCS, got type=%d", recType)
			}
		default: // Encrypted records (EncExt, Cert, CertVerify, Finished, NST)
			if recType != byte(recordTypeApplicationData) {
				// NST might not be present
				break
			}
		}

		pr.HandshakeLens[recordIdx] = totalLen
		data = data[totalLen:]
		recordIdx++
	}

	if recordIdx < 2 {
		return fmt.Errorf("captured only %d records, need at least ServerHello+CCS", recordIdx)
	}

	if show {
		fmt.Printf("REALITY prebuilt: parsed %d record types, total %d bytes\n", recordIdx, len(pr.RawRecords))
	}

	return nil
}

// captureConn wraps a net.Conn and records all data read from it.
type captureConn struct {
	net.Conn
	mu       sync.Mutex
	captured []byte
}

func (c *captureConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	if n > 0 {
		c.mu.Lock()
		c.captured = append(c.captured, b[:n]...)
		c.mu.Unlock()
	}
	return n, err
}

func (c *captureConn) Captured() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]byte, len(c.captured))
	copy(out, c.captured)
	return out
}

// Compatible checks whether a cached response can serve the given ClientHello.
// The cached Server Hello must offer a cipher suite and key share group
// that the client supports.
func (pr *PrebuiltResponse) Compatible(ch *clientHelloMsg) bool {
	if pr.Hello == nil {
		return false
	}
	// Check cipher suite
	suiteOK := false
	for _, cs := range ch.cipherSuites {
		if cs == pr.Hello.cipherSuite {
			suiteOK = true
			break
		}
	}
	if !suiteOK {
		return false
	}
	// Check key share group
	groupOK := false
	for _, ks := range ch.keyShares {
		if ks.group == pr.Hello.serverShare.group {
			groupOK = true
			break
		}
	}
	return groupOK
}
