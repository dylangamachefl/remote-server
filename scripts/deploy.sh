#!/usr/bin/env bash
# deploy.sh — Pull latest changes and redeploy the homeserver stack
#
# Usage: bash scripts/deploy.sh [--help]

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: bash scripts/deploy.sh

Pulls the latest changes from git and redeploys the homeserver Docker Swarm stack.

Steps:
  1. Source instance.conf for per-instance config
  2. git pull to get latest changes
  3. docker stack deploy to update the running stack
  4. Prune Docker images older than 7 days
  5. Print service status
EOF
    exit 0
fi

# Resolve repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Color helpers (degrade gracefully when piped)
if [ -t 1 ]; then
    GREEN='\033[0;32m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; BLUE=''; BOLD=''; RESET=''
fi

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }

# ---------------------------------------------------------------------------
# Step 1: Source instance.conf
# ---------------------------------------------------------------------------
if [[ ! -f "$REPO_ROOT/instance.conf" ]]; then
    echo "ERROR: instance.conf not found. Run scripts/setup.sh first." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$REPO_ROOT/instance.conf"
info "Instance: ${INSTANCE_NAME:-unknown}"

# ---------------------------------------------------------------------------
# Step 2: Git pull
# ---------------------------------------------------------------------------
info "Pulling latest changes from git..."
git pull
success "Repository up to date."

# ---------------------------------------------------------------------------
# Step 3: Deploy / update the stack
# ---------------------------------------------------------------------------
info "Deploying stack..."
GENERIC_TIMEZONE="${TIMEZONE:-America/New_York}" \
    docker stack deploy -c "$REPO_ROOT/docker-compose.yml" homeserver
success "Stack deployment triggered."

# ---------------------------------------------------------------------------
# Step 4: Prune old images
# ---------------------------------------------------------------------------
info "Pruning Docker images older than 7 days..."
docker image prune -a --force --filter "until=168h" || true
success "Image pruning complete."

# ---------------------------------------------------------------------------
# Step 5: Status
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Service status:${RESET}"
docker service ls
