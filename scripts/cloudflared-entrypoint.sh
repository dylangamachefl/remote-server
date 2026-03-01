#!/bin/sh
# cloudflared-entrypoint.sh
#
# Cloudflared does not support the Docker secrets _FILE convention natively.
# This wrapper reads the tunnel token from the Docker secret file and exports
# it as the TUNNEL_TOKEN environment variable before exec-ing cloudflared.
#
# This script is mounted into the cloudflared container as a read-only bind mount.

set -e

SECRET_FILE="/run/secrets/cloudflare_tunnel_token"

if [ ! -f "$SECRET_FILE" ]; then
    echo "ERROR: Docker secret file not found at $SECRET_FILE" >&2
    echo "Make sure the 'cloudflare_tunnel_token' secret has been created." >&2
    exit 1
fi

TUNNEL_TOKEN="$(cat "$SECRET_FILE")"
if [ -z "$TUNNEL_TOKEN" ]; then
    echo "ERROR: cloudflare_tunnel_token secret is empty." >&2
    exit 1
fi

export TUNNEL_TOKEN

exec cloudflared "$@"
