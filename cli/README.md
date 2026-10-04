# chippy CLI

Uploads a summary, its tags and the raw source text to Chippy from the command line
(`POST /api/v1/summaries/import`). Nothing is re-summarised: the server stores what you send,
designs the cover and indexes it for search.

Sign-in uses [RxAuthGo](https://github.com/rxtech-lab/RxAuthGo): the first command that needs an
account opens the browser to sign in to RxLab Auth. The session is stored on disk and refreshed
automatically, so later commands run without a browser.

## Setup

1. Register a **public** OAuth client in RxLab Auth with the loopback redirect URI
   `http://127.0.0.1:53682/callback` and the scopes `openid profile email offline_access`.
2. Add its client ID to the server's `RXLAB_ALLOWED_CLIENT_IDS` (otherwise uploads fail with
   `403 OAUTH_CLIENT_NOT_ALLOWED`).
3. Build:

   ```sh
   go -C cli build -o chippy .
   # or bake in the client ID:
   go -C cli build -ldflags "-X main.builtInClientID=<client-id>" -o chippy .
   ```

| Variable | Default |
|---|---|
| `CHIPPY_CLIENT_ID` | the built-in client ID, if any (required) |
| `CHIPPY_SERVER` | `https://summary.rxlab.app` |
| `CHIPPY_ISSUER` | `https://auth.rxlab.app` |
| `CHIPPY_REDIRECT_URI` | `http://127.0.0.1:53682/callback` |

## Usage

```sh
chippy login     # sign in through the browser
chippy whoami    # show the signed-in account
chippy logout    # sign out and remove the stored session

chippy upload \
  --title "Monarch migration" \
  --summary "Monarch butterflies fly thousands of kilometres south every autumn." \
  --tag butterflies --tag migration \
  --text-file notes.md
```

`upload` signs in first when there is no usable session, and signs in again if the server rejects
the stored token. It prints the share link (`--json` prints the created summary instead).

| Flag | |
|---|---|
| `--title` | required, ≤ 200 characters |
| `--summary` / `--summary-file` | one is required, ≤ 1200 characters |
| `--text` / `--text-file` | the raw source text; one is required, ≤ 200 000 characters |
| `--tag` | repeatable or comma-separated, ≤ 12 |
| `--highlight` | repeatable, ≤ 5 |
| `--keyword` | repeatable or comma-separated, ≤ 10 |
| `--category` | e.g. `Technology`; default `Other` |
| `--language` | BCP-47 code of the title and summary; default `en` |
| `--source-url`, `--source-title`, `--site-name` | where the text came from |
| `--image-style` | `graphic` (default) or `illustration` |
| `--visibility` | `public` (default) or `private` |
| `--ttl-days` | `1`, `3`, `7`, `30`, `90`, `365` or `never` |
| `--json` | print the created summary as JSON |

Pass `-` as a file path to read from stdin:

```sh
pbpaste | chippy upload --title "Notes" --summary "Meeting notes." --text-file -
```

Each upload counts as one summary against the account's allowance.

## Tests

```sh
go -C cli test ./...
```
