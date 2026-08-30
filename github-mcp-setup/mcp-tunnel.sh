#!/usr/bin/env bash
set -u
TARGET="${MCP_TUNNEL_TARGET:-http://127.0.0.1:8080}"
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
