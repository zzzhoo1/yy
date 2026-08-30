# GitHub MCP Setup

一键搭建「GitHub MCP → Streamable HTTP → Cloudflare Quick Tunnel」链路，
把本地 stdio 的 GitHub MCP server 暴露为公网可访问的 MCP 端点，
供 Perplexity 等远程 MCP 客户端连接。

## 架构

```
Perplexity
   ↓ (HTTPS)
Cloudflare Quick Tunnel (mcp-tunnel.sh)
   ↓ 转发到本机 :8080
mcp-proxy (Streamable HTTP)  ← mcp-github-http.sh
   ↓ stdio
GitHub MCP server (npx @modelcontextprotocol/server-github)
   ↓
GitHub API
```

## 文件

- `setup-github-mcp.sh` — 主搭建脚本（install/start/stop/status/url/test）
- `mcp-github-http.sh` — 管理本地 mcp-proxy 桥接（端口 8080）
- `mcp-tunnel.sh` — 管理 8080 的 Cloudflare Quick Tunnel

## 用法

```bash
chmod +x setup-github-mcp.sh
./setup-github-mcp.sh install   # 完整搭建
./setup-github-mcp.sh status    # 查看状态与公网 URL
./setup-github-mcp.sh test      # 真实 GitHub 调用测试
./setup-github-mcp.sh stop      # 停止全部
./setup-github-mcp.sh start     # 重新启动
./setup-github-mcp.sh url       # 打印公网 MCP URL
```

## 前置条件

- Node.js / npx
- cloudflared
- `GITHUB_TOKEN` 环境变量（或写入 `~/.openclaw/.env`）

## 在 Perplexity 中配置

```json
{
  "type": "mcp",
  "server_label": "github",
  "server_url": "https://<your-tunnel>.trycloudflare.com/mcp"
}
```

Transport 选择 **Streamable HTTP**。
