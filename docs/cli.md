# Command-line tool (`chippy`)

`chippy` uploads summaries to Chippy from a terminal, a script, or an agent. You send a summary you
already have, its tags and the raw source text; Chippy stores them as given. Nothing is re-summarised:
a model still generates the cover image from your summary and text (its palette, emoji, headline and
artwork) and the summary is indexed for search, the same as for a summary made in the app. Uploaded summaries appear in the library on every device signed in to the same
account.

It is a plain command-line program (flags in, text out), so it composes with pipes and shell scripts.
The source lives in `cli/` (Go). It calls `POST /api/v1/summaries/import`, described in
[ARCHITECTURE.md](ARCHITECTURE.md#import-body).

## Install

Requires Go 1.26 or later. From `cli/`:

```sh
make install
```

This builds `chippy` and installs it into Go's bin directory (`$GOBIN`, else `$GOPATH/bin`, usually
`~/go/bin`). If that directory is not on your `PATH`, `make install` prints the line to add.

| Target | |
|---|---|
| `make build` | Build `cli/bin/chippy` without installing it |
| `make install` | Build and install into `BINDIR` |
| `make install BINDIR=~/.local/bin` | Install somewhere else |
| `make install CLIENT_ID=<id>` | Build in a different OAuth client ID |
| `make uninstall` | Remove the installed binary |
| `make test` | Run the tests with the race detector |
| `make clean` | Remove `cli/bin` |

## Signing in

`chippy` signs in with your RxLab account through the browser, using
[RxAuthGo](https://github.com/rxtech-lab/RxAuthGo) (OAuth 2.0 authorization code flow with PKCE).

1. The first command that needs an account (`upload`, `whoami`, `login`) prints
   `Not signed in. Opening your browser to sign in to Chippy…` and opens the RxLab sign-in page.
2. After you sign in, the browser returns to a temporary local callback,
   `http://127.0.0.1:53682/callback`, and the command continues.
3. The session (access and refresh tokens) is saved in your user config directory:
   - macOS: `~/Library/Application Support/rxauthgo/chippy-cli.json`
   - Linux: `~/.config/rxauthgo/chippy-cli.json`

Later commands reuse the saved session and refresh it when it expires, so the browser does not open
again. If the server rejects the saved token (for example, after it was revoked), `upload` signs in
again and retries once. Sign-in times out after 5 minutes.

`chippy logout` deletes the saved session. Treat the session file like a password: anyone with it can
upload to your account until it expires.

On a machine without a browser (SSH, CI), sign in on a machine that has one and copy the session
file to the same path.

## Commands

```text
chippy login     Sign in through the browser (replaces any saved session)
chippy logout    Sign out and delete the saved session
chippy whoami    Show the signed-in account (signs in if needed)
chippy upload    Upload a summary, its tags and the raw text (signs in if needed)
chippy help      Show usage
```

Run `chippy upload -h` for every upload flag.

### `chippy upload`

```sh
chippy upload \
  --title "Monarch migration" \
  --summary "Monarch butterflies fly thousands of kilometres south every autumn." \
  --tag butterflies --tag migration \
  --text-file notes.md
```

```text
Uploaded "Monarch migration" (public)
https://summary.rxlab.app/s/Q2AD4nuCrj
```

| Flag | Required | Description |
|---|---|---|
| `--title` | yes | Title, up to 200 characters |
| `--summary` / `--summary-file` | one of them | The summary, up to 1,200 characters |
| `--text` / `--text-file` | one of them | The raw source text, up to 200,000 characters. Kept as the summary's source document |
| `--tag` | | Tag; repeat the flag or separate with commas. Up to 12. Lowercased and de-duplicated |
| `--highlight` | | A key takeaway; repeat for more. Up to 5. Commas are kept |
| `--keyword` | | Search keyword; repeat or separate with commas. Up to 10 |
| `--category` | | One of `Technology`, `Science`, `Business`, `Finance`, `Politics`, `World`, `Health`, `Sports`, `Entertainment`, `Culture`, `Education`, `Lifestyle`, `Travel`, `Food`, `Opinion`, `Research`, `Other` (default) |
| `--language` | | BCP-47 language of the title and summary, e.g. `en`, `zh-Hans`, `ja`. Default `en` |
| `--source-url` | | Where the text came from. The summary is then shown as a link, labelled by platform (GitHub, YouTube, X, …) |
| `--source-title` | | Title of the source |
| `--site-name` | | Name of the source site, shown on the cover |
| `--image-style` | | Cover style: `graphic` (default) or `illustration` |
| `--visibility` | | `public` (default, anyone with the link can open it) or `private` (only you) |
| `--ttl-days` | | How long the public link works: `1`, `3`, `7`, `30`, `90`, `365` or `never`. Default is the server's (7 days). The summary itself stays in your library either way |
| `--json` | | Print the created summary as JSON instead of the share link |

Flags are checked before signing in, so a mistake never opens the browser.

#### Reading from files and stdin

`--summary-file` and `--text-file` read a file; `-` reads stdin. Only one of them can read stdin.

```sh
pbpaste | chippy upload --title "Meeting notes" --summary "Decisions from Monday." --text-file -

curl -s https://example.com/article.txt | chippy upload \
  --title "Example article" --summary-file summary.txt --text-file - \
  --source-url https://example.com/article
```

#### Output for scripts

Without `--json`, `upload` prints a confirmation line and then the share link, so the link is always
the last line. With `--json` it prints the full summary object (the `Summary` shape in
ARCHITECTURE.md):

```sh
chippy upload --json --title "…" --summary "…" --text-file notes.md | jq -r .shareUrl
link=$(chippy upload --title "…" --summary "…" --text-file notes.md | tail -n 1)
```

Messages about signing in go to stderr, so they never mix with the output.

#### Uploading a folder

```sh
for file in notes/*.md; do
  chippy upload \
    --title "$(basename "$file" .md)" \
    --summary "$(head -n 1 "$file")" \
    --text-file "$file" \
    --tag notes --visibility private
done
```

## Configuration

Settings come from environment variables; the defaults point at production.

| Variable | Default | |
|---|---|---|
| `CHIPPY_SERVER` | `https://summary.rxlab.app` | Chippy server. Use `http://localhost:3000` for a local `bun run dev` |
| `CHIPPY_CLIENT_ID` | built in | OAuth client ID. Overrides the one built in by `make` |
| `CHIPPY_ISSUER` | `https://auth.rxlab.app` | RxLab Auth issuer |
| `CHIPPY_REDIRECT_URI` | `http://127.0.0.1:53682/callback` | Local sign-in callback. Must be a loopback address registered for the client |

The built-in client ID is the apps' public RxAuth client (`SUMMARY_CHIP_IOS_CLIENT_ID` in
`Configuration/Base.xcconfig`), which the server accepts as `IOS_OAUTH_CLIENT_ID`. For sign-in to
work, that client must have the CLI's loopback redirect URI `http://127.0.0.1:53682/callback`
registered in RxLab Auth next to the apps' `summarychip://oauth/callback`.

Using a separate OAuth client instead: register it as a public client with that redirect URI and the
scopes `openid profile email offline_access`, add its ID to the server's `RXLAB_ALLOWED_CLIENT_IDS`,
and build with `make install CLIENT_ID=<id>`.

## Usage and billing

Each upload counts as one summary against your free allowance, or uses points once that is spent, the
same as a summary made in the app. The cover image is still designed by a model. When nothing is
left, `upload` fails with `SUMMARY_ALLOWANCE_EXHAUSTED`; top up in the app or wait for the allowance
to reset.

## Exit codes and errors

| Exit code | Meaning |
|---|---|
| `0` | Success |
| `1` | The command failed: sign-in, network, or an error from the server |
| `2` | Invalid usage (missing or bad flags), or `-h` |

Server errors are printed as `chippy: CODE (HTTP status): message`. Common ones:

| Error | Cause | Fix |
|---|---|---|
| `sign-in failed: … invalid_redirect_uri` (in the browser) | The OAuth client does not have `http://127.0.0.1:53682/callback` registered | Register the redirect URI for the client in RxLab Auth |
| `sign-in failed: … address already in use` | Another program uses port 53682 | Close it, or register another loopback port and set `CHIPPY_REDIRECT_URI` |
| `OAUTH_CLIENT_NOT_ALLOWED (HTTP 403)` | The server does not accept tokens from this client | Add the client ID to the server's `RXLAB_ALLOWED_CLIENT_IDS` |
| `VALIDATION_ERROR (HTTP 400)` | A value is out of range, e.g. a title over 200 characters or more than 12 tags | Check the limits in the flag table |
| `SUMMARY_ALLOWANCE_EXHAUSTED (HTTP 402)` | No free summaries or points left | Top up, or wait for the allowance to reset |
| `CHIPPY_CLIENT_ID is not set` | Built with plain `go build`, without a client ID | Build with `make`, or set `CHIPPY_CLIENT_ID` |

## Development

```sh
cd cli
make test                                   # unit tests (fake server, in-memory session)
make build && ./bin/chippy help
CHIPPY_SERVER=http://localhost:3000 ./bin/chippy upload …   # against a local server
```

| File | |
|---|---|
| `main.go` | Command dispatch, usage, exit codes |
| `auth.go` | Settings, the RxAuthGo session, `login` / `logout` / `whoami` |
| `upload.go` | `upload` flags, the request body, the import call and the retry after a rejected token |
| `upload_test.go` | Tests against an `httptest` server with an in-memory token store |
| `Makefile` | Build, install (with the built-in client ID), test |

CI runs gofmt, `go vet`, the build and `go test -race` for changes under `cli/`
(`.github/workflows/cli-tests.yaml`). The server side of the import is covered by the vitest and
Playwright suites in `server/`.
