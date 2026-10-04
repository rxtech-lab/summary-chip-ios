# MCP server (macOS)

The Mac app has a built-in [Model Context Protocol](https://modelcontextprotocol.io) server. With it, AI
agents on the same Mac (Claude Code, Claude Desktop, Cursor and others) can add summaries to your library,
search it in natural language and list it by filter. Agents act as the account signed in to Chippy. There
is no separate sign-in, and nothing to install.

## Turning it on

**Settings → Integrations → MCP Server → Configure…** opens a sheet where you can:

- turn the server on or off. The setting is remembered, and the server starts when Chippy launches;
- change the port (default `47823`);
- copy the endpoint URL (`http://127.0.0.1:<port>/mcp`) and the access token;
- regenerate the token. Agents set up with the old token stop working;
- copy a ready-made configuration for Claude Code, Claude Desktop, or any agent that reads JSON MCP
  configuration (Cursor, VS Code, a project's `.mcp.json`).

The server only runs while Chippy is open. It binds to the loopback interface, so other machines can't
reach it. Every request must send `Authorization: Bearer <token>`, which keeps other apps on the Mac out.
The token is a random 256-bit value stored in the keychain.

### Claude Code

```sh
claude mcp add --transport http chippy http://127.0.0.1:47823/mcp \
  --header "Authorization: Bearer <token>"
# add --scope user to use it in every project
```

### Cursor, VS Code, `.mcp.json`

```json
{
  "mcpServers": {
    "chippy": {
      "type": "http",
      "url": "http://127.0.0.1:47823/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

### Claude Desktop

Claude Desktop's config file only starts stdio servers, so it reaches the HTTP endpoint through
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote), which needs Node.js:

```json
{
  "mcpServers": {
    "chippy": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://127.0.0.1:47823/mcp", "--header", "Authorization: Bearer <token>"]
    }
  }
}
```

## Tools

| Tool | What it does | API call |
|---|---|---|
| `add_summary` | Saves a summary the agent wrote, with key points, tags and the raw source text. Nothing is re-summarised. | `POST /api/v1/summaries/import` |
| `search_summaries` | Natural-language search (meaning + keywords), most relevant first. | `GET /api/v1/summaries?q=…` |
| `list_summaries` | The library newest first, filtered. Follows cursors internally, up to 200 per call. | `GET /api/v1/summaries` |

`search_summaries` and `list_summaries` accept the same filters: `source` (`web`, `x`, `facebook`,
`youtube`, `github`, `pdf`, `text`), `category`, `tag`, `visibility` (`public` / `private`) and `scope`
(`all`, `mine` or `viewed`). Both return `{count, items, nextCursor}`. Pass `nextCursor` back as `cursor`
to get the next page. Each item has `id`, `title`, `summary`, `keyPoints`, `category`, `tags`, `source`,
`sourceUrl`, `sourceTitle`, `siteName`, `shareUrl`, `visibility`, `language`, `isOwner`, `hasSourceText`,
`createdAt` and `viewedAt`.

`add_summary` takes `title`, `summary` and `text` (all required), plus optional `keyPoints` (≤ 5), `tags`
(≤ 12), `keywords` (≤ 10), `category`, `language`, `sourceUrl`, `sourceTitle`, `siteName`, `visibility`,
`ttlDays` (`1`, `3`, `7`, `30`, `90`, `365` or `"never"`) and `allowDuplicate`. The server limits are
listed under [Import body](ARCHITECTURE.md#import-body). Added chips always get an illustrated cover. Each
one counts against the summary allowance, and the open library refreshes so the new chip shows up.

A chip that is already in the library (`409 DUPLICATE_SUMMARY`) comes back as a tool error. The message
names the existing chip and its link, and suggests `allowDuplicate: true`. When the app is signed out,
every tool returns an error asking the user to sign in to Chippy.

## Implementation

| File | Role |
|---|---|
| `summary-chip/MCP/MCPHTTPServer.swift` | Network.framework listener on loopback. It checks the bearer token, then gives each session its own `Server` + `StatefulHTTPServerTransport` ([swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)), keyed by `MCP-Session-Id` |
| `summary-chip/MCP/ChippyMCPTools.swift` | Tool catalog, argument validation, and mapping to `SummaryAPIClient` |
| `summary-chip/MCP/MCPServerController.swift` | On/off, port, and keychain token. Starts the server at launch when it's enabled |
| `summary-chip/MCP/MCPSettingsSheet.swift` | The settings sheet |
| `summary-chipTests/MCPServerTests.swift` | End-to-end over HTTP against a stubbed `/api/v1` |

The app is sandboxed, so it needs the `com.apple.security.network.server` entitlement to listen. The
whole feature is compiled only for macOS. The `MCP` package is linked with `destinationFilters: [macOS]`.

Check the endpoint by hand. Expect `401` without the token, then an SSE response with the server's
capabilities:

```sh
curl -i http://127.0.0.1:47823/mcp \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
```
