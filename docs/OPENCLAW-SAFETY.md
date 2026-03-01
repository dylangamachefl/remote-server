# OpenClaw Security Guidelines

OpenClaw is an autonomous agent with real system access — it can call APIs, send messages, read and write files in its data volume, and execute skills. This guide covers how to configure it safely in this stack.

---

## Table of Contents

1. [Why OpenClaw Needs Extra Care](#1-why-openclaw-needs-extra-care)
2. [Skill Vetting Process](#2-skill-vetting-process)
3. [Network Isolation](#3-network-isolation)
4. [Owner-Only Access](#4-owner-only-access)
5. [What OpenClaw Can and Cannot Do in This Setup](#5-what-openclaw-can-and-cannot-do-in-this-setup)
6. [Monitoring](#6-monitoring)

---

## 1. Why OpenClaw Needs Extra Care

OpenClaw is designed to be useful — it takes instructions from a messaging app and carries them out with real tool calls. That same capability is what makes it worth running, and what makes it worth configuring carefully.

**The specific risks to be aware of:**

- **Prompt injection**: A malicious actor could send a message through your messaging platform (or include injected instructions in web content the agent fetches) and attempt to get OpenClaw to perform actions you didn't intend.
- **Community skill ecosystem**: OpenClaw has a public skill registry (ClawHub). Community skills are not reviewed before publishing. Several skills have been reported to send data to external servers or request unnecessary system access. This is not hypothetical — it has been documented by security researchers.
- **Autonomous action**: Unlike n8n workflows (which are explicit and auditable), OpenClaw makes real-time decisions about what tools to call. If a skill or instruction is poorly defined, the agent may take unexpected actions.

None of this means OpenClaw is dangerous to run — just that it rewards a little care upfront.

---

## 2. Skill Vetting Process

**Never install skills directly from ClawHub (or any community registry) into a production instance without reviewing them first.**

The `openclaw/skills/` directory in this repo is a curated set of skills that you have personally reviewed. Only files in this directory are available to the agent (it's bind-mounted read-only to `/app/skills/` inside the container).

### How to add a new skill

1. Download or copy the skill file to your local machine.
2. Review it manually before placing it in `openclaw/skills/`:
   - **Check for outbound URLs**: Does the skill send data to any URL other than well-known public APIs? Any `curl`, `fetch`, `http.post`, or similar calls should go only to expected destinations.
   - **Check for filesystem access**: Skills should not read from paths outside `/data` or `/app/skills`. Be suspicious of any skill that tries to access `/etc`, `/var`, `/home`, or relative paths like `../../`.
   - **Check for obfuscated code**: Base64-encoded strings, `eval()`, dynamically constructed commands, or minified code are red flags. If you can't read it, don't run it.
   - **Check for unnecessary permissions**: A skill for "summarizing news articles" should not need database access or the ability to write files. Scope matters.
3. If the skill passes review, copy it to `openclaw/skills/` and commit it to git so there's an audit trail.

### What to do with skills you're unsure about

Test in a throwaway environment (a separate VM or local Docker Desktop instance) before adding to production. Enable debug logging to see exactly what API calls the skill makes.

---

## 3. Network Isolation

By default, OpenClaw is placed on the `tunnel` network only — the same network used by cloudflared and dozzle. **It is intentionally NOT on the `internal` network.**

The `internal` network is where PostgreSQL lives. Keeping OpenClaw off that network means it cannot query your database, even if a prompt injection or malicious skill tries to.

### What this means in practice

- OpenClaw **can** make outbound API calls (Anthropic, web searches, messaging platforms)
- OpenClaw **cannot** directly query PostgreSQL or access any service on the internal network

### When to enable database access

If you have a specific use case where OpenClaw needs to read or write your database (for example, you want the agent to look up data from your `brain.documents` table when answering questions), you can enable it:

1. Edit `instance.conf` and set `OPENCLAW_DB_ACCESS="true"`
2. Redeploy: `bash scripts/deploy.sh`

This adds OpenClaw to the `internal` network, giving it access to PostgreSQL on `postgres:5432`.

**Before enabling database access:**
- Understand that any prompt injection or malicious skill could now read all data in your database
- Consider creating a read-only PostgreSQL user for OpenClaw rather than using the admin `postgres` user
- Only enable this for specific workflows that need it; disable it again when done

---

## 4. Owner-Only Access

The `OPENCLAW_OWNER_ID` setting in `instance.conf` restricts who can issue commands to OpenClaw. **This is a critical setting.** Without it, anyone who can message the bot could interact with your agent.

### Why this matters

If you add the bot to a group chat, other group members could attempt to give it instructions. Even in a direct message scenario, someone who discovers your bot username/handle could try to interact with it.

### How to find your owner ID

**Telegram:** Message [@userinfobot](https://t.me/userinfobot) — it replies with your numeric user ID.

**Slack:** Open your profile → click the three-dot menu → "Copy member ID". It starts with `U`.

**Discord:** Enable Developer Mode (Settings → Advanced → Developer Mode), then right-click your username and select "Copy User ID".

**WhatsApp:** Your phone number in international format (e.g., `+12125551234`).

### What happens to unauthorized messages

OpenClaw should silently ignore messages from users who are not the configured owner. Check the logs if you're unsure it's working:

```bash
docker service logs --tail 50 homeserver_openclaw
```

Look for lines mentioning "unauthorized" or "ignored" message events.

---

## 5. What OpenClaw Can and Cannot Do in This Setup

### Can do (by default)

| Capability | Notes |
|-----------|-------|
| Make API calls to Anthropic | Uses the shared `anthropic_api_key` secret |
| Send and receive messages via your messaging platform | Via the `openclaw_chat_token` secret |
| Read and write its own data volume | Conversation history, session state, agent memory at `/data` |
| Execute skills in `openclaw/skills/` | Only skills you have manually placed there |
| Make outbound HTTP requests | For web searches, API integrations, etc. |

### Cannot do (by default)

| Restriction | Why |
|------------|-----|
| Access the host filesystem | No bind mounts to host paths beyond skills dir |
| Control other Docker containers | Docker socket is NOT mounted |
| Access PostgreSQL | Not on the `internal` network by default |
| Install new skills on its own | Skills directory is mounted read-only |
| Access other services on the internal network | Network isolation |

### Can do (if `OPENCLAW_DB_ACCESS=true`)

- Query PostgreSQL directly on `postgres:5432`
- Read and write all schemas in the `homeserver` database

---

## 6. Monitoring

### Check logs regularly

Make it a habit to review OpenClaw's logs after:
- Adding a new skill
- Changing configuration
- Noticing unexpected behavior from the bot

```bash
# Recent logs
docker service logs --tail 100 homeserver_openclaw

# Follow logs in real time (Ctrl+C to stop)
docker service logs -f homeserver_openclaw
```

Or use Dozzle via your Cloudflare Tunnel URL for a filterable web UI.

### What to look for

| Pattern | What it might mean |
|---------|-------------------|
| Unexpected outbound URLs | A skill sending data somewhere unintended |
| Repeated auth failures | Someone attempting to interact without authorization |
| "executing skill" for a skill you didn't add | Something is wrong — stop and investigate |
| High memory usage | A skill or conversation loop consuming excess resources |
| Connections to IPs you don't recognize | Potentially a compromised skill |

### If something looks wrong

1. Stop OpenClaw immediately:
   ```bash
   docker service scale homeserver_openclaw=0
   ```

2. Review recent logs in full:
   ```bash
   docker service logs --tail 500 homeserver_openclaw > /tmp/openclaw-review.log
   cat /tmp/openclaw-review.log
   ```

3. Remove any recently added skills from `openclaw/skills/` if they look suspicious.

4. Restart once you've identified the cause:
   ```bash
   docker service scale homeserver_openclaw=1
   ```
