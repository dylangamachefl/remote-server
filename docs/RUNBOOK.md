# Home Server Operations Runbook

This guide covers day-to-day operations for your home server. You don't need to understand Docker internals — just follow the steps and copy-paste the commands.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Starting and Stopping](#2-starting-and-stopping)
3. [Checking Status](#3-checking-status)
4. [Restarting a Single Service](#4-restarting-a-single-service)
5. [Viewing Logs](#5-viewing-logs)
6. [Updating Images](#6-updating-images)
7. [Backup and Restore](#7-backup-and-restore)
8. [Managing Secrets](#8-managing-secrets)
9. [Importing Workflows](#9-importing-workflows)
10. [OpenClaw Operations](#10-openclaw-operations)
11. [Common Issues](#11-common-issues)
12. [Emergency Recovery](#12-emergency-recovery)

---

## 1. Architecture Overview

Your server runs five containerized services managed by Docker Swarm:

```
Internet
    │
    ▼
┌─────────────────┐
│   cloudflared   │  ← Cloudflare Tunnel: secure public access
│  (port: none)   │    No ports exposed to the internet directly
└──────┬──────────┘
       │ tunnel network
  ┌────┴────┐   ┌──────────┐   ┌───────────┐
  │   n8n   │   │ openclaw │   │  dozzle   │
  │ :5678   │   │          │   │  :8080    │
  └────┬────┘   └──────────┘   └───────────┘
       │ internal network
  ┌────┴──────┐
  │ postgres  │  ← Database (never exposed outside internal network)
  │ :5432     │
  └───────────┘
```

**Two agent layers — different purposes:**

| Service | Type | What it does |
|---------|------|-------------|
| **n8n** | Structured workflows | Scheduled tasks: morning digests, bank CSV monitoring, data pipelines. Configured via a visual editor. |
| **openclaw** | Conversational agent | Ad-hoc tasks via messaging apps (Telegram, WhatsApp, etc.). Your interactive front door to the server. |
| **postgres** | Database | Stores all data: n8n workflows, AI memory, indexed documents |
| **cloudflared** | Tunnel | Secure public access — no open ports on your server |
| **dozzle** | Log viewer | Web UI for viewing container logs |

**Network design:**

| Service | Networks | Why |
|---------|----------|-----|
| postgres | `internal` only | Database is never reachable from outside |
| n8n | `internal` + `tunnel` | Needs database access and Cloudflare access |
| openclaw | `tunnel` only (default) | Isolated from database for safety; add `internal` only if needed |
| cloudflared | `tunnel` only | Routes external traffic into the stack |
| dozzle | `tunnel` only | Log viewer accessed via Cloudflare Tunnel |

**Key design decisions:**
- PostgreSQL is on an isolated internal network — it cannot be reached from outside
- OpenClaw is kept off the database network by default (see [OPENCLAW-SAFETY.md](OPENCLAW-SAFETY.md))
- All external access flows through Cloudflare (no open ports on your server)
- Secrets (API keys, passwords) are stored as Docker secrets, not in any file

---

## 2. Starting and Stopping

### Start (deploy) the stack

```bash
cd ~/home-server
bash scripts/deploy.sh
```

Or manually:

```bash
cd ~/home-server
source instance.conf
GENERIC_TIMEZONE="$TIMEZONE" docker stack deploy -c docker-compose.yml homeserver
```

### Stop the entire stack

> **Warning:** This stops all services. n8n workflows will not run and OpenClaw will not respond until you restart.

```bash
docker stack rm homeserver
```

### Restart the entire stack

```bash
docker stack rm homeserver
# Wait ~10 seconds for everything to fully stop
sleep 10
cd ~/home-server && bash scripts/deploy.sh
```

---

## 3. Checking Status

### See all running services

```bash
docker service ls
```

You should see five services each showing `1/1` in the REPLICAS column. If a service shows `0/1`, it has crashed or is starting up.

```
ID             NAME                     MODE         REPLICAS
xxxxx          homeserver_cloudflared   replicated   1/1
xxxxx          homeserver_dozzle        replicated   1/1
xxxxx          homeserver_n8n           replicated   1/1
xxxxx          homeserver_openclaw      replicated   1/1
xxxxx          homeserver_postgres      replicated   1/1
```

### See detailed status for one service

```bash
docker service ps homeserver_n8n
```

Replace `homeserver_n8n` with any service name. This shows recent start/stop history and error messages.

### Check which containers are actually running

```bash
docker ps
```

### Access Dozzle (log viewer)

Dozzle is routed through your Cloudflare Tunnel. Access it at the hostname you configured in the Cloudflare dashboard for port 8080.

---

## 4. Restarting a Single Service

Use this when a service is misbehaving but the rest of the stack is fine.

```bash
# Restart n8n
docker service update --force homeserver_n8n

# Restart postgres
docker service update --force homeserver_postgres

# Restart cloudflared
docker service update --force homeserver_cloudflared

# Restart dozzle
docker service update --force homeserver_dozzle

# Restart OpenClaw
docker service update --force homeserver_openclaw
```

The `--force` flag causes Docker to restart the container even if nothing in the configuration changed.

After restarting, check it came back up:

```bash
docker service ps homeserver_openclaw
```

---

## 5. Viewing Logs

### Via Dozzle (easiest)

Open Dozzle in your browser via the Cloudflare Tunnel URL. You'll see all containers and can click through to view and search logs in real time.

### Via command line

```bash
# n8n logs (most recent 100 lines)
docker service logs --tail 100 homeserver_n8n

# Follow n8n logs in real time (Ctrl+C to stop)
docker service logs -f homeserver_n8n

# OpenClaw logs
docker service logs --tail 100 homeserver_openclaw

# PostgreSQL logs
docker service logs --tail 50 homeserver_postgres

# Cloudflared logs (useful for tunnel connection issues)
docker service logs --tail 50 homeserver_cloudflared
```

### Backup and monitoring logs

```bash
# Backup job results
cat /var/log/homeserver-backup.log

# Disk usage monitoring
cat /var/log/homeserver-disk.log

# Backup errors
cat /var/log/homeserver-backup-error.log
```

---

## 6. Updating Images

Image versions are pinned in `docker-compose.yml`. To update a service:

1. Edit `docker-compose.yml` and change the image tag:

   ```yaml
   # Before:
   image: n8nio/n8n:1.94.1

   # After:
   image: n8nio/n8n:1.95.0
   ```

2. Deploy the updated stack:

   ```bash
   bash scripts/deploy.sh
   ```

   Docker will only restart services whose image changed.

3. Verify the service is running:

   ```bash
   docker service ls
   docker service logs --tail 20 homeserver_n8n
   ```

> **Tip:** Check the [n8n releases page](https://github.com/n8n-io/n8n/releases) for new versions and breaking changes before updating.

---

## 7. Backup and Restore

### Run a manual backup

```bash
bash scripts/backup.sh
```

Backups are saved to the `BACKUP_DESTINATION` path in your `instance.conf` (default: `/home/server/backups`). Each backup is a timestamped folder containing:
- `db_TIMESTAMP.sql.gz` — compressed full database dump
- `openclaw-data_TIMESTAMP.tar.gz` — OpenClaw conversation history and memory
- `instance.conf` — your non-secret configuration
- `openclaw.config` — OpenClaw gateway configuration
- `secrets-manifest.txt` — list of Docker secret names (not values)

### Verify a backup

```bash
# List your backups
ls -lh /home/server/backups/

# Check a specific backup is valid (should print SQL)
gunzip -c /home/server/backups/20240115T120000Z/db_20240115T120000Z.sql.gz | head -20
```

### Restore from backup

> **Warning:** This overwrites the current database. Make sure you have confirmed the backup is valid before proceeding.

```bash
bash scripts/restore.sh /home/server/backups/20240115T120000Z
```

Replace the path with your actual backup directory. The script will ask you to confirm before making any changes.

### Restore OpenClaw data

The restore script handles the database only. To also restore OpenClaw's conversation history and memory:

```bash
BACKUP_DIR="/home/server/backups/20240115T120000Z"

# Stop OpenClaw
docker service scale homeserver_openclaw=0
sleep 5

# Restore data into the openclaw_data volume
docker run --rm \
  -v homeserver_openclaw_data:/data \
  -v "$BACKUP_DIR":/backup:ro \
  alpine sh -c "cd /data && tar -xzf /backup/openclaw-data_*.tar.gz"

# Restart OpenClaw
docker service scale homeserver_openclaw=1
```

### Automatic backups

Backups run automatically every day at 2 AM (configured during setup). Backups older than `BACKUP_RETENTION_DAYS` days are deleted automatically.

---

## 8. Managing Secrets

Docker secrets are encrypted at rest and never written to disk in plaintext. You manage them with `scripts/secrets-helper.sh`.

### List all secrets

```bash
bash scripts/secrets-helper.sh list
```

### Add a new secret

```bash
bash scripts/secrets-helper.sh add my_new_secret
```

### Update an existing secret

> Note: Docker secrets are immutable — updating requires deleting and recreating. The helper does this automatically and restarts affected services.

```bash
bash scripts/secrets-helper.sh update anthropic_api_key
```

### Remove a secret

```bash
bash scripts/secrets-helper.sh remove old_secret_name
```

The helper will warn you if any running service uses the secret you're trying to remove.

---

## 9. Importing Workflows

n8n workflows are stored as JSON files in `n8n/workflows/`. To import them into a running n8n instance:

```bash
bash scripts/import-workflows.sh
```

The script:
1. Waits for n8n to be healthy
2. Imports each `.json` file in `n8n/workflows/`
3. Updates existing workflows (matched by name) or creates new ones

If n8n requires an API key (check n8n Settings → API):

```bash
N8N_API_KEY=your-api-key bash scripts/import-workflows.sh
```

To export workflows from n8n for storage in this repo:
1. In n8n, open the workflow
2. Click the menu (⋮) → Export
3. Save the JSON to `n8n/workflows/`
4. Commit it to git

---

## 10. OpenClaw Operations

OpenClaw is the conversational agent layer — it listens on your configured messaging platform (Telegram, Slack, etc.) and handles ad-hoc tasks interactively.

### Check if OpenClaw is connected

```bash
docker service logs --tail 20 homeserver_openclaw
```

Look for a line like `Connected to Telegram gateway` or `Listening for messages`. If you see repeated connection errors, the bot token may be wrong or expired.

### Restart OpenClaw

```bash
docker service update --force homeserver_openclaw
```

### View conversation logs

OpenClaw logs all interactions. To browse recent activity:

```bash
# Last 50 log lines
docker service logs --tail 50 homeserver_openclaw

# Follow in real time
docker service logs -f homeserver_openclaw
```

Or use Dozzle via your Cloudflare Tunnel URL for a searchable web view.

### Add a skill to OpenClaw

Skill files must be manually reviewed before adding (see [OPENCLAW-SAFETY.md](OPENCLAW-SAFETY.md) for the vetting process):

1. Review the skill file for safety
2. Copy it to `openclaw/skills/` in the repo
3. Commit it to git
4. Restart OpenClaw to pick up the new skill:
   ```bash
   docker service update --force homeserver_openclaw
   ```

### Remove a skill

1. Delete the skill file from `openclaw/skills/`
2. Commit the change
3. Restart OpenClaw:
   ```bash
   docker service update --force homeserver_openclaw
   ```

### Change the AI model OpenClaw uses

1. Edit `openclaw/openclaw.config` and update the `name` field under `model:`
2. Restart OpenClaw:
   ```bash
   docker service update --force homeserver_openclaw
   ```

Common model options (consult Anthropic's pricing page for current costs):
- `claude-sonnet-4-5-20250929` — recommended for conversational tasks
- `claude-opus-4-6` — more capable for complex reasoning, costs more

### Grant OpenClaw database access

By default, OpenClaw cannot query your database. To enable it:

1. Edit `instance.conf` and set:
   ```bash
   OPENCLAW_DB_ACCESS="true"
   ```
2. Redeploy:
   ```bash
   bash scripts/deploy.sh
   ```

To revoke access, set `OPENCLAW_DB_ACCESS="false"` and redeploy.

See [OPENCLAW-SAFETY.md](OPENCLAW-SAFETY.md) before enabling database access.

### Update the messaging platform token

If your bot token changes or expires:

```bash
bash scripts/secrets-helper.sh update openclaw_chat_token
```

This will prompt you for the new token and automatically restart OpenClaw.

---

## 11. Common Issues

### Disk space running low

Check disk usage:

```bash
df -h /
du -sh /home/server/backups/
du -sh /var/lib/docker/
```

Free up space:

```bash
# Remove unused Docker images
docker image prune -a --force --filter "until=168h"

# Remove old backups manually (or reduce BACKUP_RETENTION_DAYS in instance.conf)
ls /home/server/backups/
rm -rf /home/server/backups/20240101T000000Z  # example
```

### A service is out of memory (OOM killed)

Check if a service was killed by the OOM killer:

```bash
docker service ps homeserver_n8n
# Look for "OOM" in the error column
```

Check current memory usage:

```bash
docker stats --no-stream
```

The memory limits in `docker-compose.yml` are:
- postgres: 2GB
- n8n: 2GB
- openclaw: 1GB
- cloudflared: 256MB
- dozzle: 128MB

If a service is consistently hitting its limit, you can increase it in `docker-compose.yml` and redeploy — but check `free -h` first to make sure you have headroom.

### Tunnel not connecting

1. Check cloudflared logs:
   ```bash
   docker service logs --tail 50 homeserver_cloudflared
   ```

2. Verify the `cloudflare_tunnel_token` secret is correct:
   ```bash
   bash scripts/secrets-helper.sh update cloudflare_tunnel_token
   ```

3. Check your Cloudflare Zero Trust dashboard → Networks → Tunnels to confirm the tunnel shows as healthy.

4. Make sure your server has outbound internet access on port 443.

### n8n cannot reach the Claude API

1. Check n8n logs for the error:
   ```bash
   docker service logs --tail 50 homeserver_n8n
   ```

2. Verify the Anthropic API key secret is correct and not expired:
   ```bash
   bash scripts/secrets-helper.sh update anthropic_api_key
   ```

3. Test connectivity from inside the n8n container:
   ```bash
   N8N_CONTAINER=$(docker ps -q -f name=homeserver_n8n | head -n1)
   docker exec "$N8N_CONTAINER" wget -q -O- https://api.anthropic.com 2>&1 | head -5
   ```

### n8n shows database connection errors

1. Check postgres is healthy:
   ```bash
   docker service ls
   docker service logs --tail 20 homeserver_postgres
   ```

2. Restart postgres (n8n will reconnect automatically):
   ```bash
   docker service update --force homeserver_postgres
   ```

3. If postgres keeps failing, check disk space — a full disk causes postgres to crash.

### OpenClaw not responding on messaging platform

1. Check OpenClaw logs:
   ```bash
   docker service logs --tail 50 homeserver_openclaw
   ```

2. Look for connection errors. If the token is wrong or expired:
   ```bash
   bash scripts/secrets-helper.sh update openclaw_chat_token
   ```

3. Confirm the service is running:
   ```bash
   docker service ps homeserver_openclaw
   ```

4. Check the `owner_id` in `openclaw/openclaw.config` — if it doesn't match your user ID on the platform, OpenClaw will silently ignore your messages. Correct it and restart:
   ```bash
   docker service update --force homeserver_openclaw
   ```

### OpenClaw is behaving unexpectedly

1. Stop it immediately:
   ```bash
   docker service scale homeserver_openclaw=0
   ```

2. Review recent logs for clues:
   ```bash
   docker service logs --tail 200 homeserver_openclaw > /tmp/openclaw-review.log
   cat /tmp/openclaw-review.log
   ```

3. Check if any new skills were recently added to `openclaw/skills/`. If so, review them against the guidelines in [OPENCLAW-SAFETY.md](OPENCLAW-SAFETY.md).

4. Restart once you've identified the cause:
   ```bash
   docker service scale homeserver_openclaw=1
   ```

---

## 12. Emergency Recovery

This section describes how to rebuild the entire server from scratch using only:
- This git repository
- Your Docker secrets (write them down somewhere safe!)
- A database and OpenClaw backup

### Step 1: Provision a new server

Get a fresh Ubuntu 22.04+ or Debian 12+ server (VPS or mini PC).

### Step 2: Clone the repo

```bash
git clone https://github.com/YOUR_USERNAME/home-server.git
cd home-server
```

### Step 3: Run setup

```bash
sudo bash scripts/setup.sh
```

During setup, you'll be prompted to enter all your secrets. Have these values ready:
- PostgreSQL password
- n8n encryption key (**critical** — without this, n8n cannot decrypt stored credentials)
- Anthropic API key
- Slack bot token
- Cloudflare Tunnel token
- OpenClaw chat platform token

> **If you lost the n8n encryption key:** You will need to re-enter all credentials in n8n manually after restore. The database structure will be intact but encrypted credential values will be unreadable.

### Step 4: Restore the database

Once setup completes and the stack is running:

```bash
# Copy your backup to the new server
scp -r user@old-server:/home/server/backups/20240115T120000Z ./

# Restore the database
bash scripts/restore.sh ./20240115T120000Z
```

### Step 5: Restore OpenClaw data (optional)

```bash
BACKUP_DIR="./20240115T120000Z"
docker service scale homeserver_openclaw=0
sleep 5
docker run --rm \
  -v homeserver_openclaw_data:/data \
  -v "$BACKUP_DIR":/backup:ro \
  alpine sh -c "cd /data && tar -xzf /backup/openclaw-data_*.tar.gz"
docker service scale homeserver_openclaw=1
```

### Step 6: Restore openclaw.config

If your backup includes `openclaw.config`:

```bash
cp ./20240115T120000Z/openclaw.config openclaw/openclaw.config
docker service update --force homeserver_openclaw
```

### Step 7: Import workflows

```bash
bash scripts/import-workflows.sh
```

### Step 8: Verify

```bash
docker service ls
docker service logs --tail 20 homeserver_n8n
docker service logs --tail 20 homeserver_openclaw
```

Open your Cloudflare Tunnel URL and confirm n8n loads. Message your bot to confirm OpenClaw responds.
