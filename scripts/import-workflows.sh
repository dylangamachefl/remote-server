#!/usr/bin/env bash
# import-workflows.sh — Import n8n workflow JSON files via the n8n REST API
#
# Usage: bash scripts/import-workflows.sh [--help]
#
# Imports all .json files from n8n/workflows/ into the running n8n instance.
# Handles both creating new workflows and updating existing ones by name.

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: bash scripts/import-workflows.sh

Imports all .json files from n8n/workflows/ into the running n8n instance.

The script will:
  1. Wait for n8n to be healthy (HTTP check on localhost:5678)
  2. For each .json file in n8n/workflows/:
     - Check if a workflow with the same name already exists
     - Create it (if new) or update it (if existing)
  3. Report success or failure for each file

n8n API authentication: If n8n is configured with an API key, set the
N8N_API_KEY environment variable before running this script.

Example:
  N8N_API_KEY=your-api-key bash scripts/import-workflows.sh
EOF
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOWS_DIR="$REPO_ROOT/n8n/workflows"
N8N_BASE_URL="http://localhost:5678"
N8N_API="${N8N_BASE_URL}/api/v1"
N8N_API_KEY="${N8N_API_KEY:-}"

# Color helpers
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
    YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; BLUE=''; YELLOW=''; BOLD=''; RESET=''
fi

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ---------------------------------------------------------------------------
# Build curl auth header
# ---------------------------------------------------------------------------
curl_auth() {
    if [[ -n "$N8N_API_KEY" ]]; then
        echo "-H" "X-N8N-API-KEY: $N8N_API_KEY"
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Wait for n8n
# ---------------------------------------------------------------------------
info "Waiting for n8n to be healthy at $N8N_BASE_URL ..."

MAX_WAIT=120
WAIT=0
while [[ $WAIT -lt $MAX_WAIT ]]; do
    HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" \
        $(curl_auth) \
        "${N8N_BASE_URL}/healthz" 2>/dev/null || echo "000")"
    if [[ "$HTTP_STATUS" == "200" ]]; then
        break
    fi
    sleep 5
    WAIT=$((WAIT + 5))
    printf "."
done
echo ""

if [[ "$WAIT" -ge "$MAX_WAIT" ]]; then
    error "n8n did not become healthy within ${MAX_WAIT} seconds."
    error "Check service status: docker service ls"
    exit 1
fi

success "n8n is healthy."

# ---------------------------------------------------------------------------
# Step 2: Find workflow files
# ---------------------------------------------------------------------------
WORKFLOW_FILES=()
while IFS= read -r -d '' f; do
    WORKFLOW_FILES+=("$f")
done < <(find "$WORKFLOWS_DIR" -maxdepth 1 -name "*.json" -print0 2>/dev/null || true)

if [[ ${#WORKFLOW_FILES[@]} -eq 0 ]]; then
    warn "No .json files found in $WORKFLOWS_DIR"
    warn "Add workflow JSON files exported from n8n to n8n/workflows/ and re-run."
    exit 0
fi

info "Found ${#WORKFLOW_FILES[@]} workflow file(s) to import."

# ---------------------------------------------------------------------------
# Step 3: Import each workflow
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

for workflow_file in "${WORKFLOW_FILES[@]}"; do
    filename="$(basename "$workflow_file")"
    info "Processing: $filename"

    # Extract workflow name from JSON
    workflow_name="$(python3 -c "import json,sys; d=json.load(open('$workflow_file')); print(d.get('name',''))" 2>/dev/null || true)"
    if [[ -z "$workflow_name" ]]; then
        error "Could not read workflow name from $filename — skipping."
        FAIL=$((FAIL + 1))
        continue
    fi

    info "  Name: $workflow_name"

    # Check if workflow already exists by name
    existing_id="$(curl -s \
        $(curl_auth) \
        -H "Content-Type: application/json" \
        "${N8N_API}/workflows" 2>/dev/null \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
workflows = data.get('data', [])
for w in workflows:
    if w.get('name') == '$workflow_name':
        print(w['id'])
        break
" 2>/dev/null || true)"

    if [[ -n "$existing_id" ]]; then
        # Update existing workflow
        info "  Workflow exists (id=$existing_id) — updating..."
        HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" \
            -X PUT \
            $(curl_auth) \
            -H "Content-Type: application/json" \
            -d @"$workflow_file" \
            "${N8N_API}/workflows/${existing_id}" 2>/dev/null || echo "000")"
        if [[ "$HTTP_STATUS" =~ ^2 ]]; then
            success "  Updated: $workflow_name"
            PASS=$((PASS + 1))
        else
            error "  Failed to update '$workflow_name' (HTTP $HTTP_STATUS)"
            FAIL=$((FAIL + 1))
        fi
    else
        # Create new workflow
        info "  Creating new workflow..."
        HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            $(curl_auth) \
            -H "Content-Type: application/json" \
            -d @"$workflow_file" \
            "${N8N_API}/workflows" 2>/dev/null || echo "000")"
        if [[ "$HTTP_STATUS" =~ ^2 ]]; then
            success "  Created: $workflow_name"
            PASS=$((PASS + 1))
        else
            error "  Failed to create '$workflow_name' (HTTP $HTTP_STATUS)"
            FAIL=$((FAIL + 1))
        fi
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Import summary:${RESET} $PASS succeeded, $FAIL failed out of ${#WORKFLOW_FILES[@]} total."

if [[ $FAIL -gt 0 ]]; then
    warn "Some workflows failed to import. Check errors above."
    warn "If n8n requires authentication, set: export N8N_API_KEY=your-key"
    exit 1
fi
