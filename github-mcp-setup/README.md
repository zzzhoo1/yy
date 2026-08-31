# GitHub MCP Setup

One-click setup to expose a local GitHub MCP server as a public Streamable HTTP endpoint via Cloudflare Quick Tunnel, for use with Perplexity and other remote MCP clients.

## Architecture

```
Perplexity
   ↓ (HTTPS, Authorization: Bearer <key>)
Cloudflare Quick Tunnel (mcp-tunnel.sh)
   ↓ forwards to local :8081
auth-proxy (auth-proxy.js)  ← converts Bearer → X-API-Key
   ↓
mcp-proxy (Streamable HTTP, :8080)  ← mcp-github-http.sh
   ↓ stdio
GitHub MCP server (npx @modelcontextprotocol/server-github)
   ↓
GitHub API
```

The `auth-proxy` layer lets Perplexity authenticate with its native `authorization` field (which sends `Authorization: Bearer <token>`), while the backend `mcp-proxy` only accepts `X-API-Key`. Both auth methods are accepted.

## Files

- `setup-github-mcp.sh` — main setup script (install/start/stop/status/url/test)
- `mcp-github-http.sh` — manages the local mcp-proxy bridge (port 8080)
- `auth-proxy.js` + `auth-proxy.sh` — Bearer→X-API-Key conversion proxy (port 8081)
- `mcp-tunnel.sh` — manages the Cloudflare Quick Tunnel for port 8081

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
- Rotate: `openssl rand -hex 16 > /root/.mcp-api-key && ./mcp-github-http.sh restart`

## Perplexity configuration

Use the `authorization` field (Perplexity sends it as `Authorization: Bearer`):

```json
{
  "type": "mcp",
  "server_label": "github",
  "server_url": "https://<your-tunnel>.trycloudflare.com/mcp",
  "authorization": "<your-api-key>"
}
```

Transport: **Streamable HTTP**.

---

# Caura MCP Setup

One-click local deployment of [Caura](https://github.com/caura-ai/caura) (formerly MemClaw) — a governed shared-memory server for AI agent fleets — exposed to the public via Cloudflare Quick Tunnel for use with Perplexity and other remote MCP clients.

## Architecture

```
Perplexity
   ↓ (HTTPS, Streamable HTTP /mcp)
Cloudflare Quick Tunnel (caura-setup.sh step 5)
   ↓ forwards to local :8000
Caura core-api  (:8000)  ← REST + MCP
   ↓
Caura core-storage-api  (:8002)  → PostgreSQL 16 + pgvector
```

Caura runs in **standalone mode** (`IS_STANDALONE=true`) with fake providers, so no API key is needed. The MCP endpoint exposes 12 tools (`caura_write`, `caura_recall`, `caura_manage`, `caura_list`, `caura_doc`, `caura_entity_get`, `caura_tune`, `caura_insights`, `caura_evolve`, `caura_stats`, `caura_keystones`, `caura_keystones_set`).

## Files

- `caura-setup.sh` — full one-click setup (deps, database, services, tunnel, Claude Code MCP)
- `caura-start.sh` — lightweight start script (storage + api only)

## Usage

```bash
chmod +x caura-setup.sh
./caura-setup.sh            # full setup (idempotent, safe to re-run)
./caura-setup.sh status     # view status & public URL
./caura-setup.sh tunnel-url # print public MCP URL
./caura-setup.sh --no-tunnel  # setup without the tunnel
./caura-setup.sh --no-claude  # setup without registering Claude Code MCP
```

> Tip: run detached so the script isn't killed when your terminal session ends:
> ```bash
> setsid ./caura-setup.sh > /tmp/caura-setup.log 2>&1 < /dev/null &
> ```

## What the script does

1. **System deps** — PostgreSQL 16 + pgvector, Redis, Python 3.12 (via uv), cloudflared, Claude Code
2. **Clone** — `caura-ai/caura`
3. **Database** — create user/db, enable pgvector, run alembic migrations
4. **Services** — core-storage-api (:8002) + core-api (:8000), started with `setsid` so they survive the session ending
5. **Tunnel** — Cloudflare Quick Tunnel exposing :8000 publicly
6. **Claude Code** — register the `caura` MCP server

## Ports

| Service | Port |
|---|---|
| core-api (REST + MCP) | 8000 |
| core-storage-api | 8002 |
| PostgreSQL | 5432 |
| Redis | 6379 |

## Perplexity configuration

Caura is MCP-native. Point Perplexity at the public URL:

```json
{
  "type": "mcp",
  "server_label": "caura",
  "server_url": "https://<your-tunnel>.trycloudflare.com/mcp"
}
```

Transport: **Streamable HTTP**. No API key required in standalone mode (a placeholder `X-API-Key` header is harmless).

> Note: the Quick Tunnel URL is temporary — it changes whenever cloudflared restarts. For a stable URL, use a Cloudflare named tunnel with your own domain.
