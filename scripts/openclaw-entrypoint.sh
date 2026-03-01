#!/bin/sh
# openclaw-entrypoint.sh
#
# OpenClaw does not natively support Docker's _FILE secret convention.
# This wrapper reads secrets from /run/secrets/, exports them as environment
# variables, then exec-s the OpenClaw gateway process.
#
# NOTE: Verify the expected environment variable names against the installed
# OpenClaw version. The variable names below match the current documented API
# but may change between releases.
#
# This script is mounted into the openclaw container as a read-only bind mount.

set -e

# ---------------------------------------------------------------------------
# Anthropic API key (required)
# ---------------------------------------------------------------------------
ANTHROPIC_SECRET_FILE="/run/secrets/anthropic_api_key"

if [ ! -f "$ANTHROPIC_SECRET_FILE" ]; then
    echo "ERROR: Docker secret file not found at $ANTHROPIC_SECRET_FILE" >&2
    echo "Make sure the 'anthropic_api_key' secret has been created." >&2
    exit 1
fi

ANTHROPIC_API_KEY="$(cat "$ANTHROPIC_SECRET_FILE")"
if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "ERROR: anthropic_api_key secret is empty." >&2
    exit 1
fi

export ANTHROPIC_API_KEY

# ---------------------------------------------------------------------------
# Messaging platform token (required for gateway to connect)
# ---------------------------------------------------------------------------
CHAT_SECRET_FILE="/run/secrets/openclaw_chat_token"

if [ ! -f "$CHAT_SECRET_FILE" ]; then
    echo "ERROR: Docker secret file not found at $CHAT_SECRET_FILE" >&2
    echo "Make sure the 'openclaw_chat_token' secret has been created." >&2
    echo "Run: bash scripts/secrets-helper.sh add openclaw_chat_token" >&2
    exit 1
fi

OPENCLAW_CHAT_TOKEN="$(cat "$CHAT_SECRET_FILE")"
if [ -z "$OPENCLAW_CHAT_TOKEN" ]; then
    echo "ERROR: openclaw_chat_token secret is empty." >&2
    exit 1
fi

export OPENCLAW_CHAT_TOKEN

# ---------------------------------------------------------------------------
# PostgreSQL password (optional — only needed if OPENCLAW_DB_ACCESS=true)
# ---------------------------------------------------------------------------
PG_SECRET_FILE="/run/secrets/postgres_password"

if [ -f "$PG_SECRET_FILE" ]; then
    PGPASSWORD="$(cat "$PG_SECRET_FILE")"
    export PGPASSWORD
fi

# ---------------------------------------------------------------------------
# Exec OpenClaw
# ---------------------------------------------------------------------------
# Pass through all arguments (e.g., "gateway --config /app/config/openclaw.config")
exec openclaw "$@"
