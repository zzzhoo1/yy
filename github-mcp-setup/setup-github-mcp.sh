#!/usr/bin/env bash
#
# setup-github-mcp.sh - 一键搭建「GitHub MCP → HTTP → Cloudflare 隧道」链路
#
# 目标: 把本地 stdio 的 GitHub MCP server 包装成 Streamable HTTP 端点，
#       并通过 Cloudflare Quick Tunnel 暴露到公网，供 Perplexity 等远程
#       MCP 客户端连接。
#
# 架构:
#   Perplexity → Cloudflare Quick Tunnel → mcp-proxy (:8080) → GitHub MCP (stdio) → GitHub API
#
# 用法:
#   /root/setup-github-mcp.sh install    完整搭建（检查依赖→启动组件→验证）
#   /root/setup-github-mcp.sh status     查看所有组件状态与公网 URL
#   /root/setup-github-mcp.sh start      启动所有组件（幂等）
#   /root/setup-github-mcp.sh stop       停止所有组件
#   /root/setup-github-mcp.sh url        打印 MCP 公网 URL
#   /root/setup-github-mcp.sh test       对公网端点做一次真实调用测试
#
# 依赖: node/npx, cloudflared, 网络
# 日志: /var/log/mcp-github-http.log, /var/log/cloudflared-mcp.log
#
set -u

# ---------- 配置 ----------
MCP_HTTP_PORT="${MCP_HTTP_PORT:-8080}"
AUTH_PROXY_PORT="${AUTH_PROXY_PORT:-8081}"
MCP_TUNNEL_TARGET="http://127.0.0.1:${AUTH_PROXY_PORT}"
ENV_FILE=/root/.openclaw/.env
MCP_PROXY_SCRIPT=/root/mcp-github-http.sh
AUTH_PROXY_SCRIPT=/root/auth-proxy.sh
MCP_TUNNEL_SCRIPT=/root/mcp-tunnel.sh
GATEWAY_TUNNEL_SCRIPT=/root/start-tunnel.sh
LOG_FILE=/var/log/mcp-github-http.log

# ---------- 工具函数 ----------
log()  { echo -e "\033[1;34m[$1]\033[0m $2"; }
ok()   { echo -e "\033[1;32m  ✓\033[0m $1"; }
fail() { echo -e "\033[1;31m  ✗\033[0m $1"; }

# 从 ~/.openclaw/.env 加载 GITHUB_TOKEN
load_token() {
  if [ -z "${GITHUB_TOKEN:-}" ] && [ -f "$ENV_FILE" ]; then
    export GITHUB_TOKEN="$(grep -E '^GITHUB_TOKEN=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
  fi
}

# ---------- 依赖检查 ----------
check_deps() {
  log "CHECK" "检查依赖..."
  local ok_all=1

  if command -v node >/dev/null 2>&1; then
    ok "node: $(node --version)"
  else
    fail "node 未安装"; ok_all=0
  fi

  if command -v npx >/dev/null 2>&1; then
    ok "npx 可用"
  else
    fail "npx 未安装"; ok_all=0
  fi

  if command -v cloudflared >/dev/null 2>&1; then
    ok "cloudflared: $(cloudflared --version 2>/dev/null | head -1)"
  else
    fail "cloudflared 未安装 (可运行: curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg ... )"; ok_all=0
  fi

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    ok "GITHUB_TOKEN 已配置"
  else
    fail "GITHUB_TOKEN 未配置 (写入 $ENV_FILE)"
    ok_all=0
  fi

  [ "$ok_all" -eq 1 ] && return 0 || return 1
}

# ---------- 组件脚本生成 ----------
write_mcp_proxy_script() {
  cat > "$MCP_PROXY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -u
PORT="${MCP_HTTP_PORT:-8080}"
LOG_FILE=/var/log/mcp-github-http.log
PID_FILE=/var/run/mcp-github-http.pid
API_KEY_FILE=/root/.mcp-api-key
if [ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ] && [ -f /root/.openclaw/.env ]; then
  export GITHUB_PERSONAL_ACCESS_TOKEN="$(grep -E '^GITHUB_TOKEN=' /root/.openclaw/.env | head -1 | cut -d= -f2-)"
fi
# 读取 API key（若存在）
API_KEY_ARG=""
if [ -n "${MCP_API_KEY:-}" ]; then
  API_KEY_ARG="--apiKey $MCP_API_KEY"
elif [ -f "$API_KEY_FILE" ]; then
  API_KEY_ARG="--apiKey $(cat "$API_KEY_FILE")"
fi
is_running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }
start() {
  if is_running; then echo "已运行 (pid $(cat "$PID_FILE"))"; return 0; fi
  echo "启动 GitHub MCP HTTP 桥接 (端口 $PORT) ..."
  nohup npx -y mcp-proxy --port "$PORT" --host 0.0.0.0 $API_KEY_ARG \
    -- npx -y @modelcontextprotocol/server-github \
    >> "$LOG_FILE" 2>&1 &
  echo "$!" > "$PID_FILE"
  sleep 8
  if is_running; then
    echo "已启动 (pid $(cat "$PID_FILE"))"
    echo "本机端点: http://127.0.0.1:$PORT/mcp"
  else
    echo "启动失败，查看日志: $LOG_FILE"; tail -5 "$LOG_FILE"; return 1
  fi
}
stop() {
  if is_running; then kill "$(cat "$PID_FILE")" 2>/dev/null; fi
  # 杀掉整个进程树：mcp-proxy 及其 npx/server-github 子进程
  pkill -f "mcp-proxy --port $PORT" 2>/dev/null
  pkill -f "server-github" 2>/dev/null
  rm -f "$PID_FILE"
  sleep 1
  echo "已停止"
}
status() {
  if is_running; then
    echo "状态: 运行中 (pid $(cat "$PID_FILE"))"
    echo "本机端点: http://127.0.0.1:$PORT/mcp"
    echo "日志: $LOG_FILE"
  else
    echo "状态: 未运行"
  fi
}
case "${1:-start}" in
  start)  start ;;
  stop)   stop ;;
  restart) stop; start ;;
  status) status ;;
  *)      echo "用法: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
  chmod +x "$MCP_PROXY_SCRIPT"
}

write_mcp_tunnel_script() {
  cat > "$MCP_TUNNEL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -u
TARGET="${MCP_TUNNEL_TARGET:-http://127.0.0.1:8081}"
LOG_FILE=/var/log/cloudflared-mcp.log
PID_FILE=/var/run/cloudflared-mcp.pid
LOCK_FILE=/var/run/cloudflared-mcp.lock
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")"
is_running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }
start() {
  if is_running; then echo "已运行 (pid $(cat "$PID_FILE"))"; return 0; fi
  echo "启动 MCP 隧道 ($TARGET) ..."
  nohup flock "$LOCK_FILE" bash -c '
    while true; do
      /usr/local/bin/cloudflared tunnel --url '"$TARGET"' --no-autoupdate >> '"$LOG_FILE"' 2>&1
      echo "$(date -u +%FT%TZ) mcp tunnel exited, restarting in 5s" >> '"$LOG_FILE"'
      sleep 5
    done
  ' > /dev/null 2>&1 &
  echo "$!" > "$PID_FILE"
  sleep 8
  if is_running; then
    echo "已启动 (pid $(cat "$PID_FILE"))"
    echo "公网 URL: $(get_url)"
  else
    echo "启动失败，查看日志: $LOG_FILE"; return 1
  fi
}
stop() {
  if is_running; then
    kill "$(cat "$PID_FILE")" 2>/dev/null
    pkill -f "cloudflared tunnel --url http://127.0.0.1:8080" 2>/dev/null
    rm -f "$PID_FILE"
    echo "已停止"
  else
    echo "未在运行"
  fi
}
get_url() { grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" "$LOG_FILE" 2>/dev/null | tail -1; }
status() {
  if is_running; then
    echo "状态: 运行中 (pid $(cat "$PID_FILE"))"
    echo "目标: $TARGET"
    echo "公网 URL: $(get_url)"
    echo "日志: $LOG_FILE"
  else
    echo "状态: 未运行"
  fi
}
case "${1:-start}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  url)    get_url ;;
  *)      echo "用法: $0 {start|stop|status|url}"; exit 1 ;;
esac
EOF
  chmod +x "$MCP_TUNNEL_SCRIPT"
}

write_auth_proxy_script() {
  cat > "$AUTH_PROXY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -u
PORT="${AUTH_PROXY_PORT:-8081}"
UPSTREAM="${AUTH_PROXY_UPSTREAM:-http://127.0.0.1:8080}"
LOG_FILE=/var/log/auth-proxy.log
PID_FILE=/var/run/auth-proxy.pid
is_running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }
start() {
  if is_running; then echo "已运行 (pid $(cat "$PID_FILE"))"; return 0; fi
  echo "启动认证转换代理 (端口 $PORT -> $UPSTREAM) ..."
  nohup env AUTH_PROXY_PORT="$PORT" AUTH_PROXY_UPSTREAM="$UPSTREAM" \
    node /root/auth-proxy.js >> "$LOG_FILE" 2>&1 &
  echo "$!" > "$PID_FILE"
  sleep 2
  if is_running; then
    echo "已启动 (pid $(cat "$PID_FILE"))"
  else
    echo "启动失败，查看日志: $LOG_FILE"; tail -5 "$LOG_FILE"; return 1
  fi
}
stop() {
  if is_running; then kill "$(cat "$PID_FILE")" 2>/dev/null; rm -f "$PID_FILE"; echo "已停止"; else echo "未在运行"; fi
}
status() {
  if is_running; then
    echo "状态: 运行中 (pid $(cat "$PID_FILE"))"
    echo "端口: $PORT -> $UPSTREAM"
    echo "日志: $LOG_FILE"
  else
    echo "状态: 未运行"
  fi
}
case "${1:-start}" in
  start)  start ;;
  stop)   stop ;;
  restart) stop; start ;;
  status) status ;;
  *)      echo "用法: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
  chmod +x "$AUTH_PROXY_SCRIPT"
}

# ---------- 验证 ----------
verify() {
  log "VERIFY" "验证本地与公网 MCP 端点..."
  local ok_all=1
  local key=""
  if [ -n "${MCP_API_KEY:-}" ]; then
    key="$MCP_API_KEY"
  elif [ -f /root/.mcp-api-key ]; then
    key="$(cat /root/.mcp-api-key)"
  fi

  # 1. 本机端点 (auth-proxy 8081)
  if curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:${AUTH_PROXY_PORT}/mcp" \
       -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
       -H "Authorization: Bearer $key" \
       -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"setup","version":"1"}}}' 2>/dev/null | grep -q 200; then
    ok "本机端点 http://127.0.0.1:${AUTH_PROXY_PORT}/mcp 响应 200"
  else
    fail "本机端点无响应"; ok_all=0
  fi

  # 2. 公网端点
  local url
  url="$($MCP_TUNNEL_SCRIPT url 2>/dev/null)"
  if [ -n "$url" ]; then
    if curl -s -o /dev/null -w "%{http_code}" -X POST "$url/mcp" \
         -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
         -H "Authorization: Bearer $key" \
         -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"setup","version":"1"}}}' 2>/dev/null | grep -q 200; then
      ok "公网端点 $url/mcp 响应 200"
    else
      fail "公网端点无响应"; ok_all=0
    fi
  else
    fail "未获取到公网 URL"; ok_all=0
  fi

  [ "$ok_all" -eq 1 ] && return 0 || return 1
}

# ---------- 真实调用测试 ----------
test_call() {
  log "TEST" "对公网端点做一次真实工具调用 (search_repositories)..."
  local url
  url="$($MCP_TUNNEL_SCRIPT url 2>/dev/null)"
  [ -z "$url" ] && { fail "未获取到公网 URL"; return 1; }

  # 读取 API key（若存在）
  local auth_args=()
  if [ -n "${MCP_API_KEY:-}" ]; then
    auth_args=(-H "X-API-Key: $MCP_API_KEY")
  elif [ -f /root/.mcp-api-key ]; then
    auth_args=(-H "X-API-Key: $(cat /root/.mcp-api-key)")
  fi

  # initialize 拿 session
  local sid
  sid=$(curl -s -D - -o /dev/null -X POST "$url/mcp" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    "${auth_args[@]}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' \
    2>/dev/null | grep -i "mcp-session-id:" | tr -d '\r' | awk '{print $2}')

  if [ -z "$sid" ]; then fail "initialize 未返回 session"; return 1; fi

  local resp
  resp=$(curl -s -X POST "$url/mcp" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "Mcp-Session-Id: $sid" \
    "${auth_args[@]}" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_repositories","arguments":{"query":"openclaw"}}}' 2>/dev/null)

  if echo "$resp" | grep -q "total_count"; then
    ok "真实调用成功，GitHub 返回了结果"
    return 0
  else
    fail "真实调用失败"; echo "$resp" | head -c 300; echo; return 1
  fi
}

# ---------- 主流程 ----------
case "${1:-install}" in
  install)
    echo "=============================================="
    echo " GitHub MCP → HTTP → Cloudflare 隧道 搭建脚本"
    echo "=============================================="
    load_token
    check_deps || { echo; echo "依赖缺失，请先安装后重试。"; exit 1; }
    echo
    write_mcp_proxy_script
    write_auth_proxy_script
    write_mcp_tunnel_script
    ok "组件脚本已生成: $MCP_PROXY_SCRIPT, $AUTH_PROXY_SCRIPT, $MCP_TUNNEL_SCRIPT"
    echo
    log "START" "启动 GitHub MCP HTTP 桥接..."
    "$MCP_PROXY_SCRIPT" start || exit 1
    echo
    log "START" "启动认证转换代理..."
    "$AUTH_PROXY_SCRIPT" start || exit 1
    echo
    log "START" "启动 Cloudflare MCP 隧道..."
    "$MCP_TUNNEL_SCRIPT" start || exit 1
    echo
    verify || { echo; echo "验证未通过，请检查日志。"; exit 1; }
    echo
    echo "=============================================="
    echo " 搭建完成！"
    echo " 公网 MCP 端点: $($MCP_TUNNEL_SCRIPT url)/mcp"
    echo "=============================================="
    echo
    echo "在 Perplexity (Agent API) 中配置:"
    echo "  {"
    echo "    \"type\": \"mcp\","
    echo "    \"server_label\": \"github\","
    echo "    \"server_url\": \"$($MCP_TUNNEL_SCRIPT url)/mcp\","
    echo "    \"authorization\": \"<API_KEY>\""
    echo "  }"
    echo
    echo "常用命令:"
    echo "  $0 status    查看状态"
    echo "  $0 test      真实调用测试"
    echo "  $0 stop      停止全部"
    echo "  $0 start     重新启动"
    ;;
  start)
    load_token
    "$MCP_PROXY_SCRIPT" start
    "$AUTH_PROXY_SCRIPT" start
    "$MCP_TUNNEL_SCRIPT" start
    echo "公网 MCP 端点: $($MCP_TUNNEL_SCRIPT url)/mcp"
    ;;
  stop)
    "$MCP_TUNNEL_SCRIPT" stop
    "$AUTH_PROXY_SCRIPT" stop
    "$MCP_PROXY_SCRIPT" stop
    echo "已停止全部组件"
    ;;
  status)
    echo "=== GitHub MCP HTTP 桥接 ==="
    "$MCP_PROXY_SCRIPT" status
    echo
    echo "=== 认证转换代理 ==="
    "$AUTH_PROXY_SCRIPT" status
    echo
    echo "=== Cloudflare MCP 隧道 ==="
    "$MCP_TUNNEL_SCRIPT" status
    echo
    echo "=== 网关隧道 (18789) ==="
    [ -x "$GATEWAY_TUNNEL_SCRIPT" ] && "$GATEWAY_TUNNEL_SCRIPT" status 2>/dev/null || echo "未配置"
    ;;
  url)
    "$MCP_TUNNEL_SCRIPT" url
    ;;
  test)
    load_token
    test_call
    ;;
  *)
    echo "用法: $0 {install|start|stop|status|url|test}"
    exit 1
    ;;
esac
