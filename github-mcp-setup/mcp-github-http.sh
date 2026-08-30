#!/usr/bin/env bash
set -u
PORT="${MCP_HTTP_PORT:-8080}"
LOG_FILE=/var/log/mcp-github-http.log
PID_FILE=/var/run/mcp-github-http.pid
API_KEY_FILE=/root/.mcp-api-key
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f /root/.openclaw/.env ]; then
  export GITHUB_TOKEN="$(grep -E '^GITHUB_TOKEN=' /root/.openclaw/.env | head -1 | cut -d= -f2-)"
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
  status) status ;;
  *)      echo "用法: $0 {start|stop|status}"; exit 1 ;;
esac
