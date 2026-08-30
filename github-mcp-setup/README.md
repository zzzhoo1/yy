# GitHub MCP Setup

One-click setup to expose a local GitHub MCP server as a public Streamable HTTP endpoint via Cloudflare Quick Tunnel, for use with Perplexity and other remote MCP clients.

## Architecture

```
Perplexity
   ↓ (HTTPS)
Cloudflare Quick Tunnel (mcp-tunnel.sh)
   ↓ forwards to local :8080
mcp-proxy (Streamable HTTP)  ← mcp-github-http.sh
   ↓ stdio
GitHub MCP server (npx @modelcontextprotocol/server-github)
   ↓
GitHub API
```

## Files

- `setup-github-mcp.sh` — main setup script (install/start/stop/status/url/test)
- `mcp-github-http.sh` — manages the local mcp-proxy bridge (port 8080)
- `mcp-tunnel.sh` — manages the Cloudflare Quick Tunnel for port 8080

## Usage

```bash
chmod +x setup-github-mcp.sh
./setup-github-mcp.sh install   # full setup
./setup-github-mcp.sh status    # view status & public URL
./setup-github-mcp.sh test      # real GitHub call test
./setup-github-mcp.sh stop      # stop everything
./setup-github-mcp.sh start     # restart
./setup-github-mcp.sh url       # print public MCP URL
```

## Prerequisites

- Node.js / npx
- cloudflared
- `GITHUB_TOKEN` env var (or in `~/.openclaw/.env`)

## API Key Authentication

The public endpoint is protected by an API key. Requests without a valid key return `401`.

- Key is stored at `/root/.mcp-api-key` (or override with `MCP_API_KEY` env var).
- Send it via the `X-API-Key` header.

## Perplexity configuration

Perplexity's `mcp` tool supports an `authorization` field for the bearer token. For the `X-API-Key` header, use the `headers` field:

```json
{
  "type": "mcp",
  "server_label": "github",
  "server_url": "https://<your-tunnel>.trycloudflare.com/mcp",
  "headers": { "X-API-Key": "<your-api-key>" }
}
```

Transport: **Streamable HTTP**.
