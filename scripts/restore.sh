#!/usr/bin/env bash
# restore.sh — Restore PostgreSQL database from a backup
#
# Usage: bash scripts/restore.sh <backup-directory> [--help]
#
# WARNING: This overwrites the current database. Make sure you have
# confirmed the backup is valid before proceeding.

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: bash scripts/restore.sh <backup-directory>

Restores the PostgreSQL database from a backup created by scripts/backup.sh.

Arguments:
  backup-directory    Path to the timestamped backup directory
                      (e.g., /home/server/backups/20240115T120000Z)

WARNING: This will overwrite the current database. The n8n service will be
stopped during restore and restarted afterward.

Example:
  bash scripts/restore.sh /home/server/backups/20240115T120000Z
EOF
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ---------------------------------------------------------------------------
# Validate argument
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    error "Missing required argument: backup directory."
    echo "Usage: bash scripts/restore.sh <backup-directory>"
    exit 1
fi

BACKUP_DIR="$1"

if [[ ! -d "$BACKUP_DIR" ]]; then
    error "Backup directory not found: $BACKUP_DIR"
    exit 1
fi

# Find the dump file
DUMP_FILE="$(ls "$BACKUP_DIR"/db_*.sql.gz 2>/dev/null | head -n1 || true)"
if [[ -z "$DUMP_FILE" ]]; then
    error "No database dump found in $BACKUP_DIR"
    error "Expected a file matching: db_*.sql.gz"
    exit 1
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
echo ""
warn "This will OVERWRITE the current database with the backup from:"
echo "  $BACKUP_DIR"
echo ""
warn "Dump file: $DUMP_FILE ($(du -sh "$DUMP_FILE" | cut -f1))"
echo ""
echo -e "${RED}${BOLD}THIS CANNOT BE UNDONE.${RESET}"
echo ""
read -r -p "Type 'yes' to confirm you want to restore this backup: " confirm
if [[ "$confirm" != "yes" ]]; then
    info "Restore cancelled."
    exit 0
fi

# ---------------------------------------------------------------------------
# Stop n8n to prevent writes during restore
# ---------------------------------------------------------------------------
info "Scaling down n8n service to prevent writes during restore..."
docker service scale homeserver_n8n=0 || {
    error "Could not scale down n8n. Is the stack running?"
    exit 1
}

# Wait for n8n to stop
info "Waiting for n8n to stop..."
sleep 5

# ---------------------------------------------------------------------------
# Restore the database
# ---------------------------------------------------------------------------
info "Finding PostgreSQL container..."
POSTGRES_CONTAINER="$(docker ps -q -f name=homeserver_postgres 2>/dev/null | head -n1 || true)"

if [[ -z "$POSTGRES_CONTAINER" ]]; then
    error "Could not find running homeserver_postgres container."
    error "Restarting n8n service before exiting..."
    docker service scale homeserver_n8n=1 || true
    exit 1
fi

info "Restoring database from $DUMP_FILE ..."
gunzip -c "$DUMP_FILE" | docker exec -i "$POSTGRES_CONTAINER" psql -U postgres

success "Database restore complete."

# ---------------------------------------------------------------------------
# Restart services
# ---------------------------------------------------------------------------
info "Restarting n8n service..."
docker service scale homeserver_n8n=1

# Wait and print status
sleep 10
echo ""
echo "Service status:"
docker service ls

success "Restore finished. Monitor logs to confirm n8n started correctly:"
echo "  docker service logs homeserver_n8n"
