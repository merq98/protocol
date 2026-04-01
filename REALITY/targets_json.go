package reality

import (
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"slices"
	"strings"
	"time"
)

type targetListJSON struct {
	Entries []targetListEntry `json:"entries"`
}

type targetListEntry struct {
	Name string   `json:"name"`
	URLs []string `json:"urls"`
}

// LoadTargetPoolFromJSON builds a TargetPool from the flat JSON file used in this repo.
// Each unique hostname becomes a target with Dest=<host>:443 and ServerNames containing the host itself.
func LoadTargetPoolFromJSON(filePath string, rotateInterval time.Duration) (*TargetPool, error) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return nil, fmt.Errorf("read targets json: %w", err)
	}

	var payload targetListJSON
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("parse targets json: %w", err)
	}

	targets, err := buildTargetsFromEntries(payload.Entries)
	if err != nil {
		return nil, err
	}

	return NewTargetPool(targets, rotateInterval), nil
}

func buildTargetsFromEntries(entries []targetListEntry) ([]Target, error) {
	hostSet := make(map[string]bool)
	for _, entry := range entries {
		for _, rawURL := range entry.URLs {
			host, port, err := extractTargetHostPort(rawURL)
			if err != nil {
				continue
			}
			hostSet[net.JoinHostPort(host, port)] = true
		}
	}

	if len(hostSet) == 0 {
		return nil, fmt.Errorf("targets json does not contain any valid target URLs")
	}

	dests := make([]string, 0, len(hostSet))
	for dest := range hostSet {
		dests = append(dests, dest)
	}
	slices.Sort(dests)

	targets := make([]Target, 0, len(dests))
	for _, dest := range dests {
		host, _, err := net.SplitHostPort(dest)
		if err != nil {
			continue
		}
		targets = append(targets, Target{
			Dest: dest,
			ServerNames: map[string]bool{
				host: true,
			},
		})
	}

	if len(targets) == 0 {
		return nil, fmt.Errorf("targets json does not contain any valid target hosts")
	}

	return targets, nil
}

func extractTargetHostPort(raw string) (string, string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", "", fmt.Errorf("empty url")
	}

	parsed, err := url.Parse(raw)
	if err != nil {
		return "", "", err
	}

	host := parsed.Hostname()
	if host == "" {
		parsed, err = url.Parse("https://" + raw)
		if err != nil {
			return "", "", err
		}
		host = parsed.Hostname()
	}
	if host == "" {
		return "", "", fmt.Errorf("missing host")
	}

	port := parsed.Port()
	if port == "" {
		port = "443"
	}

	return strings.ToLower(host), port, nil
}