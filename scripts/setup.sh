#!/usr/bin/env bash
# setup.sh — First-time VPS bootstrap for home-server
#
# Usage: bash scripts/setup.sh [--help]
#
# This script installs Docker, initializes Docker Swarm, creates Docker secrets,
# deploys the stack, and configures cron jobs. It is safe to run multiple times.

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; BLUE=''; BOLD=''; RESET=''
fi

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${BLUE}==> $*${RESET}"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: bash scripts/setup.sh

First-time VPS bootstrap for home-server Docker Swarm stack.

This script will:
  1.  Verify OS compatibility
  2.  Install Docker Engine and Docker Compose plugin
  3.  Initialize Docker Swarm
  4.  Create instance.conf from the example template
  5.  Create all required Docker secrets interactively
  6.  Set up OpenClaw configuration
  7.  Apply Docker daemon configuration
  8.  Create backup directory
  9.  Deploy the homeserver stack
  10. Wait for services to start
  11. Set up backup and monitoring cron jobs

Safe to re-run — existing configuration and secrets are preserved.
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# Must run as root (or with sudo)
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root. Try: sudo bash scripts/setup.sh"
    exit 1
fi

# Resolve the repo root regardless of where the script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Step 1: OS check
# ---------------------------------------------------------------------------
header "Step 1: Checking operating system"

OS_OK=false
if command -v lsb_release &>/dev/null; then
    DISTRO=$(lsb_release -si)
    VERSION=$(lsb_release -sr)
    info "Detected: $DISTRO $VERSION"
    if [[ "$DISTRO" == "Ubuntu" ]] && dpkg --compare-versions "$VERSION" ge "22.04"; then
        OS_OK=true
    elif [[ "$DISTRO" == "Debian" ]] && dpkg --compare-versions "$VERSION" ge "12"; then
        OS_OK=true
    fi
fi

if [[ "$OS_OK" == false ]]; then
    warn "This script is tested on Ubuntu 22.04+ and Debian 12+."
    warn "Your OS may not be fully supported."
    read -r -p "Continue anyway? [y/N] " answer
    [[ "${answer,,}" == "y" ]] || { info "Aborted."; exit 0; }
else
    success "OS is supported."
fi

# ---------------------------------------------------------------------------
# Step 2: Install Docker
# ---------------------------------------------------------------------------
header "Step 2: Installing Docker Engine"

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    success "Docker and Docker Compose plugin are already installed."
    docker --version
    docker compose version
else
    info "Installing Docker Engine from Docker's official repository..."

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || \
      curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    chmod a+r /etc/apt/keyrings/docker.gpg

    # Detect distro for repo URL
    if lsb_release -si | grep -qi ubuntu; then
        DOCKER_REPO_DISTRO="ubuntu"
    else
        DOCKER_REPO_DISTRO="debian"
    fi

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/$DOCKER_REPO_DISTRO \
      $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker
    success "Docker installed successfully."
    docker --version
fi

# ---------------------------------------------------------------------------
# Step 3: Initialize Docker Swarm
# ---------------------------------------------------------------------------
header "Step 3: Initializing Docker Swarm"

if docker info 2>/dev/null | grep -q "Swarm: active"; then
    success "Docker Swarm is already initialized."
else
    info "Initializing Docker Swarm..."
    docker swarm init
    success "Docker Swarm initialized."
fi

# ---------------------------------------------------------------------------
# Step 4: instance.conf setup
# ---------------------------------------------------------------------------
header "Step 4: Configuring instance.conf"

if [[ ! -f "$REPO_ROOT/instance.conf" ]]; then
    cp "$REPO_ROOT/instance.conf.example" "$REPO_ROOT/instance.conf"
    info "Created instance.conf from template."
    info "Please review and edit instance.conf before continuing."
    EDITOR="${EDITOR:-nano}"
    read -r -p "Press Enter to open instance.conf in $EDITOR (or Ctrl+C to edit manually)..."
    "$EDITOR" "$REPO_ROOT/instance.conf"
else
    success "instance.conf already exists. Skipping."
fi

# Source instance.conf
# shellcheck source=/dev/null
source "$REPO_ROOT/instance.conf"

# ---------------------------------------------------------------------------
# Step 5: Create Docker secrets
# ---------------------------------------------------------------------------
header "Step 5: Creating Docker secrets"

_secret_exists() {
    docker secret ls --format '{{.Name}}' | grep -qx "$1"
}

_create_secret() {
    local name="$1"
    local description="$2"
    local hint="$3"
    local can_autogenerate="${4:-false}"
    local optional="${5:-false}"

    if _secret_exists "$name"; then
        success "Secret '$name' already exists. Skipping."
        return 0
    fi

    echo ""
    echo -e "${BOLD}Secret: $name${RESET}"
    echo "  Purpose: $description"
    echo "  $hint"

    local value=""

    if [[ "$can_autogenerate" == "true" ]]; then
        read -r -p "  Auto-generate a strong random value? [Y/n] " autogen
        if [[ "${autogen,,}" != "n" ]]; then
            value="$(openssl rand -base64 32)"
            echo "$value" | docker secret create "$name" - > /dev/null
            success "Secret '$name' created (auto-generated)."
            return 0
        fi
    fi

    if [[ "$optional" == "true" ]]; then
        echo "  This secret is optional — press Enter without a value to skip."
    fi

    while true; do
        read -r -s -p "  Enter value: " value
        echo ""
        if [[ -z "$value" ]]; then
            if [[ "$optional" == "true" ]]; then
                warn "Skipped '$name'. Add it later with:"
                warn "  bash scripts/secrets-helper.sh add $name"
                return 0
            else
                warn "Value cannot be empty. Please try again."
            fi
        else
            break
        fi
    done

    echo "$value" | docker secret create "$name" - > /dev/null
    success "Secret '$name' created."
    return 0
}

_create_secret "postgres_password" \
    "PostgreSQL database password" \
    "Used internally — never exposed publicly." \
    "true"

_create_secret "n8n_encryption_key" \
    "n8n encryption key for stored credentials" \
    "Used to encrypt API keys stored in n8n. Keep a backup of this value!" \
    "true"

_create_secret "anthropic_api_key" \
    "Anthropic API key for Claude access (shared by n8n and OpenClaw)" \
    "Get yours at: https://console.anthropic.com → API Keys" \
    "false"

_create_secret "slack_bot_token" \
    "Slack Bot OAuth token for n8n alerts and HITL approvals" \
    "Create a Slack app at https://api.slack.com/apps → OAuth & Permissions → Bot Token (xoxb-...)" \
    "false"

_create_secret "cloudflare_tunnel_token" \
    "Cloudflare Tunnel token" \
    "In Cloudflare Zero Trust dashboard → Networks → Tunnels → Create tunnel → copy the token" \
    "false"

# OpenClaw chat token — platform-specific hint, skippable
OPENCLAW_PLATFORM="${OPENCLAW_CHAT_PLATFORM:-telegram}"
case "$OPENCLAW_PLATFORM" in
    telegram)
        CHAT_HINT="Message @BotFather on Telegram, send /newbot, and follow the prompts. Copy the token it provides (looks like 123456:ABCdef...)." ;;
    whatsapp)
        CHAT_HINT="Requires a WhatsApp Business API account. Find your API token in the Meta Business dashboard → WhatsApp → API Setup." ;;
    slack)
        CHAT_HINT="Create a Slack app at https://api.slack.com/apps → OAuth & Permissions → Bot Token (xoxb-...)." ;;
    discord)
        CHAT_HINT="Create a Discord bot at https://discord.com/developers/applications → Bot → Reset Token." ;;
    signal)
        CHAT_HINT="Requires signal-cli or a Signal API bridge. Consult your OpenClaw version's documentation." ;;
    *)
        CHAT_HINT="Consult your OpenClaw documentation for the '$OPENCLAW_PLATFORM' platform token format." ;;
esac

echo ""
info "OpenClaw messaging platform: ${BOLD}${OPENCLAW_PLATFORM}${RESET}"
info "You can skip this now — the rest of the stack will deploy fine without it."
info "OpenClaw will not start until this secret is created."

_create_secret "openclaw_chat_token" \
    "OpenClaw messaging platform token ($OPENCLAW_PLATFORM bot token)" \
    "$CHAT_HINT" \
    "false" \
    "true"

# ---------------------------------------------------------------------------
# Step 6: Set up OpenClaw configuration
# ---------------------------------------------------------------------------
header "Step 6: Setting up OpenClaw configuration"

OPENCLAW_CONFIG="$REPO_ROOT/openclaw/openclaw.config"
OPENCLAW_CONFIG_EXAMPLE="$REPO_ROOT/openclaw/openclaw.config.example"

if [[ -f "$OPENCLAW_CONFIG" ]]; then
    success "openclaw/openclaw.config already exists. Skipping."
else
    cp "$OPENCLAW_CONFIG_EXAMPLE" "$OPENCLAW_CONFIG"
    info "Created openclaw/openclaw.config from template."

    # Inject values from instance.conf using sed
    OPENCLAW_MDL="${OPENCLAW_MODEL:-claude-sonnet-4-5-20250929}"
    OPENCLAW_OWNER="${OPENCLAW_OWNER_ID:-}"

    sed -i "s|  platform: telegram.*|  platform: $OPENCLAW_PLATFORM|" "$OPENCLAW_CONFIG"
    sed -i "s|  owner_id: \"\".*|  owner_id: \"$OPENCLAW_OWNER\"|" "$OPENCLAW_CONFIG"
    sed -i "s|  name: claude-sonnet-4-5-20250929|  name: $OPENCLAW_MDL|" "$OPENCLAW_CONFIG"

    success "openclaw.config created (platform=$OPENCLAW_PLATFORM, model=$OPENCLAW_MDL)"

    if [[ -z "$OPENCLAW_OWNER" ]]; then
        warn "OPENCLAW_OWNER_ID is not set in instance.conf!"
        warn "Edit openclaw/openclaw.config and set 'owner_id' before starting OpenClaw."
        warn "Without this, OpenClaw may respond to messages from anyone."
    fi
fi

# ---------------------------------------------------------------------------
# Step 7: Apply Docker daemon config
# ---------------------------------------------------------------------------
header "Step 7: Applying Docker daemon configuration"

DAEMON_JSON_SRC="$REPO_ROOT/config/docker-daemon.json"
DAEMON_JSON_DST="/etc/docker/daemon.json"

if [[ -f "$DAEMON_JSON_DST" ]]; then
    if diff -q "$DAEMON_JSON_SRC" "$DAEMON_JSON_DST" &>/dev/null; then
        success "Docker daemon config is already up to date."
    else
        warn "Existing /etc/docker/daemon.json differs from repo config."
        read -r -p "Overwrite with repo config? [y/N] " answer
        if [[ "${answer,,}" == "y" ]]; then
            cp "$DAEMON_JSON_SRC" "$DAEMON_JSON_DST"
            systemctl restart docker
            success "Docker daemon config updated and Docker restarted."
        else
            info "Keeping existing Docker daemon config."
        fi
    fi
else
    cp "$DAEMON_JSON_SRC" "$DAEMON_JSON_DST"
    systemctl restart docker
    success "Docker daemon config applied and Docker restarted."
fi

# ---------------------------------------------------------------------------
# Step 8: Create backup directory
# ---------------------------------------------------------------------------
header "Step 8: Creating backup directory"

BACKUP_DESTINATION="${BACKUP_DESTINATION:-/home/server/backups}"
mkdir -p "$BACKUP_DESTINATION"
success "Backup directory: $BACKUP_DESTINATION"

# ---------------------------------------------------------------------------
# Step 9: Deploy the stack
# ---------------------------------------------------------------------------
header "Step 9: Deploying the homeserver stack"

OPENCLAW_DB_ACCESS="${OPENCLAW_DB_ACCESS:-false}"
DB_OVERRIDE="$REPO_ROOT/docker-compose.openclaw-db-override.yml"

if [[ "$OPENCLAW_DB_ACCESS" == "true" ]]; then
    info "OPENCLAW_DB_ACCESS=true — applying database access override for OpenClaw."
    GENERIC_TIMEZONE="${TIMEZONE:-America/New_York}" \
        docker stack deploy \
        -c "$REPO_ROOT/docker-compose.yml" \
        -c "$DB_OVERRIDE" \
        homeserver
else
    GENERIC_TIMEZONE="${TIMEZONE:-America/New_York}" \
        docker stack deploy -c "$REPO_ROOT/docker-compose.yml" homeserver
fi

success "Stack deployment initiated."

# ---------------------------------------------------------------------------
# Step 10: Wait for services
# ---------------------------------------------------------------------------
header "Step 10: Waiting for services to start"

info "Waiting up to 120 seconds for services to become healthy..."
WAIT=0
MAX_WAIT=120
while [[ $WAIT -lt $MAX_WAIT ]]; do
    REPLICAS_OK=$(docker service ls --format '{{.Replicas}}' 2>/dev/null \
        | grep -c "^1/1$" || true)
    TOTAL=$(docker service ls --format '{{.Name}}' 2>/dev/null | wc -l)
    if [[ "$REPLICAS_OK" -eq "$TOTAL" && "$TOTAL" -gt 0 ]]; then
        break
    fi
    sleep 5
    WAIT=$((WAIT + 5))
    printf "."
done
echo ""
docker service ls
success "Stack is running."

# ---------------------------------------------------------------------------
# Step 11: Backup cron job
# ---------------------------------------------------------------------------
header "Step 11: Setting up backup cron job"

CRON_BACKUP="0 2 * * * root bash $REPO_ROOT/scripts/backup.sh >> /var/log/homeserver-backup.log 2>&1"
CRON_DISK="0 */6 * * * root df -h / | awk 'NR==2{gsub(/%/,\"\"); if (\$5>80) print strftime(\"%Y-%m-%dT%H:%M:%S\") \" WARN disk usage at \" \$5 \"%%\"}' >> /var/log/homeserver-disk.log"

if grep -qF "homeserver/scripts/backup.sh" /etc/crontab 2>/dev/null; then
    success "Backup cron job already configured."
else
    echo "$CRON_BACKUP" >> /etc/crontab
    success "Backup cron job added (daily at 2 AM)."
fi

if grep -qF "homeserver-disk.log" /etc/crontab 2>/dev/null; then
    success "Disk monitoring cron job already configured."
else
    echo "$CRON_DISK" >> /etc/crontab
    success "Disk monitoring cron job added (every 6 hours)."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Setup Complete!"

OPENCLAW_STATUS="platform=${OPENCLAW_CHAT_PLATFORM:-telegram}"
if ! docker secret ls --format '{{.Name}}' 2>/dev/null | grep -qx "openclaw_chat_token"; then
    OPENCLAW_STATUS="$OPENCLAW_STATUS (chat token not set — OpenClaw will not start until added)"
fi

cat <<EOF

${GREEN}${BOLD}Your home-server stack is up and running.${RESET}

Instance:  ${BOLD}${INSTANCE_NAME:-my-home-server}${RESET}
Timezone:  ${TIMEZONE:-America/New_York}
Backups:   ${BACKUP_DESTINATION}
OpenClaw:  ${OPENCLAW_STATUS}

${BOLD}Next steps:${RESET}
  1. Import n8n workflows:
       bash scripts/import-workflows.sh

  2. Access n8n via your Cloudflare Tunnel:
       https://${TUNNEL_DOMAIN:-<your-tunnel-domain>}

  3. Read the OpenClaw security guide before adding skills:
       docs/OPENCLAW-SAFETY.md

  4. Message your ${OPENCLAW_CHAT_PLATFORM:-telegram} bot to test OpenClaw.

  5. View service status:
       docker service ls

${BOLD}Useful commands:${RESET}
  docker service ls                             — check all services
  docker service logs homeserver_n8n            — n8n logs
  docker service logs homeserver_openclaw       — OpenClaw logs
  bash scripts/backup.sh                        — run a manual backup
  bash scripts/secrets-helper.sh list           — list secrets

EOF
