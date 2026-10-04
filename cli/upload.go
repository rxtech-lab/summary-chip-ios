package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// importRequest is the body of POST /api/v1/summaries/import (docs/ARCHITECTURE.md, "Import body").
type importRequest struct {
	Title       string   `json:"title"`
	Summary     string   `json:"summary"`
	Text        string   `json:"text"`
	Tags        []string `json:"tags,omitempty"`
	Highlights  []string `json:"highlights,omitempty"`
	Category    string   `json:"category,omitempty"`
	Keywords    []string `json:"keywords,omitempty"`
	Language    string   `json:"language,omitempty"`
	SourceURL   string   `json:"sourceUrl,omitempty"`
	SourceTitle string   `json:"sourceTitle,omitempty"`
	SiteName    string   `json:"siteName,omitempty"`
	ImageStyle  string   `json:"imageStyle,omitempty"`
	Visibility  string   `json:"visibility,omitempty"`
	// TTLDays is raw so "never" can be sent as null; omitted means the server default.
	TTLDays json.RawMessage `json:"ttlDays,omitempty"`
}

type summaryResponse struct {
	ID         string   `json:"id"`
	Slug       string   `json:"slug"`
	ShareURL   string   `json:"shareUrl"`
	Title      string   `json:"title"`
	Tags       []string `json:"tags"`
	Visibility string   `json:"visibility"`
}

type apiError struct {
	Status  int
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *apiError) Error() string {
	if e.Code == "" {
		return fmt.Sprintf("server returned HTTP %d", e.Status)
	}
	return fmt.Sprintf("%s (HTTP %d): %s", e.Code, e.Status, e.Message)
}

// stringList is a repeatable flag that also accepts comma-separated values.
type stringList []string

func (l *stringList) String() string { return strings.Join(*l, ",") }

func (l *stringList) Set(value string) error {
	for _, part := range strings.Split(value, ",") {
		if part = strings.TrimSpace(part); part != "" {
			*l = append(*l, part)
		}
	}
	return nil
}

// repeated is a repeatable flag that keeps each value whole (highlights may contain commas).
type repeated []string

func (r *repeated) String() string { return strings.Join(*r, " | ") }

func (r *repeated) Set(value string) error {
	*r = append(*r, value)
	return nil
}

const uploadUsage = `Usage: chippy upload --title TITLE (--summary TEXT | --summary-file PATH) (--text-file PATH | --text TEXT) [flags]

Uploads a summary, its tags and the raw source text to Chippy. Nothing is re-summarised.
Signs in through the browser first when there is no usable session.
Use "-" as a file path to read from stdin (only one of --summary-file / --text-file).

Example:
  chippy upload --title "Monarch migration" --summary "Monarchs fly south each autumn." \
    --tag butterflies --tag migration --text-file notes.md

Flags:
`

func runUpload(ctx context.Context, s *session, cfg settings, args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("upload", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() {
		fmt.Fprint(stderr, uploadUsage)
		fs.PrintDefaults()
	}
	var (
		req                   importRequest
		summaryFile, textFile string
		tags, keywords        stringList
		highlights            repeated
		ttl                   string
		jsonOutput            bool
	)
	fs.StringVar(&req.Title, "title", "", "summary title (required, ≤ 200 chars)")
	fs.StringVar(&req.Summary, "summary", "", "summary text (≤ 1200 chars)")
	fs.StringVar(&summaryFile, "summary-file", "", "read the summary from a file")
	fs.StringVar(&req.Text, "text", "", "raw source text")
	fs.StringVar(&textFile, "text-file", "", "read the raw source text from a file")
	fs.Var(&tags, "tag", "tag (repeatable or comma-separated, ≤ 12)")
	fs.Var(&highlights, "highlight", "key takeaway (repeatable, ≤ 5)")
	fs.Var(&keywords, "keyword", "search keyword (repeatable or comma-separated, ≤ 10)")
	fs.StringVar(&req.Category, "category", "", `category, e.g. "Technology" (default "Other")`)
	fs.StringVar(&req.Language, "language", "", `BCP-47 language of the title and summary (default "en")`)
	fs.StringVar(&req.SourceURL, "source-url", "", "URL the text came from")
	fs.StringVar(&req.SourceTitle, "source-title", "", "title of the source")
	fs.StringVar(&req.SiteName, "site-name", "", "name of the source site")
	fs.StringVar(&req.ImageStyle, "image-style", "", `cover style: "graphic" or "illustration" (default "graphic")`)
	fs.StringVar(&req.Visibility, "visibility", "", `"public" or "private" (default "public")`)
	fs.StringVar(&ttl, "ttl-days", "", `public link lifetime in days (1, 3, 7, 30, 90, 365) or "never"`)
	fs.BoolVar(&jsonOutput, "json", false, "print the created summary as JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		fs.Usage()
		return fmt.Errorf("%w: unexpected argument %q", errUsage, fs.Arg(0))
	}

	if summaryFile == "-" && textFile == "-" {
		return fmt.Errorf("%w: only one of --summary-file and --text-file can read stdin", errUsage)
	}
	var err error
	if req.Summary, err = pick("summary", req.Summary, summaryFile, stdin); err != nil {
		return err
	}
	if req.Text, err = pick("text", req.Text, textFile, stdin); err != nil {
		return err
	}
	if strings.TrimSpace(req.Title) == "" {
		return fmt.Errorf("%w: --title is required", errUsage)
	}
	req.Tags, req.Keywords, req.Highlights = tags, keywords, highlights
	if req.TTLDays, err = parseTTL(ttl); err != nil {
		return err
	}

	summary, raw, err := upload(ctx, s, cfg.server, req)
	if err != nil {
		return err
	}
	if jsonOutput {
		_, err = stdout.Write(append(raw, '\n'))
		return err
	}
	fmt.Fprintf(stdout, "Uploaded %q (%s)\n%s\n", summary.Title, summary.Visibility, summary.ShareURL)
	return nil
}

// pick returns the inline value or the file's contents ("-" = stdin); exactly one is required.
func pick(name, inline, path string, stdin io.Reader) (string, error) {
	switch {
	case inline != "" && path != "":
		return "", fmt.Errorf("%w: use either --%s or --%s-file, not both", errUsage, name, name)
	case path == "-":
		data, err := io.ReadAll(stdin)
		return string(data), err
	case path != "":
		data, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("reading --%s-file: %w", name, err)
		}
		return string(data), nil
	case strings.TrimSpace(inline) == "":
		return "", fmt.Errorf("%w: --%s or --%s-file is required", errUsage, name, name)
	default:
		return inline, nil
	}
}

func parseTTL(value string) (json.RawMessage, error) {
	switch value {
	case "":
		return nil, nil
	case "never":
		return json.RawMessage("null"), nil
	}
	for _, allowed := range []string{"1", "3", "7", "30", "90", "365"} {
		if value == allowed {
			return json.RawMessage(value), nil
		}
	}
	return nil, fmt.Errorf("%w: --ttl-days must be 1, 3, 7, 30, 90, 365 or never", errUsage)
}

var httpClient = &http.Client{Timeout: 2 * time.Minute}

// upload posts the summary; when the server rejects the stored token it signs in again and retries once.
func upload(ctx context.Context, s *session, server string, req importRequest) (summaryResponse, []byte, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return summaryResponse{}, nil, err
	}
	token, err := s.accessToken(ctx)
	if err != nil {
		return summaryResponse{}, nil, err
	}
	summary, raw, err := postImport(ctx, server, token, body)
	var apiErr *apiError
	if errors.As(err, &apiErr) && apiErr.Status == http.StatusUnauthorized {
		if token, err = s.login(ctx); err != nil {
			return summaryResponse{}, nil, err
		}
		summary, raw, err = postImport(ctx, server, token, body)
	}
	return summary, raw, err
}

func postImport(ctx context.Context, server, token string, body []byte) (summaryResponse, []byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, server+"/api/v1/summaries/import", bytes.NewReader(body))
	if err != nil {
		return summaryResponse{}, nil, err
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	response, err := httpClient.Do(request)
	if err != nil {
		return summaryResponse{}, nil, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 10<<20))
	if err != nil {
		return summaryResponse{}, nil, err
	}
	if response.StatusCode != http.StatusCreated {
		failure := &apiError{Status: response.StatusCode}
		var envelope struct {
			Error *apiError `json:"error"`
		}
		if json.Unmarshal(raw, &envelope) == nil && envelope.Error != nil {
			failure.Code, failure.Message = envelope.Error.Code, envelope.Error.Message
		}
		return summaryResponse{}, nil, failure
	}
	var summary summaryResponse
	if err := json.Unmarshal(raw, &summary); err != nil {
		return summaryResponse{}, nil, fmt.Errorf("unexpected response: %w", err)
	}
	return summary, raw, nil
}
