#!/usr/bin/env bash
# backup.sh — Backup PostgreSQL database, OpenClaw data, and instance config
#
# Usage: bash scripts/backup.sh [--help]
#
# Designed to be run manually or via cron. Logs to stdout (redirect to a file
# via cron if desired). Errors are also written to /var/log/homeserver-backup-error.log.

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: bash scripts/backup.sh

Backs up the PostgreSQL database, OpenClaw data, and instance configuration.

What gets backed up:
  - Full PostgreSQL dump (pg_dumpall, gzip compressed)
  - OpenClaw data volume (conversation history, session state, agent memory)
  - instance.conf (non-secret configuration)
  - openclaw/openclaw.config (OpenClaw gateway configuration)
  - Docker secret names manifest (names only, never values)

Backup destination and retention are read from instance.conf.
EOF
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ERROR_LOG="/var/log/homeserver-backup-error.log"

log()   { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
error() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" | tee -a "$ERROR_LOG" >&2; }

# Trap errors
trap 'error "Backup failed at line $LINENO. Check $ERROR_LOG for details."' ERR

# ---------------------------------------------------------------------------
# Source instance.conf
# ---------------------------------------------------------------------------
if [[ ! -f "$REPO_ROOT/instance.conf" ]]; then
    error "instance.conf not found at $REPO_ROOT/instance.conf"
    exit 1
fi

# shellcheck source=/dev/null
source "$REPO_ROOT/instance.conf"

BACKUP_DESTINATION="${BACKUP_DESTINATION:-/home/server/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# ---------------------------------------------------------------------------
# Create timestamped backup directory
# ---------------------------------------------------------------------------
TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
BACKUP_DIR="$BACKUP_DESTINATION/$TIMESTAMP"
mkdir -p "$BACKUP_DIR"
log "Backup directory: $BACKUP_DIR"

# ---------------------------------------------------------------------------
# PostgreSQL dump
# ---------------------------------------------------------------------------
log "Starting PostgreSQL dump..."

POSTGRES_CONTAINER="$(docker ps -q -f name=homeserver_postgres 2>/dev/null | head -n1 || true)"

if [[ -z "$POSTGRES_CONTAINER" ]]; then
    error "Could not find running homeserver_postgres container."
    exit 1
fi

docker exec "$POSTGRES_CONTAINER" pg_dumpall -U postgres \
    | gzip > "$BACKUP_DIR/db_${TIMESTAMP}.sql.gz"

# Verify the dump is non-empty
if [[ ! -s "$BACKUP_DIR/db_${TIMESTAMP}.sql.gz" ]]; then
    error "Database dump is empty. Something went wrong."
    rm -f "$BACKUP_DIR/db_${TIMESTAMP}.sql.gz"
    exit 1
fi

DUMP_SIZE="$(du -sh "$BACKUP_DIR/db_${TIMESTAMP}.sql.gz" | cut -f1)"
log "Database dump complete: $DUMP_SIZE"

# ---------------------------------------------------------------------------
# OpenClaw data volume backup
# ---------------------------------------------------------------------------
log "Backing up OpenClaw data volume..."

OPENCLAW_CONTAINER="$(docker ps -q -f name=homeserver_openclaw 2>/dev/null | head -n1 || true)"

if [[ -z "$OPENCLAW_CONTAINER" ]]; then
    log "WARN: homeserver_openclaw container not running. Skipping OpenClaw data backup."
    log "      (This is OK if OpenClaw is not yet configured.)"
else
    mkdir -p "$BACKUP_DIR/openclaw-data"
    # Use the container to tar the /data volume contents into the backup directory
    docker exec "$OPENCLAW_CONTAINER" tar -czf - -C /data . \
        > "$BACKUP_DIR/openclaw-data_${TIMESTAMP}.tar.gz" 2>/dev/null || {
        log "WARN: Could not back up OpenClaw data volume. Container may be restarting."
    }
    if [[ -s "$BACKUP_DIR/openclaw-data_${TIMESTAMP}.tar.gz" ]]; then
        OC_SIZE="$(du -sh "$BACKUP_DIR/openclaw-data_${TIMESTAMP}.tar.gz" | cut -f1)"
        log "OpenClaw data backup complete: $OC_SIZE"
    else
        rm -f "$BACKUP_DIR/openclaw-data_${TIMESTAMP}.tar.gz"
        log "WARN: OpenClaw data backup was empty (volume may be empty — this is OK on first run)."
    fi
fi

# ---------------------------------------------------------------------------
# Copy instance.conf and openclaw.config
# ---------------------------------------------------------------------------
log "Copying configuration files..."
cp "$REPO_ROOT/instance.conf" "$BACKUP_DIR/instance.conf"
log "instance.conf copied."

if [[ -f "$REPO_ROOT/openclaw/openclaw.config" ]]; then
    cp "$REPO_ROOT/openclaw/openclaw.config" "$BACKUP_DIR/openclaw.config"
    log "openclaw/openclaw.config copied."
else
    log "openclaw/openclaw.config not found — skipping (not yet configured)."
fi

# ---------------------------------------------------------------------------
# Docker secrets manifest (names only, never values)
# ---------------------------------------------------------------------------
log "Writing secrets manifest..."
{
    echo "# Docker secret names present at backup time: $TIMESTAMP"
    echo "# This file documents which secrets exist — values are NOT stored here."
    echo "# To recreate them, use: bash scripts/secrets-helper.sh add <name>"
    echo ""
    docker secret ls --format 'NAME={{.Name}} CREATED={{.CreatedAt}}' 2>/dev/null || echo "(could not list secrets)"
} > "$BACKUP_DIR/secrets-manifest.txt"
log "Secrets manifest written."

# ---------------------------------------------------------------------------
# Delete old backups
# ---------------------------------------------------------------------------
log "Pruning backups older than ${BACKUP_RETENTION_DAYS} days..."
find "$BACKUP_DESTINATION" -maxdepth 1 -mindepth 1 -type d \
    -mtime "+${BACKUP_RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null || true
log "Pruning complete."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "Backup completed successfully: $BACKUP_DIR"
