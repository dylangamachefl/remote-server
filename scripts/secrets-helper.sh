#!/usr/bin/env bash
# secrets-helper.sh — Manage Docker Swarm secrets
#
# Usage: bash scripts/secrets-helper.sh <command> [arguments]
#
# Commands:
#   list              List all Docker secrets (names only)
#   add <name>        Interactively create a new secret
#   update <name>     Remove and recreate a secret (secrets are immutable)
#   remove <name>     Remove a secret after confirmation

set -euo pipefail

# Color helpers
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

usage() {
    cat <<EOF
Usage: bash scripts/secrets-helper.sh <command> [arguments]

Manage Docker Swarm secrets for the homeserver stack.

Commands:
  list              List all Docker secrets (names and creation dates)
  add <name>        Create a new secret interactively
  update <name>     Remove and recreate a secret (Docker secrets are immutable;
                    updating requires remove + recreate + service restart)
  remove <name>     Remove a secret after confirmation

Examples:
  bash scripts/secrets-helper.sh list
  bash scripts/secrets-helper.sh add anthropic_api_key
  bash scripts/secrets-helper.sh update slack_bot_token
  bash scripts/secrets-helper.sh remove old_secret

Notes:
  - Docker secrets cannot be modified after creation; 'update' deletes and
    recreates the secret, then forces a service restart to pick up the change.
  - Never store secret values in files or shell history. Values are read
    interactively with input masking.
EOF
}

# ---------------------------------------------------------------------------
# Helper: check if a secret exists
# ---------------------------------------------------------------------------
_secret_exists() {
    docker secret ls --format '{{.Name}}' | grep -qx "$1"
}

# ---------------------------------------------------------------------------
# Helper: read a secret value interactively (masked)
# ---------------------------------------------------------------------------
_read_secret() {
    local prompt="${1:-Enter secret value}"
    local value=""
    while [[ -z "$value" ]]; do
        read -r -s -p "$prompt: " value
        echo ""
        if [[ -z "$value" ]]; then
            warn "Value cannot be empty. Please try again."
        fi
    done
    echo "$value"
}

# ---------------------------------------------------------------------------
# Helper: find services using a secret
# ---------------------------------------------------------------------------
_services_using_secret() {
    local name="$1"
    docker service ls --quiet 2>/dev/null | while read -r svc_id; do
        docker service inspect "$svc_id" --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretName}}{{"\n"}}{{end}}' 2>/dev/null \
            | grep -qx "$name" && docker service inspect "$svc_id" --format '{{.Spec.Name}}' 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_list() {
    info "Docker secrets:"
    docker secret ls
}

cmd_add() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        error "Missing secret name. Usage: secrets-helper.sh add <name>"
        exit 1
    fi

    if _secret_exists "$name"; then
        warn "Secret '$name' already exists."
        warn "To replace it, use: bash scripts/secrets-helper.sh update $name"
        exit 0
    fi

    info "Creating secret: $name"
    local value
    value="$(_read_secret "Enter value for '$name'")"
    echo "$value" | docker secret create "$name" - > /dev/null
    success "Secret '$name' created."
}

cmd_update() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        error "Missing secret name. Usage: secrets-helper.sh update <name>"
        exit 1
    fi

    if ! _secret_exists "$name"; then
        warn "Secret '$name' does not exist. Use 'add' to create it."
        exit 1
    fi

    warn "Updating a Docker secret requires removing and recreating it."
    warn "Services using this secret will be restarted."
    echo ""

    # Find which services use this secret
    AFFECTED_SERVICES=()
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && AFFECTED_SERVICES+=("$svc")
    done < <(_services_using_secret "$name")

    if [[ ${#AFFECTED_SERVICES[@]} -gt 0 ]]; then
        info "Services using '$name':"
        for svc in "${AFFECTED_SERVICES[@]}"; do
            echo "  - $svc"
        done
    else
        info "No running services appear to use '$name'."
    fi

    echo ""
    read -r -p "Continue with update? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Cancelled."; exit 0; }

    # Read new value before removing old secret
    local new_value
    new_value="$(_read_secret "Enter new value for '$name'")"

    # Remove old secret
    info "Removing old secret '$name'..."
    docker secret rm "$name"

    # Create new secret
    echo "$new_value" | docker secret create "$name" - > /dev/null
    success "Secret '$name' recreated."

    # Force restart affected services to pick up new secret
    for svc in "${AFFECTED_SERVICES[@]}"; do
        info "Restarting service $svc ..."
        docker service update --force "$svc" > /dev/null
        success "$svc restarted."
    done

    success "Secret '$name' updated successfully."
}

cmd_remove() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        error "Missing secret name. Usage: secrets-helper.sh remove <name>"
        exit 1
    fi

    if ! _secret_exists "$name"; then
        warn "Secret '$name' does not exist."
        exit 0
    fi

    # Check if any service uses this secret
    AFFECTED_SERVICES=()
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && AFFECTED_SERVICES+=("$svc")
    done < <(_services_using_secret "$name")

    if [[ ${#AFFECTED_SERVICES[@]} -gt 0 ]]; then
        warn "Secret '$name' is currently used by:"
        for svc in "${AFFECTED_SERVICES[@]}"; do
            echo "  - $svc"
        done
        warn "Removing it while services are running may cause failures."
    fi

    read -r -p "Remove secret '$name'? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Cancelled."; exit 0; }

    docker secret rm "$name"
    success "Secret '$name' removed."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
COMMAND="${1:-}"

case "$COMMAND" in
    list)    cmd_list ;;
    add)     cmd_add "${2:-}" ;;
    update)  cmd_update "${2:-}" ;;
    remove)  cmd_remove "${2:-}" ;;
    --help|-h|help|"")
        usage
        [[ -z "$COMMAND" ]] && exit 1 || exit 0
        ;;
    *)
        error "Unknown command: $COMMAND"
        echo ""
        usage
        exit 1
        ;;
esac
