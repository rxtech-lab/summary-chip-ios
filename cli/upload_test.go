package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	rxauth "github.com/rxtech-lab/RxAuthGo"
	"github.com/rxtech-lab/RxAuthGo/rxauthcli"
)

// testSession has an in-memory token store; a sign-in attempt records the browser open and times out.
func testSession(t *testing.T, token string) (*session, *atomic.Int32) {
	t.Helper()
	store := rxauth.NewMemoryTokenStore()
	if token != "" {
		if err := store.SaveToken(context.Background(), rxauth.TokenSet{AccessToken: token, ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
			t.Fatal(err)
		}
	}
	var opened atomic.Int32
	auth, err := rxauthcli.NewAuthenticator(rxauthcli.Options{
		Config: rxauth.Config{
			Issuer:      "https://auth.test.example",
			ClientID:    "chippy-cli-test",
			RedirectURI: "http://127.0.0.1:0/callback",
		},
		Store:           store,
		BrowserOpen:     func(string) error { opened.Add(1); return nil },
		CallbackTimeout: 100 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	return &session{auth: auth, stderr: io.Discard}, &opened
}

type fakeServer struct {
	*httptest.Server
	auth []string
	body importRequest
	raw  map[string]any
}

func newFakeServer(t *testing.T, status int, response string) *fakeServer {
	t.Helper()
	fake := &fakeServer{}
	fake.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/summaries/import" {
			http.NotFound(w, r)
			return
		}
		fake.auth = append(fake.auth, r.Header.Get("Authorization"))
		data, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(data, &fake.body)
		_ = json.Unmarshal(data, &fake.raw)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, response)
	}))
	t.Cleanup(fake.Close)
	return fake
}

const created = `{"id":"sum-1","slug":"abc123","shareUrl":"https://summary.test/s/abc123","title":"Monarch migration","tags":["butterflies","migration"],"visibility":"public"}`

func runUploadTest(t *testing.T, s *session, server string, args []string, stdin string) (string, error) {
	t.Helper()
	var stdout bytes.Buffer
	err := runUpload(context.Background(), s, settings{server: server}, args, strings.NewReader(stdin), &stdout, io.Discard)
	return stdout.String(), err
}

func TestUploadSendsSummaryTagsAndTextWithStoredToken(t *testing.T) {
	server := newFakeServer(t, http.StatusCreated, created)
	s, opened := testSession(t, "stored-token")
	notes := filepath.Join(t.TempDir(), "notes.md")
	if err := os.WriteFile(notes, []byte("Raw field notes"), 0o600); err != nil {
		t.Fatal(err)
	}

	out, err := runUploadTest(t, s, server.URL, []string{
		"--title", "Monarch migration",
		"--summary", "Monarchs fly south each autumn.",
		"--tag", "butterflies,migration", "--tag", "insects",
		"--highlight", "They fly south, in groups",
		"--text-file", notes,
		"--category", "Science",
		"--visibility", "private",
		"--ttl-days", "never",
	}, "")
	if err != nil {
		t.Fatal(err)
	}
	if opened.Load() != 0 {
		t.Fatal("signed in although a token was stored")
	}
	if got := server.auth; len(got) != 1 || got[0] != "Bearer stored-token" {
		t.Fatalf("authorization headers = %v", got)
	}
	want := importRequest{
		Title: "Monarch migration", Summary: "Monarchs fly south each autumn.", Text: "Raw field notes",
		Tags: []string{"butterflies", "migration", "insects"}, Highlights: []string{"They fly south, in groups"},
		Category: "Science", Visibility: "private",
	}
	got := server.body
	got.TTLDays = nil
	if gotJSON, wantJSON := mustJSON(t, got), mustJSON(t, want); gotJSON != wantJSON {
		t.Fatalf("body = %s\nwant %s", gotJSON, wantJSON)
	}
	if ttl, ok := server.raw["ttlDays"]; !ok || ttl != nil {
		t.Fatalf("ttlDays = %v (present %v), want null", ttl, ok)
	}
	if _, ok := server.raw["sourceUrl"]; ok {
		t.Fatal("unset optional fields must be omitted")
	}
	if !strings.Contains(out, "https://summary.test/s/abc123") {
		t.Fatalf("output = %q", out)
	}
}

func TestUploadReadsTextFromStdinAndPrintsJSON(t *testing.T) {
	server := newFakeServer(t, http.StatusCreated, created)
	s, _ := testSession(t, "stored-token")
	out, err := runUploadTest(t, s, server.URL, []string{"--title", "T", "--summary", "S", "--text-file", "-", "--json"}, "piped text")
	if err != nil {
		t.Fatal(err)
	}
	if server.body.Text != "piped text" {
		t.Fatalf("text = %q", server.body.Text)
	}
	if strings.TrimSpace(out) != created {
		t.Fatalf("output = %q", out)
	}
}

func TestUploadSignsInWhenThereIsNoSession(t *testing.T) {
	server := newFakeServer(t, http.StatusCreated, created)
	s, opened := testSession(t, "")
	_, err := runUploadTest(t, s, server.URL, []string{"--title", "T", "--summary", "S", "--text", "x"}, "")
	if err == nil || !strings.Contains(err.Error(), "sign-in failed") {
		t.Fatalf("err = %v, want a sign-in attempt", err)
	}
	if opened.Load() != 1 {
		t.Fatalf("browser opened %d times, want 1", opened.Load())
	}
	if len(server.auth) != 0 {
		t.Fatal("uploaded without a token")
	}
}

func TestUploadSignsInAgainWhenTheServerRejectsTheToken(t *testing.T) {
	server := newFakeServer(t, http.StatusUnauthorized, `{"error":{"code":"INVALID_ACCESS_TOKEN","message":"expired"}}`)
	s, opened := testSession(t, "revoked-token")
	_, err := runUploadTest(t, s, server.URL, []string{"--title", "T", "--summary", "S", "--text", "x"}, "")
	if err == nil || !strings.Contains(err.Error(), "sign-in failed") {
		t.Fatalf("err = %v", err)
	}
	if opened.Load() != 1 || len(server.auth) != 1 {
		t.Fatalf("browser opened %d times, %d uploads", opened.Load(), len(server.auth))
	}
}

func TestUploadReportsServerErrors(t *testing.T) {
	server := newFakeServer(t, http.StatusPaymentRequired, `{"error":{"code":"SUMMARY_ALLOWANCE_EXHAUSTED","message":"Top up"}}`)
	s, _ := testSession(t, "stored-token")
	_, err := runUploadTest(t, s, server.URL, []string{"--title", "T", "--summary", "S", "--text", "x"}, "")
	var apiErr *apiError
	if !errors.As(err, &apiErr) || apiErr.Status != 402 || apiErr.Code != "SUMMARY_ALLOWANCE_EXHAUSTED" {
		t.Fatalf("err = %v", err)
	}
}

func TestUploadValidatesFlagsBeforeSigningIn(t *testing.T) {
	cases := map[string][]string{
		"missing title":     {"--summary", "S", "--text", "x"},
		"missing summary":   {"--title", "T", "--text", "x"},
		"missing text":      {"--title", "T", "--summary", "S"},
		"text and file":     {"--title", "T", "--summary", "S", "--text", "x", "--text-file", "a.md"},
		"two stdin readers": {"--title", "T", "--summary-file", "-", "--text-file", "-"},
		"bad ttl":           {"--title", "T", "--summary", "S", "--text", "x", "--ttl-days", "5"},
		"extra argument":    {"--title", "T", "--summary", "S", "--text", "x", "stray"},
	}
	for name, args := range cases {
		t.Run(name, func(t *testing.T) {
			s, opened := testSession(t, "")
			_, err := runUploadTest(t, s, "http://127.0.0.1:1", args, "")
			if !errors.Is(err, errUsage) {
				t.Fatalf("err = %v, want errUsage", err)
			}
			if opened.Load() != 0 {
				t.Fatal("signed in before validating flags")
			}
		})
	}
}

func mustJSON(t *testing.T, value any) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
