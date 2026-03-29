package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// IPInfo contains ASN and location info for an IP address.
type IPInfo struct {
	IP      string `json:"ip"`
	ASN     int    `json:"asn"`
	Org     string `json:"org"`
	Country string `json:"country"`
	City    string `json:"city"`
}

// TargetCandidate represents a potential target with its validation results.
type TargetCandidate struct {
	Domain    string
	IP        string
	ASN       int
	Org       string
	Country   string
	City      string
	TLS13     bool
	H2        bool
	NonRedir  bool
	OCSPStapl bool
	Score     int
}

// lookupSelfInfo queries a public API to get our own IP, ASN, and geolocation.
func lookupSelfInfo(ctx context.Context) (*IPInfo, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://ipinfo.io/json", nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to query ipinfo.io: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	// ipinfo.io returns: {"ip":"...","org":"AS12345 Org Name","country":"DE","city":"Falkenstein",...}
	var raw struct {
		IP      string `json:"ip"`
		Org     string `json:"org"`
		Country string `json:"country"`
		City    string `json:"city"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, fmt.Errorf("failed to parse ipinfo response: %w", err)
	}

	info := &IPInfo{
		IP:      raw.IP,
		Org:     raw.Org,
		Country: raw.Country,
		City:    raw.City,
	}

	// Parse ASN from org field: "AS12345 Hetzner Online GmbH"
	if strings.HasPrefix(raw.Org, "AS") {
		parts := strings.SplitN(raw.Org, " ", 2)
		if len(parts) >= 1 {
			fmt.Sscanf(parts[0], "AS%d", &info.ASN)
		}
	}

	return info, nil
}

// lookupDomainInfo resolves a domain and gets ASN/geo for its IP.
func lookupDomainInfo(ctx context.Context, domain string) (*IPInfo, error) {
	resolver := &net.Resolver{}
	ips, err := resolver.LookupHost(ctx, domain)
	if err != nil {
		return nil, err
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("no IPs for %s", domain)
	}

	// Prefer IPv4
	ip := ips[0]
	for _, candidate := range ips {
		if net.ParseIP(candidate).To4() != nil {
			ip = candidate
			break
		}
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://ipinfo.io/"+ip+"/json", nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var raw struct {
		IP      string `json:"ip"`
		Org     string `json:"org"`
		Country string `json:"country"`
		City    string `json:"city"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, err
	}

	info := &IPInfo{
		IP:      ip,
		Org:     raw.Org,
		Country: raw.Country,
		City:    raw.City,
	}

	if strings.HasPrefix(raw.Org, "AS") {
		parts := strings.SplitN(raw.Org, " ", 2)
		if len(parts) >= 1 {
			fmt.Sscanf(parts[0], "AS%d", &info.ASN)
		}
	}

	return info, nil
}

// checkTLS13H2 connects to the domain and checks TLS 1.3 support, H2, OCSP stapling.
func checkTLS13H2(ctx context.Context, domain string) (tls13, h2, ocspStapling bool) {
	dialer := &tls.Dialer{
		Config: &tls.Config{
			NextProtos:         []string{"h2", "http/1.1"},
			InsecureSkipVerify: false,
			MinVersion:         tls.VersionTLS13,
			MaxVersion:         tls.VersionTLS13,
		},
	}

	conn, err := dialer.DialContext(ctx, "tcp", domain+":443")
	if err != nil {
		return false, false, false
	}
	defer conn.Close()

	tlsConn := conn.(*tls.Conn)
	state := tlsConn.ConnectionState()

	tls13 = state.Version == tls.VersionTLS13
	h2 = state.NegotiatedProtocol == "h2"
	ocspStapling = len(state.OCSPResponse) > 0

	return
}

// checkNonRedirect does a HEAD request and checks if the domain doesn't redirect.
func checkNonRedirect(ctx context.Context, domain string) bool {
	client := &http.Client{
		Timeout: 10 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodHead, "https://"+domain+"/", nil)
	if err != nil {
		return false
	}

	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	return resp.StatusCode < 300 || resp.StatusCode >= 400
}

// defaultCandidates returns a list of well-known domains to test.
// These are large services with servers in many locations worldwide.
func defaultCandidates() []string {
	return []string{
		// CDNs and cloud providers (present in many ASNs)
		"www.cloudflare.com",
		"cdnjs.cloudflare.com",
		"cdn.jsdelivr.net",
		"fastly.com",
		"www.fastly.com",
		"vimeo.com",
		"www.vimeo.com",

		// Large tech companies with global presence
		"dl.google.com",
		"www.google.com",
		"maps.google.com",
		"fonts.googleapis.com",
		"www.gstatic.com",
		"play.google.com",
		"mail.google.com",
		"drive.google.com",

		"www.microsoft.com",
		"learn.microsoft.com",
		"azure.microsoft.com",
		"login.microsoftonline.com",
		"outlook.office365.com",
		"teams.microsoft.com",

		"www.apple.com",
		"support.apple.com",
		"developer.apple.com",

		"www.amazon.com",
		"aws.amazon.com",

		"github.com",
		"www.github.com",
		"api.github.com",

		// Hosting/cloud providers often colocated
		"www.hetzner.com",
		"www.ovh.com",
		"www.scaleway.com",
		"www.digitalocean.com",
		"www.vultr.com",
		"www.linode.com",

		// Content platforms
		"www.mozilla.org",
		"addons.mozilla.org",
		"www.wikipedia.org",
		"en.wikipedia.org",
		"www.reddit.com",
		"www.twitch.tv",
		"discord.com",
		"www.spotify.com",

		// Enterprise / SaaS
		"www.shopify.com",
		"www.stripe.com",
		"www.netlify.com",
		"www.vercel.com",
		"www.heroku.com",
		"www.atlassian.com",
		"www.slack.com",
		"www.dropbox.com",
		"www.notion.so",
	}
}

func main() {
	fmt.Println("=== REALITY Auto-Target Finder ===")
	fmt.Println()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// Step 1: Determine our own IP and ASN
	fmt.Print("Determining VPS IP and ASN... ")
	self, err := lookupSelfInfo(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\nError: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Done!\n")
	fmt.Printf("  IP:      %s\n", self.IP)
	fmt.Printf("  ASN:     AS%d\n", self.ASN)
	fmt.Printf("  Org:     %s\n", self.Org)
	fmt.Printf("  Country: %s\n", self.Country)
	fmt.Printf("  City:    %s\n", self.City)
	fmt.Println()

	// Step 2: Check candidates
	candidates := defaultCandidates()

	// Allow user to supply additional domains via args
	if len(os.Args) > 1 {
		candidates = append(candidates, os.Args[1:]...)
	}

	fmt.Printf("Checking %d candidate domains...\n\n", len(candidates))

	var (
		mu      sync.Mutex
		results []TargetCandidate
		wg      sync.WaitGroup
	)

	// Use a semaphore to limit concurrent checks (avoid rate limiting from ipinfo.io)
	sem := make(chan struct{}, 5)

	for _, domain := range candidates {
		wg.Add(1)
		go func(d string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			checkCtx, checkCancel := context.WithTimeout(ctx, 15*time.Second)
			defer checkCancel()

			// Resolve and get ASN info
			info, err := lookupDomainInfo(checkCtx, d)
			if err != nil {
				return
			}

			// Check TLS 1.3 + H2
			tls13, h2, ocsp := checkTLS13H2(checkCtx, d)
			if !tls13 {
				return // Hard requirement
			}

			// Check non-redirect
			nonRedir := checkNonRedirect(checkCtx, d)

			// Score the candidate
			score := 0

			// Same ASN = strongest signal (+50)
			if info.ASN == self.ASN && self.ASN != 0 {
				score += 50
			}

			// Same country (+20)
			if info.Country == self.Country && self.Country != "" {
				score += 20
			}

			// Same city (+15)
			if info.City == self.City && self.City != "" {
				score += 15
			}

			// TLS 1.3 is mandatory, but H2 is bonus (+10)
			if h2 {
				score += 10
			}

			// Non-redirect (+5)
			if nonRedir {
				score += 5
			}

			// OCSP Stapling (+5)
			if ocsp {
				score += 5
			}

			candidate := TargetCandidate{
				Domain:    d,
				IP:        info.IP,
				ASN:       info.ASN,
				Org:       info.Org,
				Country:   info.Country,
				City:      info.City,
				TLS13:     tls13,
				H2:        h2,
				NonRedir:  nonRedir,
				OCSPStapl: ocsp,
				Score:     score,
			}

			mu.Lock()
			results = append(results, candidate)
			mu.Unlock()
		}(domain)
	}

	wg.Wait()

	// Sort by score descending
	sort.Slice(results, func(i, j int) bool {
		return results[i].Score > results[j].Score
	})

	// Display results
	fmt.Printf("\n=== Results (sorted by compatibility score) ===\n\n")
	fmt.Printf("%-35s %-16s %-8s %-4s %-6s %-4s %-5s %-7s %s\n",
		"DOMAIN", "IP", "ASN", "CC", "CITY", "H2", "OCSP", "NO-RED", "SCORE")
	fmt.Println(strings.Repeat("-", 110))

	for _, r := range results {
		asnMatch := " "
		if r.ASN == self.ASN && self.ASN != 0 {
			asnMatch = "*"
		}

		cityStr := r.City
		if len(cityStr) > 6 {
			cityStr = cityStr[:6]
		}

		h2Str := "no"
		if r.H2 {
			h2Str = "yes"
		}
		ocspStr := "no"
		if r.OCSPStapl {
			ocspStr = "yes"
		}
		redirStr := "no"
		if r.NonRedir {
			redirStr = "yes"
		}

		fmt.Printf("%-35s %-16s AS%-5d%s %-4s %-6s %-4s %-5s %-7s %d\n",
			r.Domain, r.IP, r.ASN, asnMatch, r.Country, cityStr, h2Str, ocspStr, redirStr, r.Score)
	}

	// Print recommendation
	fmt.Println()
	if len(results) > 0 && results[0].Score >= 30 {
		fmt.Println("=== RECOMMENDED TARGET ===")
		fmt.Printf("  Domain: %s\n", results[0].Domain)
		fmt.Printf("  Score:  %d\n", results[0].Score)
		fmt.Println()
		fmt.Println("Sample REALITY server config:")
		fmt.Printf("  \"target\": \"%s:443\",\n", results[0].Domain)
		fmt.Printf("  \"serverNames\": [\"%s\"],\n", results[0].Domain)
	} else if len(results) > 0 {
		fmt.Println("=== BEST AVAILABLE (no same-ASN match found) ===")
		fmt.Printf("  Domain: %s (score: %d)\n", results[0].Domain, results[0].Score)
		fmt.Println("  Consider using a VPS in the same ASN as a popular website,")
		fmt.Println("  or adding custom domains with: autotarget domain1.com domain2.com")
	} else {
		fmt.Println("No suitable targets found. Check your network connectivity.")
	}
}
