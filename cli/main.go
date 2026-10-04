// Command chippy uploads summaries to Chippy from the command line.
//
//	chippy login                 sign in through the browser (RxLab Auth)
//	chippy logout                forget the stored session
//	chippy whoami                show the signed-in account
//	chippy upload [flags]        upload a summary, its tags and the raw text
//
// Commands that need an account sign in first when there is no usable session.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
)

const usage = `Usage: chippy <command> [flags]

Commands:
  login     Sign in through the browser
  logout    Sign out and remove the stored session
  whoami    Show the signed-in account
  upload    Upload a summary with its tags and raw text (signs in when needed)

Run "chippy <command> -h" for a command's flags.

Environment:
  CHIPPY_CLIENT_ID     OAuth client ID of the Chippy CLI (required unless built in)
  CHIPPY_SERVER        Chippy server (default ` + defaultServer + `)
  CHIPPY_ISSUER        RxLab Auth issuer (default ` + defaultIssuer + `)
  CHIPPY_REDIRECT_URI  Loopback callback registered for the client (default ` + defaultRedirectURI + `)
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr); err != nil {
		// Help and bare usage errors have already printed the usage; a duplicate its explanation.
		if !errors.Is(err, flag.ErrHelp) && err != errUsage && !errors.Is(err, errDuplicate) {
			fmt.Fprintln(os.Stderr, "chippy:", err)
		}
		os.Exit(exitCode(err))
	}
}

func exitCode(err error) int {
	if errors.Is(err, flag.ErrHelp) || errors.Is(err, errUsage) {
		return 2
	}
	if errors.Is(err, errDuplicate) {
		return 3
	}
	return 1
}

var errUsage = errors.New("invalid usage")

func run(ctx context.Context, args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return errUsage
	}
	command, rest := args[0], args[1:]
	switch command {
	case "-h", "--help", "help":
		fmt.Fprint(stdout, usage)
		return nil
	case "login", "logout", "whoami", "upload":
	default:
		fmt.Fprintf(stderr, "unknown command %q\n\n%s", command, usage)
		return errUsage
	}

	settings, err := loadSettings()
	if err != nil {
		return err
	}
	session, err := newSession(settings, stderr)
	if err != nil {
		return err
	}
	switch command {
	case "login":
		return runLogin(ctx, session, stdout)
	case "logout":
		return runLogout(ctx, session, stdout)
	case "whoami":
		return runWhoami(ctx, session, stdout)
	default:
		return runUpload(ctx, session, settings, rest, stdin, stdout, stderr)
	}
}
