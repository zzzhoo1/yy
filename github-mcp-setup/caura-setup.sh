#!/bin/bash
# =============================================================================
# Caura 本地搭建 + 内网穿透 一键脚本
# =============================================================================
# 功能：
#   1. 安装系统依赖 (PostgreSQL 16 + pgvector, Redis, Python 3.12, uv, cloudflared, Claude Code)
#   2. 克隆 Caura 仓库并配置
#   3. 创建数据库 + 运行迁移
#   4. 启动 core-storage-api (:8002) + core-api (:8000)
#   5. 启动 Cloudflare Tunnel 暴露 MCP (:8000/mcp) 到公网
#   6. 注册 MCP 到 Claude Code
#
# 用法：
#   ./setup.sh            # 完整搭建（幂等，可重复运行）
#   ./setup.sh --no-tunnel   # 不启动内网穿透
#   ./setup.sh --no-claude   # 不注册 Claude Code MCP
#   ./setup.sh status        # 查看当前运行状态
#   ./setup.sh tunnel-url    # 打印当前公网 URL
# =============================================================================
set -euo pipefail

# ---------- 配置 ----------
WORKSPACE="${CAURA_WORKSPACE:-$(cd "$(dirname "$0")" && pwd)}"
REPO_DIR="$WORKSPACE/caura"
PORT_API=8000
PORT_STORAGE=8002
DB_USER="memclaw"
DB_PASS="${CAURA_DB_PASS:-changeme}"
DB_NAME="memclaw"
SHARED_SECRET="${CAURA_SHARED_SECRET:-local-dev-shared-secret-123}"
# 用固定 secret 便于重复运行；如需随机，改为 $(openssl rand -hex 16)
# SHARED_SECRET="$(openssl rand -hex 16)"

export PATH="$HOME/.local/bin:$PATH"

log()  { echo -e "\033[1;32m[setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
err()  { echo -e "\033[1;31m[error]\033[0m $*"; }

# ---------- 工具函数 ----------
have() { command -v "$1" >/dev/null 2>&1; }

start_service() {
  # $1=name $2=app $3=port $4=logfile
  local name="$1" app="$2" port="$3" logfile="$4"
  if curl -sf "http://localhost:$port/api/v1/health" >/dev/null 2>&1 || \
     curl -sf "http://localhost:$port/readyz" >/dev/null 2>&1; then
    log "$name already running on :$port"
    return 0
  fi
  log "Starting $name on :$port"
  # setsid detaches from the calling process group so the service survives
  # the exec session ending (SIGTERM to the group would otherwise kill it).
  ( cd "$REPO_DIR" && \
    CORE_STORAGE_SHARED_SECRET="$SHARED_SECRET" \
    EMBEDDING_PROVIDER="local" \
    ENTITY_EXTRACTION_PROVIDER="openai" \
    OPENAI_API_KEY="localhost-proxy-api-key-not-real" \
    OPENAI_CHAT_BASE_URL="http://172.17.0.1:3001/v1" \
    ENTITY_EXTRACTION_MODEL="gpt-5.6" \
    LLM_FALLBACK_MODEL_OPENAI="gpt-5.6" \
    USE_LLM_FOR_MEMORY_CREATION="true" \
    PYTHONPATH="$REPO_DIR/common:$REPO_DIR/core-storage-api/src:$REPO_DIR/core-api/src" \
    setsid "$REPO_DIR/venv/bin/python" -m uvicorn "$app" --host 0.0.0.0 --port "$port" \
      > "$logfile" 2>&1 < /dev/null & )
  echo $! > "/tmp/caura-${name}.pid"
}

# =============================================================================
# 1. 系统依赖
# =============================================================================
install_system_deps() {
  log "=== 1/6 安装系统依赖 ==="

  if ! have curl; then
    log "Installing curl"
    apt-get update -qq && apt-get install -y -qq curl
  fi

  # PostgreSQL 16 (PGDG repo) —— Debian 12 默认只有 15
  if ! have psql || ! psql --version | grep -q "16\."; then
    log "Adding PGDG repo + installing PostgreSQL 16"
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list
    apt-get update -qq
  fi

  # 基础包（幂等）
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    postgresql-16 postgresql-client-16 postgresql-16-pgvector \
    python3 python3-pip python3-venv \
    redis-server \
    build-essential libpq-dev postgresql-common \
    openssl 2>&1 | tail -2 || true

  # Python 3.12 —— 用 uv 安装（Caura 需要 3.12+，PEP 695 语法）
  if ! have uv; then
    log "Installing uv"
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  if ! "$HOME/.local/bin/python3.12" --version >/dev/null 2>&1; then
    log "Installing Python 3.12 via uv"
    uv python install 3.12
  fi

  # cloudflared —— 内网穿透
  if ! have cloudflared; then
    log "Installing cloudflared"
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
  fi

  # Claude Code —— MCP 客户端
  if ! have claude; then
    log "Installing Claude Code"
    npm install -g @anthropic-ai/claude-code 2>&1 | tail -1 || true
  fi

  # 本地 embedding 依赖（bge-m3）：sentence-transformers + torch (CPU)
  if ! "$REPO_DIR/venv/bin/python" -c "import sentence_transformers" 2>/dev/null; then
    log "Installing sentence-transformers + torch (CPU) for local embeddings"
    ( cd "$REPO_DIR" && \
      uv pip install --python "$REPO_DIR/venv/bin/python" \
        --index-url https://download.pytorch.org/whl/cpu torch 2>&1 | tail -1 && \
      uv pip install --python "$REPO_DIR/venv/bin/python" sentence-transformers 2>&1 | tail -1 )
  fi
}

# =============================================================================
# 2. 克隆仓库
# =============================================================================
clone_repo() {
  log "=== 2/6 克隆 Caura 仓库 ==="
  if [ ! -d "$REPO_DIR/.git" ]; then
    git clone --depth 1 https://github.com/caura-ai/caura.git "$REPO_DIR"
  else
    log "Repo already exists, skipping clone"
  fi
}

# =============================================================================
# 3. 数据库 + venv + 迁移
# =============================================================================
setup_database_and_env() {
  log "=== 3/6 配置数据库 + Python 环境 ==="

  # 启动 PostgreSQL / Redis
  pg_ctlcluster 16 main start 2>/dev/null || service postgresql start 2>/dev/null || true
  redis-server --daemonize yes 2>/dev/null || true

  # 创建 DB 用户和库（幂等）
  su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\" | grep -q 1" 2>/dev/null || \
    su - postgres -c "psql -c \"CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';\""
  su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\" | grep -q 1" 2>/dev/null || \
    su - postgres -c "psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER;\""
  su - postgres -c "psql -d $DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS vector;'" 2>/dev/null || true

  # 创建 venv (Python 3.12)
  if [ ! -d "$REPO_DIR/venv" ]; then
    log "Creating venv with Python 3.12"
    ( cd "$REPO_DIR" && uv venv --python 3.12 venv )
  fi

  # 安装依赖 —— 从各服务 pyproject.toml（requirements.txt 不完整）
  log "Installing dependencies (this may take a few minutes)"
  ( cd "$REPO_DIR" && \
    uv pip install --python "$REPO_DIR/venv/bin/python" \
      -e "core-api/" -e "core-storage-api/" -e "core-worker/" -e "core-operations/" \
      -r requirements.txt 2>&1 | tail -3 )

  # 写 .env
  cat > "$REPO_DIR/.env" << EOF
ENVIRONMENT=development
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASS
POSTGRES_DB=$DB_NAME
POSTGRES_REQUIRE_SSL=false
IS_STANDALONE=true
EMBEDDING_PROVIDER=local
ENTITY_EXTRACTION_PROVIDER=openai
USE_LLM_FOR_MEMORY_CREATION=true
CORS_ORIGINS=http://localhost:8000,http://localhost:3000
REDIS_URL=redis://127.0.0.1:6379/0
CORE_STORAGE_SHARED_SECRET=$SHARED_SECRET
OPENAI_API_KEY=localhost-proxy-api-key-not-real
OPENAI_CHAT_BASE_URL=http://172.17.0.1:3001/v1
ENTITY_EXTRACTION_MODEL=gpt-5.6
LLM_FALLBACK_MODEL_OPENAI=gpt-5.6
EOF
  log ".env written"

  # 运行迁移
  log "Running database migrations"
  ( cd "$REPO_DIR" && \
    PYTHONPATH="$REPO_DIR/common:$REPO_DIR/core-storage-api/src:$REPO_DIR/core-api/src" \
    "$REPO_DIR/venv/bin/python" -c "
import sys
sys.path.insert(0, '$REPO_DIR/common')
sys.path.insert(0, '$REPO_DIR/core-storage-api/src')
sys.path.insert(0, '$REPO_DIR/core-api/src')
from alembic.config import Config
from alembic import command
command.upgrade(Config('alembic.ini'), 'head')
" 2>&1 | tail -3 )
}

# =============================================================================
# 4. 启动服务
# =============================================================================
start_services() {
  log "=== 4/6 启动 Caura 服务 ==="
  start_service "storage" "core_storage_api.app:app" "$PORT_STORAGE" "/tmp/caura-storage.log"
  sleep 3
  start_service "api" "core_api.app:app" "$PORT_API" "/tmp/caura-api.log"
  sleep 8
  log "Health: $(curl -s http://localhost:$PORT_API/api/v1/health)"
  # 预热本地 embedding 模型（bge-m3 首次加载 ~8s，会超 10s 请求超时导致 504）。
  # 提前触发一次搜索让模型加载进内存，后续请求即时响应。
  if grep -q "EMBEDDING_PROVIDER=local" "$REPO_DIR/.env" 2>/dev/null; then
    log "Warming up local embedding model (bge-m3)..."
    curl -s -m 60 -X POST "http://localhost:$PORT_API/api/v1/search" \
      -H "X-API-Key: ***" -H "Content-Type: application/json" \
      -d '{"tenant_id":"default","query":"warmup","top_k":1}' > /dev/null 2>&1
    log "Model warmup done"
  fi
}

# =============================================================================
# 5. 内网穿透
# =============================================================================
start_tunnel() {
  log "=== 5/6 启动 Cloudflare Tunnel ==="
  if ! curl -sf "http://localhost:8000/api/v1/health" >/dev/null 2>&1; then
    warn "Caura API not up yet, skipping tunnel"
    return 0
  fi
  # 只认我们自己的 tunnel 进程（通过 PID 文件），避免被系统预置的
  # cloudflared（指向其它端口）干扰。
  local our_pid
  our_pid=$(cat /tmp/caura-tunnel.pid 2>/dev/null || echo "")
  if [ -n "$our_pid" ] && kill -0 "$our_pid" 2>/dev/null; then
    log "Tunnel already running: $(grep -oP 'https://\S+\.trycloudflare\.com' /tmp/cloudflared.log | head -1)"
    return 0
  fi
  log "Starting quick tunnel -> http://localhost:8000"
  setsid cloudflared tunnel --url http://localhost:8000 > /tmp/cloudflared.log 2>&1 < /dev/null &
  echo $! > /tmp/caura-tunnel.pid
  sleep 8
  local url
  url=$(grep -oP 'https://\S+\.trycloudflare\.com' /tmp/cloudflared.log | head -1)
  log "Public MCP URL: $url/mcp"
}

# =============================================================================
# 6. Claude Code MCP 注册
# =============================================================================
register_claude() {
  log "=== 6/6 注册 Claude Code MCP ==="
  if have claude && curl -sf "http://localhost:8000/api/v1/health" >/dev/null 2>&1; then
    claude mcp add --transport http -s user caura http://localhost:8000/mcp \
      --header "X-API-Key: ***" 2>&1 | grep -E "Added|already" || true
    log "Claude MCP:"
    claude mcp list 2>&1 | grep caura || true
  else
    warn "claude not installed or API not up, skipping"
  fi
}

# =============================================================================
# 状态 / 工具命令
# =============================================================================
show_status() {
  echo "=== Caura 服务状态 ==="
  echo -n "core-api  (:8000): "; curl -sf http://localhost:8000/api/v1/health >/dev/null 2>&1 && echo "UP" || echo "DOWN"
  echo -n "storage   (:8002): "; curl -sf http://localhost:8002/readyz >/dev/null 2>&1 && echo "UP" || echo "DOWN"
  echo -n "redis     (:6379): "; redis-cli ping 2>/dev/null || echo "DOWN"
  echo -n "postgres  (:5432): "; pg_lsclusters 2>/dev/null | grep -q online && echo "UP" || echo "DOWN"
  echo -n "tunnel: "; { [ -n "$(cat /tmp/caura-tunnel.pid 2>/dev/null)" ] && kill -0 "$(cat /tmp/caura-tunnel.pid)" 2>/dev/null; } && echo "UP" || echo "DOWN"
  echo ""
  echo "=== 公网 MCP URL ==="
  grep -oP 'https://\S+\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1 | sed 's|$|/mcp|'
  echo ""
  echo "=== Claude MCP ==="
  claude mcp list 2>&1 | grep caura || echo "(not registered)"
}

tunnel_url() {
  grep -oP 'https://\S+\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1 | sed 's|$|/mcp|'
}

# =============================================================================
# 主流程
# =============================================================================
TUNNEL=1
CLAUDE=1

case "${1:-}" in
  status)  show_status; exit 0 ;;
  tunnel-url) tunnel_url; exit 0 ;;
  --no-tunnel) TUNNEL=0 ;;
  --no-claude) CLAUDE=0 ;;
  -h|--help)
    grep "^#" "$0" | sed 's/^# \{0,1\}//' | head -40
    exit 0 ;;
esac

install_system_deps
clone_repo
setup_database_and_env
start_services
[ "$TUNNEL" = 1 ] && start_tunnel
[ "$CLAUDE" = 1 ] && register_claude

log "==========================================="
log "✅ 搭建完成！"
log "   本地 API:   http://localhost:$PORT_API"
log "   本地 MCP:   http://localhost:$PORT_API/mcp"
[ "$TUNNEL" = 1 ] && log "   公网 MCP:   $(tunnel_url)"
log "   状态查看:   $0 status"
log "==========================================="
