package reality

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadTargetPoolFromJSON(t *testing.T) {
	tempDir := t.TempDir()
	jsonPath := filepath.Join(tempDir, "targets.json")
	content := `{
	  "entries": [
	    {"name": "A", "urls": ["https://www.example.com/path", "https://api.example.com"]},
	    {"name": "B", "urls": ["https://www.example.com/other", "example.org"]}
	  ]
	}`
	if err := os.WriteFile(jsonPath, []byte(content), 0644); err != nil {
		t.Fatalf("write temp json: %v", err)
	}

	pool, err := LoadTargetPoolFromJSON(jsonPath, 5*time.Second)
	if err != nil {
		t.Fatalf("LoadTargetPoolFromJSON returned error: %v", err)
	}
	if pool == nil {
		t.Fatal("LoadTargetPoolFromJSON returned nil pool")
	}
	if got, want := pool.Len(), 3; got != want {
		t.Fatalf("pool.Len() = %d, want %d", got, want)
	}

	all := pool.AllServerNames()
	for _, host := range []string{"www.example.com", "api.example.com", "example.org"} {
		if !all[host] {
			t.Fatalf("expected host %q in target pool", host)
		}
	}
}