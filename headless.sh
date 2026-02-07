#!/bin/bash
# PayRam Headless CLI - API-only setup and operations (no web UI).
# Requires PayRam already running (e.g. via ./run_local.sh).
# Usage: ./headless.sh [command] [options]
#   (no command) or menu - Show step menu; choose which step to run
#   run                - Full flow: setup/signin then create payment link (prompts with defaults)
#   status             - Show API and auth status
#   setup              - Ensure root user + default project (register if needed)
#   signin             - Sign in (saves token)
#   ensure-config      - Seed payram.frontend / payram.backend for local API (if missing)
#   ensure-wallet      - Ensure project has a deposit wallet (create random BTC or link existing)
#   deploy-scw         - Deploy ETH/EVM smart-contract deposit wallet (requires token + RPC + fund collector)
#   create-payment-link - Create a payment link
#   reset-local        - Remove local data; run ./run_local.sh again to start fresh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SCRIPT_DIR"

# Config: prefer env, then local dirs from run_local.sh layout
PAYRAM_INFO_DIR="${PAYRAM_INFO_DIR:-${SCRIPT_DIR}/.payraminfo}"
PAYRAM_CORE_DIR="${PAYRAM_CORE_DIR:-${SCRIPT_DIR}/.payram-core}"
PAYRAM_API_URL="${PAYRAM_API_URL:-http://localhost:8080}"
TOKEN_FILE="${PAYRAM_INFO_DIR}/headless-tokens.env"

# Load saved token if present
load_tokens() {
  if [[ -f "$TOKEN_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$TOKEN_FILE"
  fi
}

# Call API with optional Bearer token; output body to stdout; return curl exit code
api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local use_token="${4:-true}"
  load_tokens
  local url="${PAYRAM_API_URL}${path}"
  if [[ -n "$data" ]]; then
    if [[ "$use_token" == "true" && -n "${ACCESS_TOKEN:-}" ]]; then
      curl -s -S -w "\n%{http_code}" -X "$method" "$url" \
        -H "Content-Type: application/json" -H "Authorization: Bearer $ACCESS_TOKEN" -d "$data"
    else
      curl -s -S -w "\n%{http_code}" -X "$method" "$url" -H "Content-Type: application/json" -d "$data"
    fi
  else
    if [[ "$use_token" == "true" && -n "${ACCESS_TOKEN:-}" ]]; then
      curl -s -S -w "\n%{http_code}" -X "$method" "$url" -H "Authorization: Bearer $ACCESS_TOKEN"
    else
      curl -s -S -w "\n%{http_code}" -X "$method" "$url"
    fi
  fi
}

# Parse last line as HTTP code and the rest as body
parse_response() {
  local response="$1"
  HTTP_BODY=$(echo "$response" | sed '$d')
  HTTP_CODE=$(echo "$response" | tail -1)
}

# Print API error details and hint for backend logs (set PAYRAM_DEBUG=1 for request dump)
log_api_error() {
  local context="$1"    # e.g. "Create payment link"
  local code="${2:-$HTTP_CODE}"
  local body="${3:-$HTTP_BODY}"
  local method="${4:-}" url="${5:-}" payload="${6:-}"
  echo ""
  echo "--- $context failed ---"
  echo "HTTP status: $code"
  echo "Response body: $body"
  if [[ -n "${PAYRAM_DEBUG:-}" ]] && [[ -n "$method" ]]; then
    echo "Request: $method $url"
    [[ -n "$payload" ]] && echo "Payload: $payload"
  fi
  if [[ "$code" == "500" && "$context" == "Create payment link" ]]; then
    echo ""
    echo "Possible causes: no wallet linked, missing config (e.g. payram.frontend), or address pool not ready."
    echo "  → If no wallet: run $0 ensure-wallet   or link one in the dashboard (Project → Wallet)."
    echo "  → Check backend logs (below) for the actual error."
  fi
  echo ""
  echo "To see backend error details, run:"
  echo "  docker logs payram 2>&1 | tail -80"
  echo ""
}

# Refresh access token using saved REFRESH_TOKEN
refresh_token() {
  load_tokens
  [[ -z "${REFRESH_TOKEN:-}" ]] && return 1
  local res
  res=$(curl -s -S -w "\n%{http_code}" -X POST "${PAYRAM_API_URL}/api/v1/refresh" \
    -H "Content-Type: application/json" -d "{\"refreshToken\":\"$REFRESH_TOKEN\"}")
  parse_response "$res"
  if [[ "$HTTP_CODE" != "200" ]]; then
    return 1
  fi
  ACCESS_TOKEN=$(echo "$HTTP_BODY" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)
  REFRESH_TOKEN=$(echo "$HTTP_BODY" | grep -o '"refreshToken":"[^"]*"' | cut -d'"' -f4)
  mkdir -p "$(dirname "$TOKEN_FILE")"
  echo "ACCESS_TOKEN=\"$ACCESS_TOKEN\"" > "$TOKEN_FILE"
  echo "REFRESH_TOKEN=\"$REFRESH_TOKEN\"" >> "$TOKEN_FILE"
  return 0
}

# Ensure we have a valid token; run signin if not
ensure_token() {
  load_tokens
  if [[ -n "${ACCESS_TOKEN:-}" ]]; then
    local check
    check=$(api GET "/api/v1/external-platform/all" "" true)
    parse_response "$check"
    if [[ "$HTTP_CODE" == "200" ]]; then
      return 0
    fi
    if [[ "$HTTP_CODE" == "401" ]] && refresh_token; then
      return 0
    fi
  fi
  echo "Not signed in. Run: $0 signin"
  return 1
}

cmd_status() {
  echo "API URL: $PAYRAM_API_URL"
  local res
  res=$(curl -s -o /dev/null -w "%{http_code}" "${PAYRAM_API_URL}/api/v1/member/root/exist" 2>/dev/null || echo "000")
  if [[ "$res" == "200" ]]; then
    echo "API: reachable"
    local body
    body=$(curl -s "${PAYRAM_API_URL}/api/v1/member/root/exist")
    if echo "$body" | grep -q '"exist":true'; then
      echo "Root user: exists"
    else
      echo "Root user: not created (run 'setup' to register first user)"
    fi
  else
    echo "API: unreachable (is PayRam running? try ./run_local.sh)"
    return 1
  fi
  load_tokens
  if [[ -n "${ACCESS_TOKEN:-}" ]]; then
    echo "Token: saved"
    if ensure_token >/dev/null 2>&1; then
      echo "Auth: valid"
    else
      echo "Auth: expired or invalid (run 'signin' again)"
    fi
  else
    echo "Token: none (run 'signin' or 'setup')"
  fi
}

cmd_setup() {
  local res body code
  res=$(curl -s -w "\n%{http_code}" "${PAYRAM_API_URL}/api/v1/member/root/exist")
  body=$(echo "$res" | sed '$d')
  code=$(echo "$res" | tail -1)
  if [[ "$code" != "200" ]]; then
    echo "API unreachable (HTTP $code). Is PayRam running?"
    return 1
  fi
  if echo "$body" | grep -q '"exist":true'; then
    echo "Root user already exists. Use 'signin' then 'create-payment-link'."
    return 0
  fi
  # Register first (root) user
  local email="${PAYRAM_EMAIL:-}"
  local password="${PAYRAM_PASSWORD:-}"
  if [[ -z "$email" ]]; then
    read -p "Email for first user: " email
  fi
  if [[ -z "$password" ]]; then
    read -s -p "Password: " password
    echo
  fi
  res=$(curl -s -w "\n%{http_code}" -X POST "${PAYRAM_API_URL}/api/v1/signup" \
    -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$password\"}")
  body=$(echo "$res" | sed '$d')
  code=$(echo "$res" | tail -1)
  if [[ "$code" != "200" && "$code" != "201" ]]; then
    echo "Signup failed (HTTP $code): $body"
    return 1
  fi
  ACCESS_TOKEN=$(echo "$body" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)
  REFRESH_TOKEN=$(echo "$body" | grep -o '"refreshToken":"[^"]*"' | cut -d'"' -f4)
  CUSTOMER_ID=$(echo "$body" | grep -o '"customer_id":"[^"]*"' | cut -d'"' -f4)
  MEMBER_EMAIL=$(echo "$body" | grep -o '"email":"[^"]*"' | tail -1 | cut -d'"' -f4)
  mkdir -p "$(dirname "$TOKEN_FILE")"
  echo "ACCESS_TOKEN=\"$ACCESS_TOKEN\"" > "$TOKEN_FILE"
  echo "REFRESH_TOKEN=\"$REFRESH_TOKEN\"" >> "$TOKEN_FILE"
  [[ -n "$CUSTOMER_ID" ]] && echo "CUSTOMER_ID=\"$CUSTOMER_ID\"" >> "$TOKEN_FILE"
  [[ -n "$MEMBER_EMAIL" ]] && echo "MEMBER_EMAIL=\"$MEMBER_EMAIL\"" >> "$TOKEN_FILE"
  echo "Signed in as $email"

  # Create default project
  local project_name="${PAYRAM_PROJECT_NAME:-Default Project}"
  res=$(api POST "/api/v1/external-platform" "{\"name\":\"$project_name\"}")
  parse_response "$res"
  if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
    echo "Create project failed (HTTP $HTTP_CODE): $HTTP_BODY"
    return 1
  fi
  echo "Project created: $project_name"
  echo "Setup done. You can run: $0 create-payment-link"
}

cmd_signin() {
  local email="${PAYRAM_EMAIL:-}"
  local password="${PAYRAM_PASSWORD:-}"
  if [[ -z "$email" ]]; then
    read -p "Email: " email
  fi
  if [[ -z "$password" ]]; then
    read -s -p "Password: " password
    echo
  fi
  local res
  res=$(curl -s -w "\n%{http_code}" -X POST "${PAYRAM_API_URL}/api/v1/signin" \
    -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$password\"}")
  parse_response "$res"
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Signin failed (HTTP $HTTP_CODE): $HTTP_BODY"
    return 1
  fi
  ACCESS_TOKEN=$(echo "$HTTP_BODY" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)
  REFRESH_TOKEN=$(echo "$HTTP_BODY" | grep -o '"refreshToken":"[^"]*"' | cut -d'"' -f4)
  CUSTOMER_ID=$(echo "$HTTP_BODY" | grep -o '"customer_id":"[^"]*"' | cut -d'"' -f4)
  MEMBER_EMAIL=$(echo "$HTTP_BODY" | grep -o '"email":"[^"]*"' | tail -1 | cut -d'"' -f4)
  mkdir -p "$(dirname "$TOKEN_FILE")"
  echo "ACCESS_TOKEN=\"$ACCESS_TOKEN\"" > "$TOKEN_FILE"
  echo "REFRESH_TOKEN=\"$REFRESH_TOKEN\"" >> "$TOKEN_FILE"
  [[ -n "$CUSTOMER_ID" ]] && echo "CUSTOMER_ID=\"$CUSTOMER_ID\"" >> "$TOKEN_FILE"
  [[ -n "$MEMBER_EMAIL" ]] && echo "MEMBER_EMAIL=\"$MEMBER_EMAIL\"" >> "$TOKEN_FILE"
  echo "Signed in."
}

cmd_create_payment_link() {
  ensure_token || return 1
  ensure_config || true
  local project_id="${1:-}"
  local customer_email="${2:-}"
  local amount_usd="${3:-}"
  if [[ -z "$project_id" ]]; then
    local res
    res=$(api GET "/api/v1/external-platform/all" "" true)
    parse_response "$res"
    if [[ "$HTTP_CODE" != "200" ]]; then
      echo "Failed to list projects: $HTTP_BODY"
      return 1
    fi
    project_id=$(echo "$HTTP_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
    if [[ -z "$project_id" ]]; then
      echo "No projects. Run 'setup' first."
      return 1
    fi
  fi
  load_tokens
  if [[ -z "$customer_email" ]]; then
    customer_email="${PAYRAM_PAYMENT_EMAIL:-${MEMBER_EMAIL:-}}"
    [[ -z "$customer_email" ]] && read -p "Customer email: " customer_email
    [[ -n "$MEMBER_EMAIL" && -z "$customer_email" ]] && customer_email="$MEMBER_EMAIL"
  fi
  if [[ -z "$amount_usd" ]]; then
    amount_usd="${PAYRAM_PAYMENT_AMOUNT:-10}"
    read -p "Amount (USD) [$amount_usd]: " amount_in
    [[ -n "$amount_in" ]] && amount_usd="$amount_in"
  fi
  local customer_id="${CUSTOMER_ID:-${PAYRAM_CUSTOMER_ID:-}}"
  if [[ -z "$customer_id" ]]; then
    echo "Missing customerID (required by API). Run 'signin' again to save your member customer_id, or set PAYRAM_CUSTOMER_ID."
    return 1
  fi
  local payload="{\"customerID\":\"$customer_id\",\"customerEmail\":\"$customer_email\",\"amountInUSD\":$amount_usd}"
  local res
  res=$(api POST "/api/v1/external-platform/${project_id}/payment" "$payload" true)
  parse_response "$res"
  if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
    log_api_error "Create payment link" "$HTTP_CODE" "$HTTP_BODY" "POST" "${PAYRAM_API_URL}/api/v1/external-platform/${project_id}/payment" "$payload"
    return 1
  fi
  # Extract URL from response, replace \u0026/%5Cu0026 with & so query parses (reference_id & host), print that only for opening
  payment_url=""
  if echo "$HTTP_BODY" | grep -q '"url"'; then
    if command -v python3 >/dev/null 2>&1; then
      payment_url=$(echo "$HTTP_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('url',''))" 2>/dev/null)
    fi
    if [[ -z "$payment_url" ]]; then
      payment_url=$(echo "$HTTP_BODY" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    fi
    payment_url=$(printf '%s' "$payment_url" | sed 's/\\u0026/\&/g; s/%5Cu0026/\&/g; s/%5C%75%30%30%32%36/\&/g')
  fi
  echo ""
  if [[ -n "$payment_url" ]]; then
    echo "--- Open this in your browser (use this URL only) ---"
    echo "$payment_url"
    echo "-----------------------------------------------------"
  else
    echo "--- API response (url not found; raw response below) ---"
  fi
  echo "$HTTP_BODY"
}

# Ensure payram.frontend and payram.backend config exist (required by backend for payment creation).
# In the normal UI flow these are set implicitly on signin/signup from the request (Origin + Host);
# there is no migration or seed for them. Headless signin has no Origin so payram.frontend is never set.
# Seeds config for local API when missing. Requires admin token.
ensure_config() {
  ensure_token || return 1
  local base_url="${PAYRAM_API_URL}"
  local frontend_url="${PAYRAM_FRONTEND_URL:-http://localhost}"
  # Only auto-seed when talking to localhost
  if [[ "$base_url" != *"localhost"* && "$base_url" != *"127.0.0.1"* ]]; then
    return 0
  fi
  local res
  res=$(api GET "/api/v1/configuration/key/payram.frontend" "" true)
  parse_response "$res"
  if [[ "$HTTP_CODE" == "404" || "$HTTP_CODE" == "500" ]] || ! echo "$HTTP_BODY" | grep -q '"key"'; then
    res=$(api POST "/api/v1/configuration/" "{\"key\":\"payram.frontend\",\"value\":\"$frontend_url\"}" true)
    parse_response "$res"
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
      echo "Set payram.frontend to $frontend_url"
    fi
  fi
  res=$(api GET "/api/v1/configuration/key/payram.backend" "" true)
  parse_response "$res"
  if [[ "$HTTP_CODE" == "404" || "$HTTP_CODE" == "500" ]] || ! echo "$HTTP_BODY" | grep -q '"key"'; then
    res=$(api POST "/api/v1/configuration/" "{\"key\":\"payram.backend\",\"value\":\"$base_url\"}" true)
    parse_response "$res"
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
      echo "Set payram.backend to $base_url"
    fi
  fi
}

# Ensure the current project has a linked deposit wallet (required for payment links).
# Optionally create a random wallet (saves mnemonic) or link an existing one.
ensure_wallet() {
  ensure_token || return 1
  load_tokens
  local project_id
  local res
  res=$(api GET "/api/v1/external-platform/all" "" true)
  parse_response "$res"
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Failed to list projects: $HTTP_BODY"
    return 1
  fi
  project_id=$(echo "$HTTP_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
  if [[ -z "$project_id" ]]; then
    echo "No projects. Run 'setup' first."
    return 1
  fi

  res=$(api GET "/api/v1/project/${project_id}/wallet" "" true)
  parse_response "$res"
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Failed to list project wallet (HTTP $HTTP_CODE): $HTTP_BODY"
    return 1
  fi
  # If we already have at least one mapping, we're done
  if echo "$HTTP_BODY" | grep -q '"walletID"'; then
    echo "Project already has a wallet linked."
    return 0
  fi

  echo ""
  echo "This project has no wallet linked. Payment links need a deposit wallet so"
  echo "customers get unique deposit addresses. The API uses XPUB only (no private key sent)."
  echo ""
  echo "  (1) Create a random wallet — mnemonic saved to .payraminfo (or printed)"
  echo "  (2) Link an existing wallet you already created"
  echo "  (3) Skip (link later via dashboard or API)"
  echo ""
  local choice
  read -p "Choice [1]: " choice
  choice="${choice:-1}"

  if [[ "$choice" == "3" ]]; then
    echo "Skipped. Run '$0 ensure-wallet' later or link a wallet in the dashboard."
    return 0
  fi

  if [[ "$choice" == "1" ]]; then
    if ! command -v node >/dev/null 2>&1; then
      echo "Node.js is required to generate a random wallet. Install Node or choose (2) to link an existing wallet."
      return 1
    fi
    local gen script_dir
    script_dir="$SCRIPT_DIR"
    if [[ ! -f "$script_dir/scripts/package.json" ]]; then
      echo "Missing scripts/package.json. Cannot generate wallet."
      return 1
    fi
    (cd "$script_dir/scripts" && [[ ! -d node_modules ]] && npm install --silent 2>/dev/null)
    gen=$(cd "$script_dir/scripts" && node generate-deposit-wallet.js 2>/dev/null)
    if [[ -z "$gen" ]]; then
      echo "Failed to generate wallet. Run: cd scripts && npm install && node generate-deposit-wallet.js"
      return 1
    fi
    local mnemonic xpub parsed
    parsed=$(echo "$gen" | node -e "
      let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
        try { const j=JSON.parse(d); console.log('MNEMONIC', j.mnemonic); console.log('XPUB', j.xpub); }
        catch(e) { process.exit(1); }
      });
    " 2>/dev/null)
    mnemonic=$(echo "$parsed" | grep '^MNEMONIC ' | sed 's/^MNEMONIC //')
    xpub=$(echo "$parsed" | grep '^XPUB ' | sed 's/^XPUB //')
    if [[ -z "$xpub" ]]; then
      echo "Failed to parse generated wallet."
      return 1
    fi
    mkdir -p "$PAYRAM_INFO_DIR"
    local secret_file="${PAYRAM_INFO_DIR}/headless-wallet-secret.txt"
    echo "$mnemonic" > "$secret_file"
    chmod 600 "$secret_file" 2>/dev/null || true
    local payload
    payload="{\"name\":\"Headless\",\"xpubs\":[{\"family\":\"BTC_Family\",\"xpub\":\"$xpub\"}]}"
    res=$(api POST "/api/v1/wallets/deposit/eoa/bulk" "$payload" true)
    parse_response "$res"
    if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
      log_api_error "Create wallet" "$HTTP_CODE" "$HTTP_BODY" "POST" "${PAYRAM_API_URL}/api/v1/wallets/deposit/eoa/bulk" "$payload"
      return 1
    fi
    echo "Wallet created; backend is linking it to your project..."
    # Backend links the wallet in a goroutine, so wait for the mapping to appear
    local wait_max=15
    local waited=0
    while [[ $waited -lt $wait_max ]]; do
      sleep 1
      waited=$((waited + 1))
      res=$(api GET "/api/v1/project/${project_id}/wallet" "" true)
      parse_response "$res"
      if [[ "$HTTP_CODE" == "200" ]] && echo "$HTTP_BODY" | grep -q '"walletID"'; then
        echo "Wallet linked to your project."
        break
      fi
      if [[ $waited -eq $wait_max ]]; then
        echo "Wallet created but link is still pending. Wait a few seconds and run create-payment-link again."
      fi
    done
    echo "Mnemonic (backup securely) saved to: $secret_file"
    echo "You can also print it later from that file. Never share it or send it to the API."
    return 0
  fi

  if [[ "$choice" == "2" ]]; then
    res=$(api GET "/api/v1/wallets" "" true)
    parse_response "$res"
    if [[ "$HTTP_CODE" != "200" ]]; then
      echo "Failed to list wallets (HTTP $HTTP_CODE): $HTTP_BODY"
      return 1
    fi
    local wallet_id family
    parsed=$(echo "$HTTP_BODY" | node -e "
      let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
        try {
          const list=JSON.parse(d);
          if(!Array.isArray(list)||list.length===0) { console.log('NONE'); process.exit(0); }
          const x=list.find(w=>w.walletType==='deposit_wallet')||list[0];
          const fam=(x.walletxpubs&&x.walletxpubs[0]&&x.walletxpubs[0].family)||'BTC_Family';
          console.log('WALLET_ID', x.id);
          console.log('FAMILY', fam);
        } catch(e) { process.exit(1); }
      });
    " 2>/dev/null)
    wallet_id=$(echo "$parsed" | grep '^WALLET_ID ' | sed 's/^WALLET_ID //')
    family=$(echo "$parsed" | grep '^FAMILY ' | sed 's/^FAMILY //')
    if [[ -z "$wallet_id" ]]; then
      # Fallback without Node: take first id and family from JSON
      wallet_id=$(echo "$HTTP_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
      family=$(echo "$HTTP_BODY" | grep -o '"family":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    if [[ -z "$wallet_id" ]]; then
      echo "No wallets found. Create one in the dashboard or use option (1) to create a random wallet."
      return 1
    fi
    [[ -z "$family" ]] && family="BTC_Family"
    payload="{\"wallets\":[{\"walletID\":$wallet_id,\"blockchainFamily\":\"$family\"}]}"
    res=$(api POST "/api/v1/project/${project_id}/wallet" "$payload" true)
    parse_response "$res"
    if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
      log_api_error "Link wallet to project" "$HTTP_CODE" "$HTTP_BODY" "POST" "${PAYRAM_API_URL}/api/v1/project/${project_id}/wallet" "$payload"
      return 1
    fi
    echo "Linked wallet $wallet_id ($family) to project."
    return 0
  fi

  echo "Invalid choice."
  return 1
}

cmd_ensure_wallet() {
  ensure_wallet
}

# Deploy ETH/EVM SCW deposit wallet (same as frontend flow; we sign with mnemonic). Requires admin token.
cmd_deploy_scw() {
  echo "deploy-scw: checking token..."
  ensure_token || { echo "Sign in first: $0 signin"; return 1; }
  load_tokens
  if [[ -z "${ACCESS_TOKEN:-}" ]]; then
    echo "No token. Run: $0 signin"
    return 1
  fi
  echo "deploy-scw: token OK."
  local script_path="${SCRIPT_DIR}/scripts/deploy-scw-eth.js"
  if [[ ! -f "$script_path" ]]; then
    echo "Missing $script_path"
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "Node.js required to run deploy-scw."
    return 1
  fi
  echo "deploy-scw: installing deps if needed..."
  (cd "$SCRIPT_DIR/scripts" && { [[ ! -d node_modules ]] && npm install --silent 2>/dev/null; true; })
  export PAYRAM_API_URL
  export PAYRAM_ACCESS_TOKEN="$ACCESS_TOKEN"
  export PAYRAM_MNEMONIC_FILE="${PAYRAM_INFO_DIR}/headless-wallet-secret.txt"
  [[ -n "${PAYRAM_ETH_RPC_URL:-}" ]] && export PAYRAM_ETH_RPC_URL
  # Only export fund collector if it looks like a valid 0x address (ignore placeholders)
  if [[ -n "${PAYRAM_FUND_COLLECTOR:-}" ]] && [[ "$PAYRAM_FUND_COLLECTOR" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    export PAYRAM_FUND_COLLECTOR
  else
    PAYRAM_FUND_COLLECTOR=""
  fi
  [[ -n "${PAYRAM_SCW_NAME:-}" ]] && export PAYRAM_SCW_NAME
  [[ -n "${PAYRAM_BLOCKCHAIN_CODE:-}" ]] && export PAYRAM_BLOCKCHAIN_CODE
  if [[ -z "${PAYRAM_ETH_RPC_URL:-}" ]] || [[ "$PAYRAM_ETH_RPC_URL" =~ YOUR_ACTUAL|YOUR_KEY ]]; then
    echo ""
    echo "PAYRAM_ETH_RPC_URL (optional; default = PublicNode Sepolia, no key). Press Enter for default:"
    read -r rpc
    if [[ -n "$rpc" ]] && [[ ! "$rpc" =~ YOUR_ACTUAL|YOUR_KEY ]]; then
      export PAYRAM_ETH_RPC_URL="$rpc"
    fi
  fi
  if [[ -z "${PAYRAM_FUND_COLLECTOR:-}" ]]; then
    echo ""
    echo "PAYRAM_FUND_COLLECTOR (cold wallet 0x address, or press Enter to use deployer address):"
    read -r fc
    fc=$(echo "$fc" | tr -d ' ')
    if [[ -n "$fc" ]] && [[ "$fc" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
      export PAYRAM_FUND_COLLECTOR="$fc"
    fi
    # If still empty, script will use deployer address from mnemonic
  fi
  echo "Deploying ETH SCW (mnemonic from $PAYRAM_MNEMONIC_FILE or PAYRAM_MNEMONIC)..."
  local deploy_log
  deploy_log="${PAYRAM_INFO_DIR}/.deploy-scw.log"
  mkdir -p "$PAYRAM_INFO_DIR"
  node "$script_path" 2>&1 | tee "$deploy_log"
  local node_exit=${PIPESTATUS[0]:-1}
  local deploy_out
  deploy_out=$(cat "$deploy_log" 2>/dev/null)
  local wallet_id family
  wallet_id=$(echo "$deploy_out" | grep '^PAYRAM_WALLET_ID=' | cut -d= -f2-)
  family=$(echo "$deploy_out" | grep '^PAYRAM_WALLET_FAMILY=' | cut -d= -f2-)
  [[ -z "$family" ]] && family="ETH_Family"
  if [[ $node_exit -ne 0 ]]; then
    echo ""
    echo "deploy-scw failed (exit $node_exit). Fix errors above and try again."
    return 1
  fi
  if [[ -n "$wallet_id" ]]; then
    echo ""
    echo "Linking SCW wallet to current project..."
    local project_id res
    res=$(api GET "/api/v1/external-platform/all" "" true)
    parse_response "$res"
    if [[ "$HTTP_CODE" == "200" ]]; then
      project_id=$(echo "$HTTP_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
      if [[ -n "$project_id" ]]; then
        local payload="{\"wallets\":[{\"walletID\":$wallet_id,\"blockchainFamily\":\"$family\"}]}"
        res=$(api POST "/api/v1/project/${project_id}/wallet" "$payload" true)
        parse_response "$res"
        if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
          echo "SCW wallet linked to project. You can create payment links (no extra setup)."
        else
          echo "Deploy succeeded but linking to project failed (HTTP $HTTP_CODE). Link manually in dashboard or run ensure-wallet and choose (2)."
        fi
      fi
    fi
  fi
}

# Interactive menu: choose which step to run
cmd_menu() {
  echo "PayRam Headless — choose a step"
  echo "API: $PAYRAM_API_URL"
  echo ""
  echo "  1) status             — Check API and auth status"
  echo "  2) setup              — First-time: register root user + create default project"
  echo "  3) signin             — Sign in (saves token; required for most steps)"
  echo "  4) ensure-config      — Seed payram.frontend / payram.backend (local API)"
  echo "  5) ensure-wallet      — Create BTC wallet or link existing (for payment links)"
  echo "  6) deploy-scw         — Deploy ETH/EVM smart-contract deposit wallet (admin)"
  echo "  7) create-payment-link — Create a payment link"
  echo "  8) run                — Full flow: setup/signin → wallet → payment link"
  echo "  9) reset-local        — Clear database and API data; re-run install"
  echo "  0) exit"
  echo ""
  read -p "Choice [0]: " choice
  choice="${choice:-0}"
  case "$choice" in
    1) cmd_status ;;
    2) cmd_setup ;;
    3) cmd_signin ;;
    4) ensure_config ;;
    5) cmd_ensure_wallet ;;
    6) cmd_deploy_scw ;;
    7) cmd_create_payment_link "$@" ;;
    8) cmd_run ;;
    9) cmd_reset_local ;;
    0) echo "Bye." ; return 0 ;;
    *) echo "Invalid choice." ; return 1 ;;
  esac
}

cmd_reset_local() {
  local skip_prompt=""
  for a in "$@"; do
    [[ "$a" == "-y" || "$a" == "--yes" ]] && skip_prompt=1 && break
  done

  echo "Reset PayRam local setup (clears database and API data so you can re-run headless from scratch)."
  echo "  • Stops and removes the payram container"
  echo "  • Removes .payraminfo (tokens, config, wallet backup)"
  echo "  • Removes .payram-core (database, logs)"
  echo "  • Removes .payram-setup.log"
  echo "Then you can run ./run_local.sh again and use ./headless.sh (setup, wallet, payment link)."
  echo ""
  if [[ -z "$skip_prompt" ]]; then
    read -p "Clear database and API data? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
      echo "Cancelled."
      return 0
    fi
  fi

  echo "Stopping and removing payram container..."
  docker stop payram 2>/dev/null || true
  docker rm -f payram 2>/dev/null || true
  [[ -d "$PAYRAM_CORE_DIR" ]] && rm -rf "$PAYRAM_CORE_DIR" && echo "Removed $PAYRAM_CORE_DIR"
  [[ -d "$PAYRAM_INFO_DIR" ]] && rm -rf "$PAYRAM_INFO_DIR" && echo "Removed $PAYRAM_INFO_DIR"
  local log_file="${LOG_FILE:-$SCRIPT_DIR/.payram-setup.log}"
  [[ -f "$log_file" ]] && rm -f "$log_file" && echo "Removed $log_file"
  echo "Database and API data cleared. Run ./run_local.sh and choose option 1 (Install PayRam) to start fresh."
  echo ""

  # Optional: full clean (Docker image + system prune)
  if [[ -z "$skip_prompt" ]]; then
    read -p "Also perform full clean (remove PayRam Docker image and run 'docker system prune -f')? (y/N): " full
    if [[ "$full" =~ ^[Yy] ]]; then
      echo "Removing PayRam Docker image(s)..."
      docker images --filter=reference='payramapp/payram' -q 2>/dev/null | xargs docker rmi -f 2>/dev/null || true
      echo "Running docker system prune -f..."
      docker system prune -f
      echo "Full clean done."
    fi
  else
    echo "Skipping full clean (use reset-local without -y to be asked)."
  fi
}

# Single interactive flow: setup/signin (if needed) then create payment link with prompts and defaults
cmd_run() {
  echo "PayRam headless — setup to payment link"
  echo "API: $PAYRAM_API_URL"
  echo ""

  local res code body
  res=$(curl -s -w "\n%{http_code}" "${PAYRAM_API_URL}/api/v1/member/root/exist" 2>/dev/null || echo -e "\n000")
  body=$(echo "$res" | sed '$d')
  code=$(echo "$res" | tail -1)
  if [[ "$code" != "200" ]]; then
    echo "API unreachable. Is PayRam running? (e.g. ./run_local.sh)"
    return 1
  fi

  if echo "$body" | grep -q '"exist":true'; then
    if ! ensure_token >/dev/null 2>&1; then
      echo "Sign in (root user already exists)"
      load_tokens
      local email="${PAYRAM_EMAIL:-${MEMBER_EMAIL:-}}"
      read -p "Email [${email:-}]: " email_in
      [[ -n "$email_in" ]] && email="$email_in"
      [[ -z "$email" ]] && echo "Email required." && return 1
      local password="${PAYRAM_PASSWORD:-}"
      [[ -z "$password" ]] && read -s -p "Password: " password && echo
      res=$(curl -s -w "\n%{http_code}" -X POST "${PAYRAM_API_URL}/api/v1/signin" \
        -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$password\"}")
      parse_response "$res"
      if [[ "$HTTP_CODE" != "200" ]]; then
        echo "Signin failed (HTTP $HTTP_CODE): $HTTP_BODY"
        return 1
      fi
      ACCESS_TOKEN=$(echo "$HTTP_BODY" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)
      REFRESH_TOKEN=$(echo "$HTTP_BODY" | grep -o '"refreshToken":"[^"]*"' | cut -d'"' -f4)
      CUSTOMER_ID=$(echo "$HTTP_BODY" | grep -o '"customer_id":"[^"]*"' | cut -d'"' -f4)
      MEMBER_EMAIL=$(echo "$HTTP_BODY" | grep -o '"email":"[^"]*"' | tail -1 | cut -d'"' -f4)
      mkdir -p "$(dirname "$TOKEN_FILE")"
      echo "ACCESS_TOKEN=\"$ACCESS_TOKEN\"" > "$TOKEN_FILE"
      echo "REFRESH_TOKEN=\"$REFRESH_TOKEN\"" >> "$TOKEN_FILE"
      [[ -n "$CUSTOMER_ID" ]] && echo "CUSTOMER_ID=\"$CUSTOMER_ID\"" >> "$TOKEN_FILE"
      [[ -n "$MEMBER_EMAIL" ]] && echo "MEMBER_EMAIL=\"$MEMBER_EMAIL\"" >> "$TOKEN_FILE"
      echo "Signed in."
    fi
  else
    echo "First-time setup: create first user and project"
    local email="${PAYRAM_EMAIL:-}"
    read -p "Email for first user [admin@example.com]: " email_in
    email="${email_in:-${email:-admin@example.com}}"
    local password="${PAYRAM_PASSWORD:-}"
    [[ -z "$password" ]] && read -s -p "Password: " password && echo
    res=$(curl -s -w "\n%{http_code}" -X POST "${PAYRAM_API_URL}/api/v1/signup" \
      -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$password\"}")
    parse_response "$res"
    if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
      echo "Signup failed (HTTP $HTTP_CODE): $HTTP_BODY"
      return 1
    fi
    ACCESS_TOKEN=$(echo "$HTTP_BODY" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)
    REFRESH_TOKEN=$(echo "$HTTP_BODY" | grep -o '"refreshToken":"[^"]*"' | cut -d'"' -f4)
    CUSTOMER_ID=$(echo "$HTTP_BODY" | grep -o '"customer_id":"[^"]*"' | cut -d'"' -f4)
    MEMBER_EMAIL=$(echo "$HTTP_BODY" | grep -o '"email":"[^"]*"' | tail -1 | cut -d'"' -f4)
    mkdir -p "$(dirname "$TOKEN_FILE")"
    echo "ACCESS_TOKEN=\"$ACCESS_TOKEN\"" > "$TOKEN_FILE"
    echo "REFRESH_TOKEN=\"$REFRESH_TOKEN\"" >> "$TOKEN_FILE"
    [[ -n "$CUSTOMER_ID" ]] && echo "CUSTOMER_ID=\"$CUSTOMER_ID\"" >> "$TOKEN_FILE"
    [[ -n "$MEMBER_EMAIL" ]] && echo "MEMBER_EMAIL=\"$MEMBER_EMAIL\"" >> "$TOKEN_FILE"
    echo "Signed in as $email"
    local project_name="${PAYRAM_PROJECT_NAME:-Default Project}"
    read -p "Project name [$project_name]: " pn_in
    [[ -n "$pn_in" ]] && project_name="$pn_in"
    res=$(api POST "/api/v1/external-platform" "{\"name\":\"$project_name\"}")
    parse_response "$res"
    if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
      echo "Create project failed (HTTP $HTTP_CODE): $HTTP_BODY"
      return 1
    fi
    echo "Project created: $project_name"
  fi

  ensure_token || return 1
  load_tokens

  local project_id
  res=$(api GET "/api/v1/external-platform/all" "" true)
  parse_response "$res"
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Failed to list projects: $HTTP_BODY"
    return 1
  fi
  project_id=$(echo "$HTTP_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
  if [[ -z "$project_id" ]]; then
    echo "No projects."
    return 1
  fi

  ensure_config || true
  ensure_wallet || true

  echo ""
  echo "Create payment link"
  local customer_email="${PAYRAM_PAYMENT_EMAIL:-${MEMBER_EMAIL:-}}"
  read -p "Customer email [$customer_email]: " email_in
  [[ -n "$email_in" ]] && customer_email="$email_in"
  [[ -z "$customer_email" ]] && customer_email="${MEMBER_EMAIL:-}"
  local amount_usd="${PAYRAM_PAYMENT_AMOUNT:-10}"
  read -p "Amount (USD) [$amount_usd]: " amount_in
  [[ -n "$amount_in" ]] && amount_usd="$amount_in"

  local customer_id="${CUSTOMER_ID:-${PAYRAM_CUSTOMER_ID:-}}"
  if [[ -z "$customer_id" ]]; then
    echo "Missing customerID. Run: $0 signin"
    return 1
  fi

  local payload="{\"customerID\":\"$customer_id\",\"customerEmail\":\"$customer_email\",\"amountInUSD\":$amount_usd}"
  res=$(api POST "/api/v1/external-platform/${project_id}/payment" "$payload" true)
  parse_response "$res"
  if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
    log_api_error "Create payment link" "$HTTP_CODE" "$HTTP_BODY" "POST" "${PAYRAM_API_URL}/api/v1/external-platform/${project_id}/payment" "$payload"
    return 1
  fi
  payment_url=""
  if echo "$HTTP_BODY" | grep -q '"url"'; then
    if command -v python3 >/dev/null 2>&1; then
      payment_url=$(echo "$HTTP_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('url',''))" 2>/dev/null)
    fi
    if [[ -z "$payment_url" ]]; then
      payment_url=$(echo "$HTTP_BODY" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    fi
    payment_url=$(printf '%s' "$payment_url" | sed 's/\\u0026/\&/g; s/%5Cu0026/\&/g; s/%5C%75%30%30%32%36/\&/g')
  fi
  echo ""
  if [[ -n "$payment_url" ]]; then
    echo "--- Open this in your browser (use this URL only) ---"
    echo "$payment_url"
    echo "-----------------------------------------------------"
  else
    echo "--- API response (url not found; raw response below) ---"
  fi
  echo "$HTTP_BODY"
}

usage() {
  echo "PayRam Headless CLI"
  echo ""
  echo "Usage: $0 [command] [args]"
  echo "  (no command) or menu - Show step menu; choose which step to run"
  echo "  run                - Full flow: setup/signin then create payment link (prompts + defaults)"
  echo "  status             - Check API and auth status"
  echo "  setup              - First-time: register root user + create default project"
  echo "  signin             - Sign in (saves token; required for wallet/payment/deploy-scw)"
  echo "  ensure-config      - Seed payram.frontend / payram.backend for local API (if missing)"
  echo "  ensure-wallet      - Create a random BTC wallet or link an existing one to the project"
  echo "  deploy-scw         - Deploy ETH/EVM smart-contract deposit wallet (admin token + RPC + fund collector)"
  echo "  create-payment-link [projectId] [email] [amountUSD] - Create payment link"
  echo "  reset-local [-y]   - Clear database and API data (optional: full Docker clean); -y skips prompts"
  echo ""
  echo "Env (optional): PAYRAM_API_URL, PAYRAM_EMAIL, PAYRAM_PASSWORD, PAYRAM_PROJECT_NAME,"
  echo "               PAYRAM_PAYMENT_EMAIL, PAYRAM_PAYMENT_AMOUNT, PAYRAM_CUSTOMER_ID,"
  echo "               PAYRAM_FRONTEND_URL (default http://localhost), PAYRAM_DEBUG=1"
  echo "               deploy-scw: PAYRAM_ETH_RPC_URL (default: PublicNode Sepolia, no key), PAYRAM_FUND_COLLECTOR, PAYRAM_SCW_NAME"
  echo "Default API: $PAYRAM_API_URL"
  echo ""
  echo "Wallet: Payment links need a deposit wallet. ensure-wallet = BTC (or link existing)."
  echo "        deploy-scw = ETH/EVM SCW (sign with mnemonic in .payraminfo)."
  echo "        Full context and env: docs/PAYRAM_HEADLESS_AGENT.md"
}

main() {
  local cmd="${1:-menu}"
  shift 2>/dev/null || true
  case "$cmd" in
    status)   cmd_status ;;
    setup)    cmd_setup ;;
    signin)   cmd_signin ;;
    ensure-config) ensure_config ;;
    ensure-wallet) cmd_ensure_wallet ;;
    deploy-scw) cmd_deploy_scw ;;
    create-payment-link) cmd_create_payment_link "$@" ;;
    reset-local) cmd_reset_local "$@" ;;
    menu)     cmd_menu "$@" ;;
    run)      cmd_run ;;
    -h|--help) usage ;;
    "")
      cmd_menu "$@"
      ;;
    *)
      echo "Unknown command: $cmd"
      usage
      return 1
      ;;
  esac
}

main "$@"
