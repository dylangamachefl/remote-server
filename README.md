# home-server

A portable, Docker Swarm-based template for running a personal AI agent server on low-power x86 hardware (Intel N100 mini PC or similar). The stack combines two agent layers: [n8n](https://n8n.io) for structured, scheduled workflows (morning digests, bank CSV monitoring, data pipelines) and [OpenClaw](https://github.com/openclaw/openclaw) as a conversational autonomous agent accessible via messaging apps (Telegram, WhatsApp, Slack, etc.). Both use Claude (via Anthropic API) as the reasoning engine and share a PostgreSQL with pgvector database for persistent state and vector search. External access is handled by Cloudflare Tunnels — no ports exposed to the internet. All secrets are managed via Docker Swarm secrets; no `.env` files with credentials are ever written to disk.

---

## Prerequisites

**Hardware**
- Intel N100 mini PC (or any x86-64 machine with 8GB+ RAM)
- 64GB+ storage recommended

**Operating System**
- Ubuntu 22.04 LTS or Debian 12 (recommended)
- Fresh install preferred; the setup script installs Docker automatically

**Accounts required**
- [Anthropic](https://console.anthropic.com) — API key for Claude (used by both n8n and OpenClaw)
- [Slack](https://api.slack.com/apps) — Bot token for n8n notifications and human-in-the-loop approvals
- [Cloudflare](https://dash.cloudflare.com) — Free account + a domain for the Tunnel
- A messaging platform account for OpenClaw (e.g., [Telegram](https://t.me/BotFather) — create a bot via @BotFather)

---

## Quick Start

```bash
# 1. Clone the repo on your server
git clone https://github.com/YOUR_USERNAME/home-server.git
cd home-server

# 2. Run the setup script (installs Docker, creates secrets, deploys the stack)
sudo bash scripts/setup.sh

# 3. Import your n8n workflows (optional — add JSON files to n8n/workflows/ first)
bash scripts/import-workflows.sh

# 4. Message your Telegram (or other platform) bot to test OpenClaw
```

The setup script is interactive and will walk you through each step. OpenClaw setup is optional during initial setup — skip the chat token and add it later with `bash scripts/secrets-helper.sh add openclaw_chat_token`.

---

## Repo Structure

```
home-server/
├── docker-compose.yml                      # Stack definition — identical on every instance
├── docker-compose.openclaw-db-override.yml # Optional override: gives OpenClaw DB access
├── instance.conf.example                   # Template for per-instance non-secret config
├── scripts/
│   ├── setup.sh                            # First-time VPS bootstrap (run this first)
│   ├── deploy.sh                           # Pull repo + redeploy stack
│   ├── backup.sh                           # Database + OpenClaw data + config backup
│   ├── restore.sh                          # Restore database from backup
│   ├── import-workflows.sh                 # Import n8n workflow JSONs via API
│   ├── secrets-helper.sh                   # Add/update/list Docker secrets
│   ├── cloudflared-entrypoint.sh           # Wrapper: reads secret file for cloudflared
│   └── openclaw-entrypoint.sh              # Wrapper: reads secret files for OpenClaw
├── n8n/
│   └── workflows/                          # Exported n8n workflow JSON files
├── openclaw/
│   ├── skills/                             # Vetted OpenClaw skill files (manually curated)
│   └── openclaw.config.example             # Template for OpenClaw gateway config
├── config/
│   ├── docker-daemon.json                  # Docker log rotation config
│   └── postgres/
│       └── init.sql                        # DB init: pgvector, schemas, tables
└── docs/
    ├── RUNBOOK.md                           # Operations guide
    └── OPENCLAW-SAFETY.md                  # OpenClaw security guidelines
```

---

## Services

| Service | Image | Purpose |
|---------|-------|---------|
| n8n | `n8nio/n8n:1.94.1` | Structured workflow automation (scheduled, visual) |
| openclaw | `ghcr.io/openclaw/openclaw:latest` | Conversational autonomous agent via messaging apps |
| postgres | `pgvector/pgvector:pg16` | Database with vector search support |
| cloudflared | `cloudflare/cloudflared:2024.12.2` | Secure tunnel (no open ports needed) |
| dozzle | `amir20/dozzle:latest` | Web-based log viewer |

---

## Configuration

Per-instance non-secret configuration lives in `instance.conf` (not committed to git). Copy the example and fill in your values:

```bash
cp instance.conf.example instance.conf
nano instance.conf
```

See [`instance.conf.example`](instance.conf.example) for all available settings with descriptions, including OpenClaw platform, owner ID, and model selection.

All secrets (passwords, API keys, tokens) are created as Docker Swarm secrets during `setup.sh` and never stored in files.

---

## Operations

See [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for:
- Starting, stopping, and restarting services
- Viewing logs (via Dozzle UI or CLI)
- Updating container image versions
- Running and restoring backups
- Managing secrets
- OpenClaw operations: connecting to a messaging platform, adding skills, granting database access
- Troubleshooting common issues
- Emergency full recovery procedure

---

## Security

See [`docs/OPENCLAW-SAFETY.md`](docs/OPENCLAW-SAFETY.md) for OpenClaw-specific security guidance:
- Why the skill vetting process matters (and what to look for)
- Why OpenClaw is network-isolated from the database by default
- Owner-only access configuration
- What OpenClaw can and cannot do in this setup
- Monitoring for unexpected behavior

---

## License

MIT
