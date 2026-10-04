package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"

	rxauth "github.com/rxtech-lab/RxAuthGo"
	"github.com/rxtech-lab/RxAuthGo/rxauthcli"
)

const (
	defaultServer      = "https://summary.rxlab.app"
	defaultIssuer      = rxauth.DefaultIssuer
	defaultRedirectURI = "http://127.0.0.1:53682/callback"
	storeName          = "chippy-cli"
)

// builtInClientID can be set at build time:
//
//	go build -ldflags "-X main.builtInClientID=<client-id>"
var builtInClientID = ""

type settings struct {
	server      string
	issuer      string
	clientID    string
	redirectURI string
}

func loadSettings() (settings, error) {
	s := settings{
		server:      strings.TrimRight(envOr("CHIPPY_SERVER", defaultServer), "/"),
		issuer:      envOr("CHIPPY_ISSUER", defaultIssuer),
		clientID:    envOr("CHIPPY_CLIENT_ID", builtInClientID),
		redirectURI: envOr("CHIPPY_REDIRECT_URI", defaultRedirectURI),
	}
	if s.clientID == "" {
		return s, fmt.Errorf("CHIPPY_CLIENT_ID is not set: use the client ID of the Chippy CLI's OAuth client (it must also be in the server's RXLAB_ALLOWED_CLIENT_IDS)")
	}
	return s, nil
}

func envOr(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

// session wraps the RxAuthGo CLI authenticator: tokens are stored on disk, refreshed when they
// expire, and the browser sign-in only runs when there is no usable session.
type session struct {
	auth   *rxauthcli.Authenticator
	stderr io.Writer
}

func newSession(s settings, stderr io.Writer) (*session, error) {
	auth, err := rxauthcli.NewAuthenticator(rxauthcli.Options{
		Config: rxauth.Config{
			Issuer:      s.issuer,
			ClientID:    s.clientID,
			RedirectURI: s.redirectURI,
			Scopes:      rxauth.DefaultScopes,
		},
		StoreName: storeName,
	})
	if err != nil {
		return nil, err
	}
	return &session{auth: auth, stderr: stderr}, nil
}

// accessToken returns a valid access token, signing in through the browser when needed.
func (s *session) accessToken(ctx context.Context) (string, error) {
	if token, err := s.auth.Client().AccessToken(ctx); err == nil {
		return token.AccessToken, nil
	}
	return s.login(ctx)
}

// login always runs the browser sign-in, replacing any stored session.
func (s *session) login(ctx context.Context) (string, error) {
	fmt.Fprintln(s.stderr, "Not signed in. Opening your browser to sign in to Chippy…")
	token, err := s.auth.Login(ctx)
	if err != nil {
		return "", fmt.Errorf("sign-in failed: %w", err)
	}
	return token.AccessToken, nil
}

func runLogin(ctx context.Context, s *session, stdout io.Writer) error {
	if _, err := s.login(ctx); err != nil {
		return err
	}
	return runWhoami(ctx, s, stdout)
}

func runLogout(ctx context.Context, s *session, stdout io.Writer) error {
	if err := s.auth.Logout(ctx); err != nil && !rxauth.IsNoToken(err) {
		return err
	}
	fmt.Fprintln(stdout, "Signed out.")
	return nil
}

func runWhoami(ctx context.Context, s *session, stdout io.Writer) error {
	user, err := s.auth.CurrentUser(ctx)
	if err != nil {
		return err
	}
	name := user.Name
	if name == "" {
		name = user.PreferredUsername
	}
	switch {
	case name != "" && user.Email != "":
		fmt.Fprintf(stdout, "Signed in as %s <%s>\n", name, user.Email)
	case user.Email != "":
		fmt.Fprintf(stdout, "Signed in as %s\n", user.Email)
	default:
		fmt.Fprintf(stdout, "Signed in as %s\n", user.ID)
	}
	return nil
}
