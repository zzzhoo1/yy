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
