#!/bin/bash
# PayRam Agent CLI - single entrypoint for install and headless flows.
# Supports running via wget/curl by self-fetching required assets when missing.

set -euo pipefail

log() {
	echo "[agent] $*"
}

usage() {
	cat <<'EOF'
Usage:
	setup_payram_agents.sh [options]            One-step flow (install -> payment link)
	setup_payram_agents.sh <command> [args]     Headless commands only

Quick start (run from a terminal; defaults at the install questions are fine):
	./setup_payram_agents.sh
	# Default flow (MVF): EVM smart-contract wallet on BASE -> payment link
	# that accepts USDC. Master wallet is local + ops-only; on mainnet the
	# sweep destination is YOUR cold address (PAYRAM_FUND_COLLECTOR). The one
	# human wait is funding the deployer with gas (~$10, Ethereum or Base).
	# Credentials are auto-created if PAYRAM_EMAIL/PAYRAM_PASSWORD are unset.
	# BTC comes later:  ./setup_payram_agents.sh ensure-wallet

One-step options:
	--mainnet               Install/run in mainnet mode (default - real payments)
	--testnet               Install/run in testnet mode (try it with free test coins)
	--restart               Restart PayRam container before headless steps
	--deploy-scw            EVM SCW first on BASE -> USDC link (default; needs gas funding)
	--ensure-wallet         BTC-first fast lane instead: XPUB wallet, no gas; SCW follows the link
	--skip-scw              Skip the SCW entirely (no gas): BTC-only fast lane
	--merchant              Merchant role: take payments for YOUR business (default)
	--operator              Operator role: run PayRam as a platform for other merchants,
	                        taking a bps fee (needs PAYRAM_OPERATOR_*_FEE_COLLECTOR)
	--wallet-choice=1|2|3   Wallet flow choice (1=create, 2=link, 3=skip)
	--skip-payment-link     Do not create a payment link
	--create-payment-link   Create a payment link (default)
	--skip-mcp-server       Do not start the Analytics MCP server
	--mcp-port=NUMBER       MCP server HTTP port (default 3333)
	--node-mode=host|docker Node runtime for JS (default docker)
	-h, --help              Show help

Headless commands:
	status | setup | signin | ensure-config | ensure-wallet | deploy-scw | deploy-scw-flow
	setup-mode [merchant|operator]    Show or set the install role
	ensure-operator-config            Fee collectors + default fees (operator)
	ensure-api-key                    Mint/reuse the project's merchant API key (for MCP/integrations)
	create-payment-link [projectId] [email] [amountUSD]
	start-mcp-server
	reset-local [-y]
	menu | run

Env vars:
	PAYRAM_NETWORK (testnet|mainnet)
	PAYRAM_SETUP_MODE (merchant|operator; default merchant)
	Fresh install: needs a terminal once (the installer asks DB/SSL/port).
	Every step AFTER the install runs fully headless.
	PAYRAM_OPERATOR_BTC_FEE_COLLECTOR, PAYRAM_OPERATOR_EVM_FEE_COLLECTOR
	PAYRAM_OPERATOR_FEE_BPS (default 100 = 1%, max 1500)
	PAYRAM_API_URL (default: derived from installed config.env / running container)
	PAYRAM_EMAIL, PAYRAM_PASSWORD, PAYRAM_PROJECT_NAME
	PAYRAM_PAYMENT_EMAIL, PAYRAM_PAYMENT_AMOUNT, PAYRAM_CUSTOMER_ID
	PAYRAM_FRONTEND_URL
	PAYRAM_ETH_RPC_URL, PAYRAM_FUND_COLLECTOR, PAYRAM_SCW_NAME, PAYRAM_BLOCKCHAIN_CODE, PAYRAM_MNEMONIC
	PAYRAM_FORCE_DEPLOY=1 (deploy another SCW even if one is already linked)
	PAYRAM_ACCEPT_MAINNET_COSTS=1 (required for non-interactive mainnet SCW deploy)
	PAYRAM_NODE_DOCKER_IMAGE (default node:20-bullseye-slim)
	PAYRAM_SCRIPTS_REF (default main)
	PAYRAM_MCP_VERSION (default v1.1.0)
	PAYRAM_MCP_PORT (default 3333)
EOF
}

resolve_base_dir() {
	local src="${BASH_SOURCE[0]:-$0}"
	if [[ -f "$src" ]]; then
		(cd "$(dirname "$src")" && pwd)
	else
		echo "$PWD"
	fi
}

fetch_file() {
	local url="$1"
	local dest="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" -o "$dest"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$dest" "$url"
	else
		echo "curl or wget is required to download agent assets."
		return 1
	fi
}

SCRIPT_DIR="$(resolve_base_dir)"
ASSET_DIR="$SCRIPT_DIR"
TEMP_DIR=""
ORIG_DIR="$PWD"

ensure_assets() {
	if [[ -f "$ASSET_DIR/setup_payram.sh" && -f "$ASSET_DIR/scripts/package.json" && -f "$ASSET_DIR/scripts/deploy-scw-eth.js" ]]; then
		return 0
	fi

	local ref="${PAYRAM_SCRIPTS_REF:-main}"
	local base_url="https://raw.githubusercontent.com/PayRam/payram-scripts/${ref}"
	TEMP_DIR="$(mktemp -d)"
	ASSET_DIR="${TEMP_DIR}/payram-scripts"
	mkdir -p "$ASSET_DIR/scripts"

	fetch_file "$base_url/setup_payram.sh" "$ASSET_DIR/setup_payram.sh"
	fetch_file "$base_url/scripts/package.json" "$ASSET_DIR/scripts/package.json"
	fetch_file "$base_url/scripts/generate-deposit-wallet.js" "$ASSET_DIR/scripts/generate-deposit-wallet.js"
	fetch_file "$base_url/scripts/generate-deposit-wallet-eth.js" "$ASSET_DIR/scripts/generate-deposit-wallet-eth.js"
	fetch_file "$base_url/scripts/deploy-scw-eth.js" "$ASSET_DIR/scripts/deploy-scw-eth.js"

	chmod +x "$ASSET_DIR/setup_payram.sh"
	trap '[[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"' EXIT
}

run_as_root() {
	if [[ "$EUID" -ne 0 ]]; then
		if command -v sudo >/dev/null 2>&1; then
			sudo -E "$@"
		else
			echo "sudo is required to run system installation steps."
			return 1
		fi
	else
		"$@"
	fi
}

wait_for_api() {
	local max_tries=60
	local wait_secs=2
	for ((i=1; i<=max_tries; i++)); do
		local code
		code=$(curl -s -o /dev/null -w "%{http_code}" "${PAYRAM_API_URL}/api/v1/member/root/exist" 2>/dev/null || echo "000")
		if [[ "$code" == "200" ]]; then
			return 0
		fi
		sleep "$wait_secs"
	done
	return 1
}

root_exists() {
	local res body code
	res=$(curl -s -w "\n%{http_code}" "${PAYRAM_API_URL}/api/v1/member/root/exist" 2>/dev/null || echo -e "\n000")
	body=$(echo "$res" | sed '$d')
	code=$(echo "$res" | tail -1)
	if [[ "$code" != "200" ]]; then
		return 2
	fi
	if echo "$body" | grep -q '"exist":true'; then
		return 0
	fi
	return 1
}

is_payram_running() {
	command -v docker >/dev/null 2>&1 || return 1
	docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^payram$'
}

# Initialise globals WITHOUT stomping caller-provided env overrides
# (PAYRAM_API_URL=... ./setup_payram_agents.sh must be honoured).
PAYRAM_INFO_DIR="${PAYRAM_INFO_DIR:-}"
PAYRAM_CORE_DIR="${PAYRAM_CORE_DIR:-}"
PAYRAM_API_URL="${PAYRAM_API_URL:-}"
TOKEN_FILE=""
CREDENTIALS_FILE=""
PAYRAM_NODE_MODE="${PAYRAM_NODE_MODE:-}"
PAYRAM_NODE_DOCKER_IMAGE="${PAYRAM_NODE_DOCKER_IMAGE:-}"
NODE_MODE_RESOLVED=""
INSTALL_CONFIG_FILE=""
INSTALL_HOME=""
INSTALL_NETWORK=""
DERIVED_API_URL=""
SCW_STATE_FILE=""
API_KEY_FILE=""

# setup_payram.sh is the source of truth for an installation. It persists every
# install-time decision (ports, dirs, network, SSL) in config.env - so we READ
# those facts instead of assuming them. The installer publishes the API on port
# 80 by default (RETAINED_PORTS="80:80"), NOT 8080.
load_install_config() {
	local candidate
	for candidate in \
		"${HOME}/.payraminfo/config.env" \
		"/root/.payraminfo/config.env" \
		"${ORIG_DIR}/.payraminfo/config.env"; do
		if [[ -r "$candidate" ]]; then
			INSTALL_CONFIG_FILE="$candidate"
			break
		fi
	done

	local retained_ports="" ssl_cert_path=""
	if [[ -n "$INSTALL_CONFIG_FILE" ]]; then
		# Source in a subshell so DB credentials / AES key never enter our env.
		local vals
		vals=$(
			# shellcheck source=/dev/null
			set +u
			source "$INSTALL_CONFIG_FILE" 2>/dev/null
			printf '%s\n%s\n%s\n%s\n' "${RETAINED_PORTS:-}" "${PAYRAM_HOME:-}" "${NETWORK_TYPE:-}" "${SSL_CERT_PATH:-}"
		)
		{ read -r retained_ports; read -r INSTALL_HOME; read -r INSTALL_NETWORK; read -r ssl_cert_path; } <<< "$vals" || true
	fi

	# Caller pinned the URL explicitly (captured in main before defaults were
	# applied) - nothing to derive, and no docker probe needed.
	if [[ -n "${PAYRAM_API_URL_OVERRIDE:-}" ]]; then
		DERIVED_API_URL="$PAYRAM_API_URL_OVERRIDE"
		return 0
	fi

	# Derive the API URL: SSL install -> https on the 443 mapping; otherwise
	# http on whatever host port maps to container port 80.
	local tok host cont http_port="" https_port=""
	for tok in $retained_ports; do
		tok="${tok%%/*}"
		host="${tok%%:*}"
		cont="${tok##*:}"
		[[ "$cont" == "80" && -z "$http_port" ]] && http_port="$host"
		[[ "$cont" == "443" && -z "$https_port" ]] && https_port="$host"
	done
	if [[ -n "$ssl_cert_path" && -n "$https_port" ]]; then
		DERIVED_API_URL=$(localhost_url https "$https_port" 443)
	elif [[ -n "$http_port" ]]; then
		DERIVED_API_URL=$(localhost_url http "$http_port" 80)
	elif command -v docker >/dev/null 2>&1; then
		# No config.env - ask the running container which host port serves :80.
		# (|| true: docker port fails when the container doesn't exist, and a
		# failing command substitution would kill the script under set -e.)
		local published
		published=$(docker port payram 80/tcp 2>/dev/null | head -1 | sed 's/.*://' || true)
		[[ -n "$published" ]] && DERIVED_API_URL=$(localhost_url http "$published" 80)
	fi
	# Last resort: the installer's default mapping is 80:80.
	[[ -z "$DERIVED_API_URL" ]] && DERIVED_API_URL="http://localhost"
}

load_tokens() {
	if [[ -f "$TOKEN_FILE" ]]; then
		# shellcheck source=/dev/null
		source "$TOKEN_FILE"
	fi
}

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

parse_response() {
	local response="$1"
	HTTP_BODY=$(echo "$response" | sed '$d')
	HTTP_CODE=$(echo "$response" | tail -1)
}

# Parse the 4 auth fields out of a signin/signup response body into the
# globals save_tokens persists. (refresh_token keeps its own 2-field parse -
# refresh responses don't carry customer_id/email.)
parse_auth_tokens() {
	local body="$1"
	ACCESS_TOKEN=$(echo "$body" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)
	REFRESH_TOKEN=$(echo "$body" | grep -o '"refreshToken":"[^"]*"' | cut -d'"' -f4)
	CUSTOMER_ID=$(echo "$body" | grep -o '"customer_id":"[^"]*"' | cut -d'"' -f4)
	MEMBER_EMAIL=$(echo "$body" | grep -o '"email":"[^"]*"' | tail -1 | cut -d'"' -f4)
}

# List projects, spanning core versions: older images serve
# /external-platform/all; current core serves /external-platform/details.
# Try the new path first, fall back to the legacy one. Sets HTTP_CODE/HTTP_BODY.
api_list_projects() {
	local res
	res=$(api GET "/api/v1/external-platform/details" "" true)
	parse_response "$res"
	if [[ "$HTTP_CODE" == "404" || "$HTTP_CODE" == "405" ]]; then
		res=$(api GET "/api/v1/external-platform/all" "" true)
		parse_response "$res"
	fi
}

# First project id - the script's "current project" policy, in ONE place.
# Echoes the id; guidance goes to stderr so $(capture) stays clean.
get_first_project_id() {
	api_list_projects
	if [[ "$HTTP_CODE" != "200" ]]; then
		echo "Failed to list projects: $HTTP_BODY" >&2
		return 1
	fi
	local id
	id=$(echo "$HTTP_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2 || true)
	if [[ -z "$id" ]]; then
		echo "No projects. Run 'setup' first." >&2
		return 1
	fi
	echo "$id"
}

# scheme + port -> localhost URL, omitting the scheme's default port.
localhost_url() {
	if [[ "$2" == "$3" ]]; then
		echo "$1://localhost"
	else
		echo "$1://localhost:$2"
	fi
}

# The one place testnet faucet links live (used by the funding card AND the
# gas troubleshooting card - keeping them identical by construction).
print_testnet_faucets() {
	# Chain-aware: point the human at faucets for the chain actually being
	# funded (default flow deploys on BASE).
	case "${PAYRAM_BLOCKCHAIN_CODE:-ETH}" in
		BASE)
			echo "  https://www.alchemy.com/faucets/base-sepolia"
			echo "  https://faucet.quicknode.com/base/sepolia"
			;;
		POLYGON)
			echo "  https://faucet.polygon.technology (Amoy)"
			echo "  https://www.alchemy.com/faucets/polygon-amoy"
			;;
		*)
			echo "  https://cloud.google.com/application/web3/faucet/ethereum/sepolia"
			echo "  https://www.alchemy.com/faucets/ethereum-sepolia"
			;;
	esac
}

# Find the id of the first JSON-list element whose <field> equals <value>.
# Tolerates {items:[...]}/{data:[...]} wrappers; reads the JSON on stdin.
json_find_id_by() {
	python3 -c "
import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('items') or d.get('data') or []
print(next((x['id'] for x in d if str(x.get(sys.argv[1]))==sys.argv[2]),''))
" "$1" "$2" 2>/dev/null || true
}

# Persist auth tokens from the current ACCESS_TOKEN/REFRESH_TOKEN/CUSTOMER_ID/
# MEMBER_EMAIL globals. Tokens are credentials: 600 like the wallet mnemonic.
save_tokens() {
	mkdir -p "$(dirname "$TOKEN_FILE")"
	echo "ACCESS_TOKEN=\"$ACCESS_TOKEN\"" > "$TOKEN_FILE"
	echo "REFRESH_TOKEN=\"$REFRESH_TOKEN\"" >> "$TOKEN_FILE"
	[[ -n "${CUSTOMER_ID:-}" ]] && echo "CUSTOMER_ID=\"$CUSTOMER_ID\"" >> "$TOKEN_FILE"
	[[ -n "${MEMBER_EMAIL:-}" ]] && echo "MEMBER_EMAIL=\"$MEMBER_EMAIL\"" >> "$TOKEN_FILE"
	chmod 600 "$TOKEN_FILE" 2>/dev/null || true
}

# ── Setup mode (merchant vs operator) ────────────────────────────────
# PayRam installs run in one of two roles, stored as the backend config
# payram.setup_mode and picked on first run (the FE shows a role wizard):
#   merchant - you take payments for YOUR business (default).
#   operator - you run PayRam as a platform for OTHER merchants and take a
#              fee (bps) on their volume, paid to YOUR fee-collector
#              addresses. Unlocks /operator/* (fee collectors, default fees,
#              operator dashboard). In operator mode, deposit wallets must be
#              bound to a project AND a fee (bps + collector) must resolve
#              for the chain before wallets can be created.
# The role LOCKS once role-specific data exists (merchant: a project;
# operator: a fee collector).

SETUP_MODE_CACHED=""

# get_setup_mode is read via $(...) subshells, so it can only READ the cache;
# ensure_setup_mode (which runs in the parent shell) is what populates it.
# One GET per run instead of one per consumer (ensure_wallet, banner, ...).
get_setup_mode() {
	if [[ -n "$SETUP_MODE_CACHED" ]]; then
		echo "$SETUP_MODE_CACHED"
		return 0
	fi
	local res
	res=$(api GET "/api/v1/operator/setup-mode" "" true)
	parse_response "$res"
	if [[ "$HTTP_CODE" == "200" ]]; then
		echo "$HTTP_BODY" | grep -o '"setupMode":"[^"]*"' | cut -d'"' -f4 || true
	fi
}

ensure_setup_mode() {
	local desired="$1"
	local current
	current=$(get_setup_mode)
	if [[ "$current" == "$desired" ]]; then
		SETUP_MODE_CACHED="$desired"
		echo "Setup mode: $desired (already set)"
		return 0
	fi
	if [[ -n "$current" ]]; then
		SETUP_MODE_CACHED="$current"
		echo "Setup mode is '$current' and you asked for '$desired'."
		echo "The role locks once role data exists (merchant: a project; operator: a"
		echo "fee collector). To change it, reset the install (reset-local) or use the"
		echo "dashboard role screen while no role data has been saved."
		return 1
	fi
	local res
	res=$(api PUT "/api/v1/operator/setup-mode" "{\"setupMode\":\"$desired\"}" true)
	parse_response "$res"
	if [[ "$HTTP_CODE" == "200" ]]; then
		SETUP_MODE_CACHED="$desired"
		echo "Setup mode set: $desired"
		return 0
	fi
	log_api_error "Set setup mode" "$HTTP_CODE" "$HTTP_BODY"
	return 1
}

# Create a fee collector for one family unless one already exists in
# $4 (the pre-fetched collectors list). Result lands in COLLECTOR_ID
# (existing or freshly created) - global result, same convention as
# HTTP_BODY/HTTP_CODE, so messages can stay on stdout.
COLLECTOR_ID=""
ensure_fee_collector() {
	local fam_id="$1" addr="$2" name="$3" existing_body="$4"
	COLLECTOR_ID=$(echo "$existing_body" | json_find_id_by blockchainFamilyID "$fam_id")
	if [[ -n "$COLLECTOR_ID" ]]; then
		# Reuse the configured collector - but if the env var points at a
		# DIFFERENT address, say so loudly: fee destination is a money-flow
		# decision and must never change silently from either side.
		local existing_addr
		existing_addr=$(echo "$existing_body" | python3 -c "
import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('items') or d.get('data') or []
print(next((x.get('address','') for x in d if str(x.get('blockchainFamilyID'))=='$fam_id'),''))" 2>/dev/null || true)
		if [[ -n "$existing_addr" && "$existing_addr" != "$addr" ]]; then
			echo "WARNING: fee collector for family $fam_id (id $COLLECTOR_ID) is configured"
			echo "  with address $existing_addr, but the env var asks for $addr."
			echo "  Keeping the EXISTING one - change it in the dashboard (Setup -> Fee"
			echo "  collectors) if the env address is the intended destination."
		else
			echo "Fee collector for family $fam_id already exists (id $COLLECTOR_ID)."
		fi
		return 0
	fi
	local res
	res=$(api POST "/api/v1/operator/fee-collectors" "{\"blockchainFamilyID\":$fam_id,\"address\":\"$addr\",\"masterAddress\":\"$addr\",\"name\":\"$name\"}" true)
	parse_response "$res"
	if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
		log_api_error "Create fee collector ($name)" "$HTTP_CODE" "$HTTP_BODY"
		return 1
	fi
	COLLECTOR_ID=$(echo "$HTTP_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2 || true)
}

# Merchant API key: every server-to-server integration (and the PayRam MCP at
# mcp.payram.com) authenticates with a per-PROJECT API key. The dashboard can
# mint one, but agents shouldn't need a browser: reuse the project's active
# key, else create one via the API. Saved next to the other secrets.
ensure_api_key() {
	ensure_token || return 1
	load_tokens
	local project_id
	project_id=$(get_first_project_id) || return 1
	local res key=""
	res=$(api GET "/api/v1/external-platform/${project_id}/api-key" "" true)
	parse_response "$res"
	if [[ "$HTTP_CODE" == "200" ]] && command -v python3 >/dev/null 2>&1; then
		key=$(echo "$HTTP_BODY" | python3 -c "
import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('items') or d.get('data') or []
print(next((k['key'] for k in d if k.get('status')=='active' and k.get('key')),''))" 2>/dev/null || true)
	fi
	if [[ -z "$key" ]]; then
		res=$(api POST "/api/v1/external-platform/${project_id}/api-key" "{\"description\":\"Created by setup_payram_agents.sh\"}" true)
		parse_response "$res"
		if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
			log_api_error "Create API key" "$HTTP_CODE" "$HTTP_BODY"
			return 1
		fi
		key=$(echo "$HTTP_BODY" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
	fi
	if [[ -z "$key" ]]; then
		echo "Could not obtain an API key. Create one in the dashboard: Project -> API keys."
		return 1
	fi
	mkdir -p "$PAYRAM_INFO_DIR"
	{
		echo "PAYRAM_BASE_URL=\"$PAYRAM_API_URL\""
		echo "PAYRAM_API_KEY=\"$key\""
	} > "$API_KEY_FILE"
	chmod 600 "$API_KEY_FILE" 2>/dev/null || true
	echo "Merchant API key ready (project $project_id), saved to: $API_KEY_FILE"
	echo "This is what server-to-server integrations and the PayRam MCP use:"
	echo "  PAYRAM_BASE_URL=$PAYRAM_API_URL"
	# Never print the full key to stdout - it's a long-lived secret and stdout
	# routinely ends up in logs/transcripts. The 600 file has the real value.
	echo "  PAYRAM_API_KEY=${key:0:6}******** (full key in $API_KEY_FILE)"
	return 0
}

# Operator lane: ensure fee collectors (per family) + default fees (per
# chain) exist, driven by env. Without these the backend refuses wallet
# creation in operator mode - so this must run BEFORE ensure_wallet.
ensure_operator_config() {
	local btc_addr="${PAYRAM_OPERATOR_BTC_FEE_COLLECTOR:-}"
	local evm_addr="${PAYRAM_OPERATOR_EVM_FEE_COLLECTOR:-}"
	local fee_bps="${PAYRAM_OPERATOR_FEE_BPS:-100}"
	# Validate the fee before it reaches the API: integer basis points,
	# 1..1500 (15% cap, enforced on-chain too). Catch typos like "10%" here
	# with a clear message instead of a confusing backend error.
	if [[ ! "$fee_bps" =~ ^[0-9]+$ ]] || (( fee_bps < 1 || fee_bps > 1500 )); then
		echo "Invalid PAYRAM_OPERATOR_FEE_BPS='${fee_bps}'. Use an integer 1-1500"
		echo "(basis points: 100 = 1%, max 1500 = 15%)."
		return 1
	fi
	if [[ -z "$btc_addr" && -z "$evm_addr" ]]; then
		echo ""
		echo "=== Operator mode needs YOUR fee-collector addresses (ownership decision) ==="
		echo "Operator fees from merchant volume are paid to addresses you control."
		echo "Provide at least one and re-run:"
		echo "  PAYRAM_OPERATOR_BTC_FEE_COLLECTOR=<your BTC address>"
		echo "  PAYRAM_OPERATOR_EVM_FEE_COLLECTOR=<your 0x address>"
		echo "  PAYRAM_OPERATOR_FEE_BPS=$fee_bps   (fee in basis points, max 1500 = 15%)"
		echo "Or configure in the dashboard: Setup -> Fee collectors -> Default fees."
		echo "=============================================================================="
		return 1
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		echo "python3 is required to auto-configure operator fees (JSON parsing)."
		echo "Configure via the dashboard instead: Setup -> Fee collectors -> Default fees."
		return 1
	fi

	local res families
	res=$(api GET "/api/v1/blockchain-family" "" true)
	parse_response "$res"
	if [[ "$HTTP_CODE" != "200" ]]; then
		log_api_error "List blockchain families" "$HTTP_CODE" "$HTTP_BODY"
		return 1
	fi
	families="$HTTP_BODY"
	local btc_fam_id evm_fam_id
	btc_fam_id=$(echo "$families" | json_find_id_by family BTC_Family)
	evm_fam_id=$(echo "$families" | json_find_id_by family ETH_Family)

	# Existing collectors (idempotency): family id -> collector id
	res=$(api GET "/api/v1/operator/fee-collectors" "" true)
	parse_response "$res"
	local existing="$HTTP_BODY"

	local btc_cid="" evm_cid=""
	if [[ -n "$btc_addr" && -n "$btc_fam_id" ]]; then
		ensure_fee_collector "$btc_fam_id" "$btc_addr" "Operator BTC collector" "$existing" || return 1
		btc_cid="$COLLECTOR_ID"
	fi
	if [[ -n "$evm_addr" && -n "$evm_fam_id" ]]; then
		ensure_fee_collector "$evm_fam_id" "$evm_addr" "Operator EVM collector" "$existing" || return 1
		evm_cid="$COLLECTOR_ID"
	fi

	# Default fees for every active chain whose family has a collector.
	res=$(api GET "/api/v1/blockchains" "" true)
	parse_response "$res"
	if [[ "$HTTP_CODE" != "200" ]]; then
		log_api_error "List blockchains" "$HTTP_CODE" "$HTTP_BODY"
		return 1
	fi
	local defaults
	defaults=$(echo "$HTTP_BODY" | python3 -c "
import sys,json
btc,evm,bps=sys.argv[1],sys.argv[2],int(sys.argv[3])
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('items') or d.get('data') or []
cid_by_family={'BTC_Family':btc,'ETH_Family':evm}
out=[{'blockchainID':b['id'],'feeBps':bps,'feeCollectorID':int(cid)}
     for b in d for cid in [cid_by_family.get(b.get('family'),'')] if cid]
print(json.dumps({'defaults':out}) if out else '')" "$btc_cid" "$evm_cid" "$fee_bps" 2>/dev/null || true)
	if [[ -z "$defaults" ]]; then
		echo "No chains matched the provided collectors; set default fees in the dashboard."
		return 1
	fi
	res=$(api PUT "/api/v1/operator/fees/defaults" "$defaults" true)
	parse_response "$res"
	if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
		log_api_error "Set default operator fees" "$HTTP_CODE" "$HTTP_BODY"
		return 1
	fi
	echo "Operator configured: fee collectors + default fee ${fee_bps} bps across supported chains."
	return 0
}

# Print a troubleshooting card: likely causes ranked by probability given the
# symptoms we can actually observe (container state, config presence, TTY).
# Keeps every failure actionable instead of a bare error line.
troubleshoot() {
	local card="$1"
	echo ""
	echo "=== Troubleshooting: $card ==="
	case "$card" in
		api-unreachable)
			local container_up="no" config_found="no"
			is_payram_running && container_up="yes"
			[[ -n "${INSTALL_CONFIG_FILE:-}" ]] && config_found="yes"
			echo "API not responding at: $PAYRAM_API_URL"
			if [[ "$container_up" == "no" ]]; then
				echo "  [80%] PayRam container is not running."
				echo "        -> docker ps | grep payram   then: $0 --restart"
				echo "  [15%] PayRam was never installed on this host."
				echo "        -> run: $0 --testnet"
				echo "  [ 5%] Wrong API URL (port/scheme)."
				echo "        -> check: docker port payram   and set PAYRAM_API_URL"
			elif [[ "$config_found" == "no" ]]; then
				echo "  [60%] API URL guess is wrong (no installer config.env found to derive it)."
				echo "        -> check the real port: docker port payram   then set PAYRAM_API_URL"
				echo "  [30%] Container is still starting up."
				echo "        -> wait ~30s, watch: docker logs -f payram"
				echo "  [10%] Container is unhealthy."
				echo "        -> docker logs payram 2>&1 | tail -50"
			else
				echo "  [60%] Container is still starting up (API not bound yet)."
				echo "        -> wait ~30s, watch: docker logs -f payram"
				echo "  [30%] Container is unhealthy/crash-looping."
				echo "        -> docker logs payram 2>&1 | tail -50"
				echo "  [10%] SSL/port mismatch vs config.env (RETAINED_PORTS)."
				echo "        -> docker port payram   and compare with $PAYRAM_API_URL"
			fi
			;;
		install-interactive)
			echo "Fresh install needs a terminal: setup_payram.sh asks one-time DB/SSL/port"
			echo "questions. Everything AFTER the install is fully headless."
			echo "  [70%] You ran the one-step flow without a TTY before PayRam was installed."
			echo "        -> run once from a terminal: sudo ./setup_payram.sh --mainnet (or --testnet)"
			echo "           then re-run this agent flow (it attaches to the existing install)."
			echo "  [15%] The installer reported an error above (disk, docker, port busy) -"
			echo "        fix what it printed and re-run."
			echo "  [10%] Container exists but is stopped."
			echo "        -> $0 --restart"
			echo "  [ 5%] Docker missing / image pull failed (network)."
			echo "        -> docker version; docker logs payram 2>&1 | tail -20"
			;;
		auth-env)
			echo "Credentials are required but no terminal is available to prompt."
			echo "  [95%] PAYRAM_EMAIL / PAYRAM_PASSWORD not set in the environment."
			echo "        -> PAYRAM_EMAIL=you@example.com PAYRAM_PASSWORD=... $0 --testnet"
			echo "  [ 5%] You meant to run interactively."
			echo "        -> re-run from a terminal."
			;;
		auth-failed)
			echo "  [70%] Wrong email or password."
			echo "        -> retry; or reset the password via the dashboard."
			echo "  [20%] Root user exists but you used 'setup' (signup) instead of 'signin' (or vice versa)."
			echo "        -> $0 status   shows whether the root user exists."
			echo "  [10%] Backend error."
			echo "        -> docker logs payram 2>&1 | tail -50"
			;;
		gas)
			echo "Deployer wallet has insufficient ETH for gas (this is ops fuel, not savings)."
			echo "  [90%] The deployer address was not funded (or not enough)."
			if [[ "${PAYRAM_NETWORK:-testnet}" == "mainnet" && "${PAYRAM_SCW_CHAIN_DEFAULTED:-0}" == "1" ]]; then
				echo "        -> send ~\$10 of ETH to: ${PAYRAM_DEPLOYER_ADDRESS:-<deployer>}"
				echo "           Ethereum or Base network - both work, same address; we detect"
				echo "           where it lands. Pick Base if your wallet asks and you're unsure."
			else
				echo "        -> send ETH (any amount lets the deploy try; ~\$10 is comfortable)"
				echo "           to: ${PAYRAM_DEPLOYER_ADDRESS:-<deployer>}"
			fi
			if [[ "${PAYRAM_NETWORK:-testnet}" != "mainnet" ]]; then
				echo "        -> testnet faucets:"
				print_testnet_faucets | sed 's/^/      /'
			fi
			echo "  [10%] Funds sent on the wrong network."
			echo "        -> confirm you funded on ${PAYRAM_NETWORK:-testnet} (RPC: ${PAYRAM_ETH_RPC_URL:-default})"
			echo "  Re-running this command resumes the wait - nothing is lost."
			;;
		rpc)
			echo "  [60%] Public RPC endpoint is rate-limiting or down."
			echo "        -> retry in a minute, or set PAYRAM_ETH_RPC_URL to another endpoint"
			echo "  [30%] No internet access / firewall blocks outbound HTTPS."
			echo "        -> curl -sI ${PAYRAM_ETH_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
			echo "  [10%] Invalid custom RPC URL."
			echo "        -> echo \$PAYRAM_ETH_RPC_URL"
			;;
		deploy-failed)
			echo "  [50%] Gas ran out mid-deploy or RPC dropped the tx."
			echo "        -> check balance, then re-run: $0 deploy-scw-flow (it will not double-charge: a"
			echo "           successful deploy is recorded and only the link step is retried)"
			echo "  [30%] RPC endpoint failed during broadcast."
			echo "        -> set PAYRAM_ETH_RPC_URL to a different endpoint and re-run"
			echo "  [20%] See the deploy log for the actual error:"
			echo "        -> cat ${PAYRAM_INFO_DIR}/.deploy-scw.log"
			;;
		link-failed)
			echo "The SCW deployed on-chain, but linking it to your project failed."
			echo "DO NOT redeploy - the contract exists and is recorded in scw-state.env."
			echo "  [70%] Transient API error."
			echo "        -> re-run: $0 deploy-scw   (it resumes at the link step only)"
			echo "  [30%] Token expired mid-flow."
			echo "        -> $0 signin   then re-run: $0 deploy-scw"
			;;
		payment-link)
			echo "  [50%] No wallet linked to the project yet."
			echo "        -> $0 ensure-wallet   (or link one in the dashboard: Project -> Wallet)"
			echo "  [25%] Wallet link is still settling (it takes a few seconds after creation)."
			echo "        -> wait ~10s and re-run: $0 create-payment-link"
			echo "  [25%] Backend config missing (payram.frontend)."
			echo "        -> $0 ensure-config   then check: docker logs payram 2>&1 | tail -50"
			;;
	esac
	echo "==============================="
	echo ""
}

resolve_node_mode() {
	if [[ -n "$NODE_MODE_RESOLVED" ]]; then
		return 0
	fi
	local mode="${PAYRAM_NODE_MODE:-docker}"
	if [[ "$mode" == "docker" ]]; then
		if command -v docker >/dev/null 2>&1; then
			NODE_MODE_RESOLVED="docker"
			return 0
		fi
		if command -v node >/dev/null 2>&1; then
			echo "Docker not found; falling back to host Node.js."
			NODE_MODE_RESOLVED="host"
			return 0
		fi
		echo "Neither Docker nor Node.js is available."
		return 1
	fi

	if command -v node >/dev/null 2>&1; then
		NODE_MODE_RESOLVED="host"
		return 0
	fi
	if command -v docker >/dev/null 2>&1; then
		echo "Node.js not found; falling back to Docker Node runtime."
		NODE_MODE_RESOLVED="docker"
		return 0
	fi
	echo "Neither Node.js nor Docker is available."
	return 1
}

run_node() {
	local workdir="$1"
	shift
	resolve_node_mode || return 1
	if [[ "$NODE_MODE_RESOLVED" == "docker" ]]; then
		local uid gid
		uid=$(id -u)
		gid=$(id -g)
		local -a env_flags=()
		local api_override="${PAYRAM_API_URL:-}"
		if [[ -n "$api_override" ]] && [[ "$api_override" =~ localhost|127\.0\.0\.1 ]]; then
			api_override="${api_override/localhost/host.docker.internal}"
			api_override="${api_override/127.0.0.1/host.docker.internal}"
			env_flags+=("-e" "PAYRAM_API_URL=${api_override}")
		fi
		for var in PAYRAM_API_URL PAYRAM_ACCESS_TOKEN PAYRAM_MNEMONIC_FILE PAYRAM_ETH_RPC_URL PAYRAM_FUND_COLLECTOR PAYRAM_SCW_NAME PAYRAM_BLOCKCHAIN_CODE PAYRAM_MNEMONIC PAYRAM_DEPLOYER_ADDRESS PAYRAM_SCW_MIN_BALANCE_ETH PAYRAM_PROJECT_ID; do
			if [[ -n "${!var:-}" ]]; then
				if [[ "$var" != "PAYRAM_API_URL" || -z "$api_override" ]]; then
					env_flags+=("-e" "$var")
				fi
			fi
		done
		local -a mounts=("-v" "${workdir}:/work")
		if [[ -n "${PAYRAM_INFO_DIR:-}" && -d "${PAYRAM_INFO_DIR}" ]]; then
			mounts+=("-v" "${PAYRAM_INFO_DIR}:/payraminfo")
			if [[ -f "${PAYRAM_INFO_DIR}/headless-wallet-secret.txt" ]]; then
				env_flags+=("-e" "PAYRAM_MNEMONIC_FILE=/payraminfo/headless-wallet-secret.txt")
			fi
		fi
		docker run --rm -i -u "${uid}:${gid}" --add-host=host.docker.internal:host-gateway "${mounts[@]}" -w /work "${env_flags[@]}" \
			"$PAYRAM_NODE_DOCKER_IMAGE" node "$@"
	else
		(cd "$workdir" && node "$@")
	fi
}

run_npm_install() {
	local workdir="$1"
	resolve_node_mode || return 1
	if [[ "$NODE_MODE_RESOLVED" == "docker" ]]; then
		local uid gid
		uid=$(id -u)
		gid=$(id -g)
		docker run --rm -i -u "${uid}:${gid}" -v "${workdir}:/work" -w /work \
			"$PAYRAM_NODE_DOCKER_IMAGE" npm install --silent
	else
		if ! command -v npm >/dev/null 2>&1; then
			echo "npm is required to install wallet generator dependencies."
			return 1
		fi
		(cd "$workdir" && npm install --silent)
	fi
}

ensure_node_deps() {
	local workdir="$1"
	if [[ -d "$workdir/node_modules" ]]; then
		return 0
	fi
	if ! run_npm_install "$workdir"; then
		echo "Failed to install Node.js dependencies in $workdir"
		return 1
	fi
	if [[ ! -d "$workdir/node_modules" ]]; then
		echo "Node.js dependencies are missing after install in $workdir"
		return 1
	fi
	return 0
}

log_api_error() {
	local context="$1"
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
	if [[ "$context" == "Create payment link" ]]; then
		troubleshoot payment-link
	fi
	echo ""
	echo "To see backend error details, run:"
	echo "  docker logs payram 2>&1 | tail -80"
	echo ""
}

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
	# CUSTOMER_ID/MEMBER_EMAIL were loaded from the file above; save_tokens
	# re-persists them so a refresh doesn't drop them.
	save_tokens
	return 0
}

ensure_token() {
	load_tokens
	if [[ -n "${ACCESS_TOKEN:-}" ]]; then
		# Version-spanning auth probe (details on current core, /all on older
		# images) - a 404 here must never be mistaken for "not signed in".
		api_list_projects
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
		echo "API: unreachable"
		troubleshoot api-unreachable
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

# Zero-input credentials: when PAYRAM_EMAIL/PAYRAM_PASSWORD are not provided,
# generate them (random password, local default email) and persist 600 next to
# the auth tokens - both are changeable from the dashboard later, so this is
# config-pushed-to-the-end, not a security downgrade. Later runs (signin)
# re-read the same file, so nothing has to be remembered or exported.
load_or_create_root_credentials() {
	if [[ -n "${PAYRAM_EMAIL:-}" && -n "${PAYRAM_PASSWORD:-}" ]]; then
		return 0
	fi
	if [[ -n "$CREDENTIALS_FILE" && -f "$CREDENTIALS_FILE" ]]; then
		# shellcheck source=/dev/null
		source "$CREDENTIALS_FILE"
		export PAYRAM_EMAIL PAYRAM_PASSWORD
		[[ -n "${PAYRAM_EMAIL:-}" && -n "${PAYRAM_PASSWORD:-}" ]] && return 0
	fi
	export PAYRAM_EMAIL="${PAYRAM_EMAIL:-admin@payram.local}"
	if [[ -z "${PAYRAM_PASSWORD:-}" ]]; then
		if command -v openssl >/dev/null 2>&1; then
			PAYRAM_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)"
		else
			PAYRAM_PASSWORD="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-16)"
		fi
		export PAYRAM_PASSWORD
	fi
	if [[ -n "$CREDENTIALS_FILE" ]]; then
		mkdir -p "$(dirname "$CREDENTIALS_FILE")"
		printf 'PAYRAM_EMAIL="%s"\nPAYRAM_PASSWORD="%s"\n' "$PAYRAM_EMAIL" "$PAYRAM_PASSWORD" > "$CREDENTIALS_FILE"
		chmod 600 "$CREDENTIALS_FILE"
	fi
	echo "Root credentials auto-created (change anytime in the dashboard):"
	echo "  email: $PAYRAM_EMAIL"
	echo "  saved to: ${CREDENTIALS_FILE:-<not persisted>} (password inside, mode 600)"
}

cmd_setup() {
	local res body code
	res=$(curl -s -w "\n%{http_code}" "${PAYRAM_API_URL}/api/v1/member/root/exist")
	body=$(echo "$res" | sed '$d')
	code=$(echo "$res" | tail -1)
	if [[ "$code" != "200" ]]; then
		echo "API unreachable (HTTP $code)."
		troubleshoot api-unreachable
		return 1
	fi
	if echo "$body" | grep -q '"exist":true'; then
		echo "Root user already exists. Use 'signin' then 'create-payment-link'."
		return 0
	fi
	load_or_create_root_credentials
	local email="$PAYRAM_EMAIL"
	local password="$PAYRAM_PASSWORD"
	res=$(curl -s -w "\n%{http_code}" -X POST "${PAYRAM_API_URL}/api/v1/signup" \
		-H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$password\"}")
	body=$(echo "$res" | sed '$d')
	code=$(echo "$res" | tail -1)
	if [[ "$code" != "200" && "$code" != "201" ]]; then
		echo "Signup failed (HTTP $code): $body"
		troubleshoot auth-failed
		return 1
	fi
	parse_auth_tokens "$body"
	save_tokens
	echo "Signed in as $email"

	# Pick the role BEFORE creating a project - the first project locks the
	# install into merchant mode. Default is merchant; operator must be asked
	# for explicitly (PAYRAM_SETUP_MODE=operator or --operator).
	# The FIRST project locks the install's role - so an operator request
	# must not silently fall through to (merchant-locking) project creation
	# when the setup-mode call fails. Merchant is the backend default, so a
	# failed call is harmless in that case.
	if ! ensure_setup_mode "${PAYRAM_SETUP_MODE:-merchant}"; then
		if [[ "${PAYRAM_SETUP_MODE:-merchant}" == "operator" ]]; then
			echo "Could not set operator mode - stopping BEFORE the first project is created"
			echo "(creating it would lock this install into merchant mode). Fix the error"
			echo "above and re-run; setup is resumable."
			return 1
		fi
	fi

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
	# Auto-created credentials from a previous setup run live next to the
	# tokens - re-use them so signin needs no env vars either.
	if [[ ( -z "$email" || -z "$password" ) && -n "$CREDENTIALS_FILE" && -f "$CREDENTIALS_FILE" ]]; then
		# shellcheck source=/dev/null
		source "$CREDENTIALS_FILE"
		email="${email:-${PAYRAM_EMAIL:-}}"
		password="${password:-${PAYRAM_PASSWORD:-}}"
	fi
	if [[ ( -z "$email" || -z "$password" ) && ! -t 0 ]]; then
		troubleshoot auth-env
		return 1
	fi
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
		troubleshoot auth-failed
		return 1
	fi
	parse_auth_tokens "$HTTP_BODY"
	save_tokens
	echo "Signed in."
}

ensure_config() {
	ensure_token || return 1
	local base_url="${PAYRAM_API_URL}"
	local frontend_url="${PAYRAM_FRONTEND_URL:-http://localhost}"
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

ensure_eth_mnemonic() {
	local script_dir="$SCRIPT_DIR/scripts"
	local secret_file="${PAYRAM_INFO_DIR}/headless-wallet-secret.txt"
	if [[ -s "$secret_file" ]]; then
		return 0
	fi
	if [[ ! -f "$script_dir/generate-deposit-wallet-eth.js" ]]; then
		echo "Missing $script_dir/generate-deposit-wallet-eth.js"
		return 1
	fi
	if [[ ! -f "$script_dir/package.json" ]]; then
		echo "Missing $script_dir/package.json. Cannot generate wallet."
		return 1
	fi
	ensure_node_deps "$script_dir" || return 1
	local gen mnemonic
	if ! gen=$(run_node "$script_dir" generate-deposit-wallet-eth.js 2>&1); then
		echo "Failed to generate ETH wallet mnemonic."
		echo "$gen"
		return 1
	fi
	# One-line JSON output; grep/cut beats a second node/docker spawn.
	mnemonic=$(echo "$gen" | grep -o '"mnemonic":"[^"]*"' | cut -d'"' -f4 || true)
	if [[ -z "$mnemonic" ]]; then
		echo "Failed to parse generated ETH mnemonic."
		return 1
	fi
	mkdir -p "$PAYRAM_INFO_DIR"
	echo "$mnemonic" > "$secret_file"
	chmod 600 "$secret_file" 2>/dev/null || true
	return 0
}

get_eth_deployer_address() {
	local script_dir="$SCRIPT_DIR/scripts"
	local secret_file="${PAYRAM_INFO_DIR}/headless-wallet-secret.txt"
	if [[ ! -f "$secret_file" ]]; then
		echo ""
		return 1
	fi
	ensure_node_deps "$script_dir" || return 1
	local addr
	addr=$(PAYRAM_MNEMONIC_FILE="$secret_file" run_node "$script_dir" -e "
		const fs = require('fs');
		const { ethers } = require('ethers');
		const file = process.env.PAYRAM_MNEMONIC_FILE;
		const mnemonic = fs.readFileSync(file, 'utf8').trim().split('\n')[0].trim();
		const wallet = ethers.Wallet.fromPhrase(mnemonic);
		console.log(wallet.address);
	" 2>&1)
	if [[ -z "$addr" ]]; then
		echo ""
		return 1
	fi
	echo "$addr"
}

# Watch the SAME deployer address on Base AND Ethereum mainnet at once.
# Humans often don't know which network their wallet/exchange will use - so we
# accept either and deploy on whichever chain the funds land. Per-chain
# minimums reflect real gas costs (Base is ~100x cheaper than Ethereum L1).
# Output: line1 OK|WAIT, line2 winning chain (or '-'), line3 balances summary.
check_eth_balance_any() {
	local script_dir="$SCRIPT_DIR/scripts"
	ensure_node_deps "$script_dir" || return 1
	PAYRAM_SCW_MIN_BASE="${PAYRAM_SCW_MIN_BALANCE_ETH:-${PAYRAM_SCW_MIN_BASE:-0}}" \
	PAYRAM_SCW_MIN_ETHL1="${PAYRAM_SCW_MIN_BALANCE_ETH:-${PAYRAM_SCW_MIN_ETHL1:-0}}" \
	run_node "$script_dir" -e "
		const { ethers } = require('ethers');
		const addr = process.env.PAYRAM_DEPLOYER_ADDRESS;
		const watch = [
			['BASE', 'https://base-rpc.publicnode.com', process.env.PAYRAM_SCW_MIN_BASE],
			['ETH', 'https://ethereum-rpc.publicnode.com', process.env.PAYRAM_SCW_MIN_ETHL1],
		];
		(async () => {
			let summary = [], winner = '', anyOk = false, allFailed = true;
			for (const [chain, rpc, min] of watch) {
				try {
					const bal = await new ethers.JsonRpcProvider(rpc).getBalance(addr);
					allFailed = false;
					summary.push(chain.toLowerCase() + '=' + ethers.formatEther(bal));
					const ok = min === '0' ? bal > 0n : bal >= ethers.parseEther(min);
					if (!anyOk && ok) { anyOk = true; winner = chain; }
				} catch (e) { summary.push(chain.toLowerCase() + '=?'); }
			}
			if (allFailed) process.exit(1);
			console.log(anyOk ? 'OK' : 'WAIT');
			console.log(winner || '-');
			console.log(summary.join(' '));
		})().catch(() => process.exit(1));
	" 2>/dev/null
}

check_eth_balance() {
	local script_dir="$SCRIPT_DIR/scripts"
	ensure_node_deps "$script_dir" || return 1
	# Any balance > 0 is a green light: we don't gate on a guessed gas number -
	# the deploy simply tries, and an out-of-gas failure is resumable. Setting
	# PAYRAM_SCW_MIN_BALANCE_ETH explicitly restores a hard threshold.
	PAYRAM_SCW_MIN_BALANCE_ETH="${PAYRAM_SCW_MIN_BALANCE_ETH:-0}" run_node "$script_dir" -e "
		const { ethers } = require('ethers');
		const rpc = process.env.PAYRAM_ETH_RPC_URL;
		const addr = process.env.PAYRAM_DEPLOYER_ADDRESS;
		const min = process.env.PAYRAM_SCW_MIN_BALANCE_ETH || '0';
		const provider = new ethers.JsonRpcProvider(rpc);
		(async () => {
			const bal = await provider.getBalance(addr);
			const ok = min === '0' ? bal > 0n : bal >= ethers.parseEther(min);
			console.log(ok ? 'OK' : 'WAIT');
			console.log(ethers.formatEther(bal));
		})().catch(() => process.exit(1));
	" 2>/dev/null
}

ensure_wallet() {
	ensure_token || return 1
	load_tokens
	local project_id res
	project_id=$(get_first_project_id) || return 1

	res=$(api GET "/api/v1/project/${project_id}/wallet" "" true)
	parse_response "$res"
	if [[ "$HTTP_CODE" != "200" ]]; then
		echo "Failed to list project wallet (HTTP $HTTP_CODE): $HTTP_BODY"
		return 1
	fi
	if echo "$HTTP_BODY" | grep -q '"walletID"'; then
		echo "Project already has a wallet linked."
		return 0
	fi

	if [[ -z "${PAYRAM_WALLET_QUIET:-}" ]]; then
		echo ""
		echo "This project has no wallet linked. Payment links need a deposit wallet so"
		echo "customers get unique deposit addresses. The API uses XPUB only (no private key sent)."
		echo ""
		echo "  (1) I create a starter BTC deposit wallet now (~10s, xpub-based, no gas)"
		echo "  (2) Link an existing wallet you already created"
		echo "  (3) Skip (link later via dashboard or API)"
		echo ""
		echo "Note: BTC payments work immediately. USDC/EVM payments need the smart-contract"
		echo "wallet step (deploy-scw, needs gas) - offered right after your first link."
		echo "Whatever you pick, you can add or replace wallets later in the dashboard."
		echo ""
	fi
	local choice
	if [[ -n "${PAYRAM_WALLET_CHOICE:-}" ]]; then
		choice="$PAYRAM_WALLET_CHOICE"
		[[ -z "${PAYRAM_WALLET_QUIET:-}" ]] && echo "Choice [1]: $choice"
	elif [[ ! -t 0 ]]; then
		# Headless with no explicit choice: take the reversible default and say so.
		choice="1"
		echo "No TTY - defaulting to (1) create a starter wallet (changeable later)."
	else
		read -p "Choice [1]: " choice
		choice="${choice:-1}"
	fi

	if [[ "$choice" == "3" ]]; then
		echo "Skipped. Run '$0 ensure-wallet' later or link a wallet in the dashboard."
		return 0
	fi

	if [[ "$choice" == "1" ]]; then
		resolve_node_mode || return 1
		local gen script_dir
		script_dir="$SCRIPT_DIR"
		if [[ ! -f "$script_dir/scripts/package.json" ]]; then
			echo "Missing scripts/package.json. Cannot generate wallet."
			return 1
		fi
		ensure_node_deps "$script_dir/scripts" || return 1
		if ! gen=$(run_node "$script_dir/scripts" generate-deposit-wallet.js 2>&1); then
			echo "Failed to generate wallet."
			echo "$gen"
			return 1
		fi
		# The generator prints one-line JSON; grep/cut it directly instead of
		# spawning a second node (= a second docker run) just to parse it.
		local mnemonic xpub
		mnemonic=$(echo "$gen" | grep -o '"mnemonic":"[^"]*"' | cut -d'"' -f4 || true)
		xpub=$(echo "$gen" | grep -o '"xpub":"[^"]*"' | cut -d'"' -f4 || true)
		if [[ -z "$xpub" || -z "$mnemonic" ]]; then
			echo "Failed to parse generated wallet."
			return 1
		fi
		mkdir -p "$PAYRAM_INFO_DIR"
		local secret_file="${PAYRAM_INFO_DIR}/headless-wallet-secret.txt"
		echo "$mnemonic" > "$secret_file"
		chmod 600 "$secret_file" 2>/dev/null || true
		# XPUB deposit wallets are BTC-only by design: payram-core derives EVM
		# deposit addresses from the fund-sweeper CONTRACT (CREATE2), never from
		# an xpub - registering an ETH_Family xpub would create a wallet whose
		# address generation fails at payment time. USDC/EVM comes from the
		# deploy-scw step.
		#
		# Operator mode: the backend requires the wallet to be bound to a
		# project at creation AND an operator fee (bps + collector) to resolve
		# for BTC - run ensure_operator_config first if creation fails.
		local payload proj_frag=""
		[[ "$(get_setup_mode)" == "operator" ]] && proj_frag="\"projectID\":$project_id,"
		payload="{\"name\":\"Headless\",${proj_frag}\"xpubs\":[{\"family\":\"BTC_Family\",\"xpub\":\"$xpub\"}]}"
		res=$(api POST "/api/v1/wallets/deposit/eoa/bulk" "$payload" true)
		parse_response "$res"
		if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
			log_api_error "Create wallet" "$HTTP_CODE" "$HTTP_BODY" "POST" "${PAYRAM_API_URL}/api/v1/wallets/deposit/eoa/bulk" "$payload"
			return 1
		fi
		echo "Wallet created; backend is linking it to your project..."
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
		echo "This is a starter wallet - you can add more wallets or replace it anytime in the dashboard."
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
		parsed=$(echo "$HTTP_BODY" | run_node "$SCRIPT_DIR/scripts" -e "
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

# Link a deployed SCW wallet to the first project. Used both right after a
# deploy and to RESUME a deploy whose link step failed (scw-state.env).
link_scw_to_project() {
	local wallet_id="$1"
	local family="$2"
	# Optional: caller may pass an already-resolved project id to avoid
	# re-fetching the project list it just queried.
	local project_id="${3:-}"
	local res
	if [[ -z "$project_id" ]]; then
		if ! project_id=$(get_first_project_id); then
			troubleshoot link-failed
			return 1
		fi
	fi
	local payload="{\"wallets\":[{\"walletID\":$wallet_id,\"blockchainFamily\":\"$family\"}]}"
	res=$(api POST "/api/v1/project/${project_id}/wallet" "$payload" true)
	parse_response "$res"
	if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
		echo "SCW_LINKED=1" >> "$SCW_STATE_FILE"
		echo "SCW wallet linked to project. You can create payment links (no extra setup)."
		return 0
	fi
	echo "Deploy succeeded but linking to project failed (HTTP $HTTP_CODE)."
	troubleshoot link-failed
	return 1
}

cmd_deploy_scw() {
	echo "deploy-scw: checking token..."
	ensure_token || { echo "Sign in first: $0 signin"; return 1; }
	load_tokens
	if [[ -z "${ACCESS_TOKEN:-}" ]]; then
		echo "No token. Run: $0 signin"
		return 1
	fi
	echo "deploy-scw: token OK."

	# Resume: a previous run deployed on-chain but failed to link. Retry the
	# LINK ONLY - never redeploy (that would spend gas on a second contract).
	if [[ -f "$SCW_STATE_FILE" ]] && ! grep -q '^SCW_LINKED=1' "$SCW_STATE_FILE" 2>/dev/null; then
		local prev_id prev_family
		prev_id=$(grep '^SCW_WALLET_ID=' "$SCW_STATE_FILE" 2>/dev/null | cut -d= -f2- || true)
		prev_family=$(grep '^SCW_FAMILY=' "$SCW_STATE_FILE" 2>/dev/null | cut -d= -f2- || true)
		if [[ -n "$prev_id" ]]; then
			echo "Found a deployed-but-unlinked SCW (wallet $prev_id). Resuming the link step only..."
			link_scw_to_project "$prev_id" "${prev_family:-ETH_Family}"
			return $?
		fi
	fi

	# Idempotency: an EVM wallet already linked to the project means a re-run
	# should NOT deploy (and pay gas for) another contract. Applied when the
	# target chain is the legacy ETH default OR was defaulted by the one-step
	# flow (PAYRAM_SCW_CHAIN_DEFAULTED=1) - an EXPLICITLY chosen chain is an
	# "add another chain" intent and always deploys. Tolerant by design: if
	# the lookup fails we proceed to deploy rather than block.
	local known_project_id=""
	if [[ -z "${PAYRAM_FORCE_DEPLOY:-}" ]] && { [[ "${PAYRAM_BLOCKCHAIN_CODE:-ETH}" == "ETH" ]] || [[ "${PAYRAM_SCW_CHAIN_DEFAULTED:-0}" == "1" ]]; }; then
		local res
		known_project_id=$(get_first_project_id 2>/dev/null || true)
		if [[ -n "$known_project_id" ]]; then
			res=$(api GET "/api/v1/project/${known_project_id}/wallet" "" true)
			parse_response "$res"
			if [[ "$HTTP_CODE" == "200" ]] && echo "$HTTP_BODY" | grep -q 'ETH_Family'; then
				echo "An EVM (ETH_Family) wallet is already linked to this project - skipping deploy."
				echo "Re-running will not spend gas again."
				echo "  - Deploy on ANOTHER chain:  PAYRAM_BLOCKCHAIN_CODE=ETH $0 deploy-scw   (POLYGON likewise)"
				echo "  - Add BTC payments:  $0 ensure-wallet"
				echo "  - Deploy another SCW anyway:  PAYRAM_FORCE_DEPLOY=1 $0 deploy-scw"
				return 0
			fi
		fi
	fi

	# GATE (mainnet only): deploying spends REAL gas and the fund collector is
	# the cold wallet where swept customer funds land - that address must be a
	# deliberate human decision, never a silent default.
	if [[ "${PAYRAM_NETWORK:-}" == "mainnet" ]]; then
		if [[ -z "${PAYRAM_FUND_COLLECTOR:-}" ]] || [[ ! "$PAYRAM_FUND_COLLECTOR" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
			echo ""
			echo "MAINNET deploy requires PAYRAM_FUND_COLLECTOR - your COLD WALLET address"
			echo "(where swept customer funds land; keys never on this server)."
			if [[ -t 0 ]]; then
				read -r -p "Cold wallet 0x address: " fc
				fc=$(echo "$fc" | tr -d ' ')
				if [[ "$fc" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
					export PAYRAM_FUND_COLLECTOR="$fc"
				else
					echo "Invalid address. Aborting mainnet deploy."
					return 1
				fi
			else
				echo "Set PAYRAM_FUND_COLLECTOR=0x... and re-run."
				return 1
			fi
		fi
		if [[ -z "${PAYRAM_ACCEPT_MAINNET_COSTS:-}" ]]; then
			if [[ -t 0 ]]; then
				echo ""
				echo "This deploys a contract on Ethereum MAINNET and spends real ETH for gas."
				read -r -p "Type 'deploy' to continue: " confirm
				if [[ "$confirm" != "deploy" ]]; then
					echo "Cancelled. (Tip: try the same flow on testnet first - it's free.)"
					return 1
				fi
			else
				echo "Mainnet deploy spends real ETH. Set PAYRAM_ACCEPT_MAINNET_COSTS=1 to confirm non-interactively."
				return 1
			fi
		fi
	fi

	local script_path="${SCRIPT_DIR}/scripts/deploy-scw-eth.js"
	if [[ ! -f "$script_path" ]]; then
		echo "Missing $script_path"
		return 1
	fi
	resolve_node_mode || return 1
	echo "deploy-scw: installing deps if needed..."
	ensure_node_deps "$SCRIPT_DIR/scripts" || return 1
	export PAYRAM_API_URL
	export PAYRAM_ACCESS_TOKEN="$ACCESS_TOKEN"
	export PAYRAM_MNEMONIC_FILE="${PAYRAM_INFO_DIR}/headless-wallet-secret.txt"
	# Current core registers the SCW under the project; older images use the
	# legacy unscoped route. Pass the project id so the deploy script can try
	# the project-scoped path first (it falls back on 404). Best-effort.
	if [[ -z "${PAYRAM_PROJECT_ID:-}" ]]; then
		PAYRAM_PROJECT_ID="$(get_first_project_id 2>/dev/null || true)"
	fi
	[[ -n "${PAYRAM_PROJECT_ID:-}" ]] && export PAYRAM_PROJECT_ID
	[[ -n "${PAYRAM_ETH_RPC_URL:-}" ]] && export PAYRAM_ETH_RPC_URL
	if [[ -n "${PAYRAM_FUND_COLLECTOR:-}" ]] && [[ "$PAYRAM_FUND_COLLECTOR" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
		export PAYRAM_FUND_COLLECTOR
	else
		PAYRAM_FUND_COLLECTOR=""
	fi
	[[ -n "${PAYRAM_SCW_NAME:-}" ]] && export PAYRAM_SCW_NAME
	[[ -n "${PAYRAM_BLOCKCHAIN_CODE:-}" ]] && export PAYRAM_BLOCKCHAIN_CODE
	if { [[ -z "${PAYRAM_ETH_RPC_URL:-}" ]] || [[ "$PAYRAM_ETH_RPC_URL" =~ YOUR_ACTUAL|YOUR_KEY ]]; } && [[ -t 0 ]]; then
		echo ""
		echo "PAYRAM_ETH_RPC_URL (optional; default = PublicNode Sepolia, no key). Press Enter for default:"
		read -r rpc
		if [[ -n "$rpc" ]] && [[ ! "$rpc" =~ YOUR_ACTUAL|YOUR_KEY ]]; then
			export PAYRAM_ETH_RPC_URL="$rpc"
		fi
	fi
	if [[ -z "${PAYRAM_FUND_COLLECTOR:-}" && -t 0 ]]; then
		echo ""
		echo "PAYRAM_FUND_COLLECTOR (cold wallet 0x address, or press Enter to use deployer address):"
		echo "(Testnet only - you can change the fund collector before going live.)"
		read -r fc
		fc=$(echo "$fc" | tr -d ' ')
		if [[ -n "$fc" ]] && [[ "$fc" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
			export PAYRAM_FUND_COLLECTOR="$fc"
		fi
	fi
	echo "Deploying ETH SCW (mnemonic from $PAYRAM_MNEMONIC_FILE or PAYRAM_MNEMONIC)..."
	local deploy_log
	deploy_log="${PAYRAM_INFO_DIR}/.deploy-scw.log"
	mkdir -p "$PAYRAM_INFO_DIR"
	run_node "$SCRIPT_DIR/scripts" "deploy-scw-eth.js" 2>&1 | tee "$deploy_log"
	local node_exit=${PIPESTATUS[0]:-1}
	local deploy_out
	deploy_out=$(cat "$deploy_log" 2>/dev/null)
	local wallet_id family
	wallet_id=$(echo "$deploy_out" | grep '^PAYRAM_WALLET_ID=' | cut -d= -f2-)
	family=$(echo "$deploy_out" | grep '^PAYRAM_WALLET_FAMILY=' | cut -d= -f2-)
	[[ -z "$family" ]] && family="ETH_Family"
	if [[ $node_exit -ne 0 ]]; then
		echo ""
		echo "deploy-scw failed (exit $node_exit)."
		troubleshoot deploy-failed
		return 1
	fi
	if [[ -n "$wallet_id" ]]; then
		# Persist BEFORE linking so a link failure is resumable without redeploy.
		{
			echo "SCW_WALLET_ID=$wallet_id"
			echo "SCW_FAMILY=$family"
		} > "$SCW_STATE_FILE"
		chmod 600 "$SCW_STATE_FILE" 2>/dev/null || true
		echo ""
		echo "Linking SCW wallet to current project..."
		link_scw_to_project "$wallet_id" "$family" "$known_project_id"
		return $?
	fi
}

cmd_deploy_scw_flow() {
	echo "deploy-scw-flow: preparing mnemonic and funding wallet..."
	ensure_token || { echo "Sign in first: $0 signin"; return 1; }
	ensure_eth_mnemonic || return 1

	# Fund-on-either-chain: when WE defaulted the chain (one-step mainnet flow,
	# no explicit RPC), the human can send ETH to the deployer address on Base
	# OR Ethereum - same address on both - and we deploy where the funds land.
	local user_rpc_set="${PAYRAM_ETH_RPC_URL:+1}"
	local dual_watch=""
	if [[ "${PAYRAM_NETWORK:-}" == "mainnet" && "${PAYRAM_SCW_CHAIN_DEFAULTED:-0}" == "1" && -z "$user_rpc_set" ]]; then
		dual_watch="1"
	fi

	if [[ -z "${PAYRAM_ETH_RPC_URL:-}" ]]; then
		local chain="${PAYRAM_BLOCKCHAIN_CODE:-ETH}"
		if [[ "${PAYRAM_NETWORK:-}" == "mainnet" ]]; then
			case "$chain" in
				ETH)     PAYRAM_ETH_RPC_URL="https://ethereum-rpc.publicnode.com" ;;
				BASE)    PAYRAM_ETH_RPC_URL="https://base-rpc.publicnode.com" ;;
				POLYGON) PAYRAM_ETH_RPC_URL="https://polygon-bor-rpc.publicnode.com" ;;
				*)
					echo "No default RPC for chain '$chain' - set PAYRAM_ETH_RPC_URL explicitly."
					return 1
					;;
			esac
		else
			case "$chain" in
				ETH)     PAYRAM_ETH_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com" ;;
				BASE)    PAYRAM_ETH_RPC_URL="https://base-sepolia-rpc.publicnode.com" ;;
				POLYGON) PAYRAM_ETH_RPC_URL="https://polygon-amoy-bor-rpc.publicnode.com" ;;
				*)
					echo "No default testnet RPC for chain '$chain' - set PAYRAM_ETH_RPC_URL to that chain's testnet RPC."
					return 1
					;;
			esac
		fi
		export PAYRAM_ETH_RPC_URL
	fi

	local deployer
	deployer=$(get_eth_deployer_address)
	if [[ -z "$deployer" ]]; then
		echo "Failed to derive deployer address from mnemonic."
		return 1
	fi
	export PAYRAM_DEPLOYER_ADDRESS="$deployer"

	# No threshold gating by default: any balance > 0 lets the deploy try
	# (out-of-gas just fails and resumes). PAYRAM_SCW_MIN_BALANCE_ETH, when
	# explicitly set, restores a hard gate in both checkers.

	local attempts=0
	local max_attempts="${PAYRAM_SCW_FUND_MAX_ATTEMPTS:-60}"

	if [[ -n "$dual_watch" ]]; then
		# Human-simple funding: one address, either network, auto-detected.
		echo ""
		echo "--- One step needs you: add a little ETH (this pays the network fees) ---"
		echo ""
		echo "Send about \$10 worth of ETH to this address:"
		echo ""
		echo "  $deployer"
		echo ""
		echo "  - Ethereum network or Base network - BOTH work, it's the same address."
		echo "    (If your wallet or exchange asks which network, pick 'Base' when unsure.)"
		echo "  - I'll detect where the funds land and continue automatically."
		echo "  - This is resumable - re-running continues the wait."
		echo "--------------------------------------------------------------------------"
		while true; do
			local status chain balances res
			res=$(check_eth_balance_any)
			if [[ -z "$res" ]]; then
				echo "Failed to check balances via RPC."
				troubleshoot rpc
				return 1
			fi
			status=$(echo "$res" | sed -n 1p)
			chain=$(echo "$res" | sed -n 2p)
			balances=$(echo "$res" | sed -n 3p)
			if [[ "$status" == "OK" ]]; then
				echo "Funds detected on ${chain} (${balances}) - deploying there."
				if [[ "$chain" != "${PAYRAM_BLOCKCHAIN_CODE:-}" ]]; then
					export PAYRAM_BLOCKCHAIN_CODE="$chain"
					case "$chain" in
						ETH)  PAYRAM_ETH_RPC_URL="https://ethereum-rpc.publicnode.com" ;;
						BASE) PAYRAM_ETH_RPC_URL="https://base-rpc.publicnode.com" ;;
					esac
					export PAYRAM_ETH_RPC_URL
				fi
				break
			fi
			attempts=$((attempts + 1))
			if [[ -n "${PAYRAM_SCW_SKIP_BALANCE_CHECK:-}" ]]; then
				echo "Balance check skipped by PAYRAM_SCW_SKIP_BALANCE_CHECK."
				break
			fi
			if [[ ! -t 0 && $attempts -ge $max_attempts ]]; then
				echo "Funds not detected after ${max_attempts} checks (~15 min). Current: ${balances}"
				troubleshoot gas
				return 1
			fi
			echo "Waiting for funds... (${balances}) - checking again in 15s"
			sleep 15
		done
	else
		echo ""
		echo "--- Gas refill needed (ops fuel for the deploy + future sweeps, not savings) ---"
		if [[ -n "${PAYRAM_SCW_MIN_BALANCE_ETH:-}" && "${PAYRAM_SCW_MIN_BALANCE_ETH}" != "0" ]]; then
			echo "Send >= ${PAYRAM_SCW_MIN_BALANCE_ETH} ETH to the deployer address:"
		else
			echo "Send ETH for gas to the deployer address (any amount lets the deploy try;"
			echo "~\$10 worth is comfortably enough - too little just fails and resumes):"
		fi
		echo ""
		echo "  $deployer"
		echo ""
		echo "Network: ${PAYRAM_NETWORK:-testnet}   RPC: $PAYRAM_ETH_RPC_URL"
		if [[ "${PAYRAM_NETWORK:-testnet}" != "mainnet" ]]; then
			echo "Testnet ETH is free - faucets:"
			print_testnet_faucets
		fi
		echo "I'll keep checking the balance; this step is resumable - re-running continues the wait."
		echo "--------------------------------------------------------------------------------"

		while true; do
			local status balance res
			res=$(check_eth_balance)
			status=$(echo "$res" | head -1)
			balance=$(echo "$res" | tail -1)
			if [[ -z "$status" ]]; then
				echo "Failed to check balance via RPC."
				troubleshoot rpc
				return 1
			fi
			if [[ "$status" == "OK" ]]; then
				echo "Balance confirmed: ${balance} ETH"
				break
			fi
			attempts=$((attempts + 1))
			if [[ -n "${PAYRAM_SCW_SKIP_BALANCE_CHECK:-}" ]]; then
				echo "Balance check skipped by PAYRAM_SCW_SKIP_BALANCE_CHECK."
				break
			fi
			if [[ -t 0 ]]; then
				if [[ -n "${PAYRAM_SCW_MIN_BALANCE_ETH:-}" && "${PAYRAM_SCW_MIN_BALANCE_ETH}" != "0" ]]; then
					echo "Balance ${balance} ETH is below ${PAYRAM_SCW_MIN_BALANCE_ETH}. Add funds and press Enter to recheck."
				else
					echo "No funds detected yet (balance ${balance} ETH). Add ETH and press Enter to recheck."
				fi
				read -r _
			else
				if [[ $attempts -ge $max_attempts ]]; then
					echo "Balance not confirmed after ${max_attempts} checks (~10 min)."
					troubleshoot gas
					return 1
				fi
				sleep 10
			fi
		done
	fi

	cmd_deploy_scw
}

cmd_create_payment_link() {
	ensure_token || return 1
	ensure_config || true
	local project_id="${1:-}"
	local customer_email="${2:-}"
	local amount_usd="${3:-}"
	if [[ -z "$project_id" ]]; then
		project_id=$(get_first_project_id) || return 1
	fi
	load_tokens
	if [[ -z "$customer_email" ]]; then
		customer_email="${PAYRAM_PAYMENT_EMAIL:-${MEMBER_EMAIL:-}}"
		[[ -z "$customer_email" && -t 0 ]] && read -p "Customer email: " customer_email
		[[ -n "$MEMBER_EMAIL" && -z "$customer_email" ]] && customer_email="$MEMBER_EMAIL"
	fi
	if [[ -z "$amount_usd" ]]; then
		amount_usd="${PAYRAM_PAYMENT_AMOUNT:-10}"
		if [[ -t 0 ]]; then
			read -p "Generate a test payment link, Amount (USD) [$amount_usd]: " amount_in
			[[ -n "$amount_in" ]] && amount_usd="$amount_in"
		fi
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

cmd_reset_local() {
	local skip_prompt=""
	for a in "$@"; do
		[[ "$a" == "-y" || "$a" == "--yes" ]] && skip_prompt=1 && break
	done

	echo "Reset PayRam local setup (clears database and API data so you can re-run headless from scratch)."
	echo "  - Stops and removes the payram container"
	echo "  - Removes .payraminfo (tokens, config, wallet backup)"
	echo "  - Removes .payram-core (database, logs)"
	echo "  - Removes .payram-setup.log"
	echo "Then you can run ./setup_payram_agents.sh again to start fresh."
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
	echo "Database and API data cleared."
	echo ""

	if [[ -z "$skip_prompt" ]]; then
		read -p "Also remove the PayRam Docker image(s)? (y/N): " full
		if [[ "$full" =~ ^[Yy] ]]; then
			echo "Removing PayRam Docker image(s)..."
			# Targeted removal only - never 'docker system prune', which would
			# delete unrelated containers/images on this host.
			docker images --filter=reference='payramapp/payram' -q 2>/dev/null | xargs docker rmi -f 2>/dev/null || true
			echo "Full clean done."
		fi
	else
		echo "Skipping full clean (use reset-local without -y to be asked)."
	fi
}

cmd_start_mcp_server() {
	local port="${PAYRAM_MCP_PORT:-3333}"
	if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
		echo "Invalid MCP server port: '$port' (must be 1-65535)."
		return 1
	fi
	local mcp_bin="${PAYRAM_INFO_DIR}/mcp.bin"
	local pid_file="${PAYRAM_INFO_DIR}/mcp-server.pid"
	local log_file="${PAYRAM_INFO_DIR}/mcp-server.log"

	mkdir -p "$PAYRAM_INFO_DIR"

	local mcp_version="${PAYRAM_MCP_VERSION:-v1.1.0}"

	# Re-download when the cached binary is from a different version
	local mcp_version_file="${PAYRAM_INFO_DIR}/mcp.bin.version"
	if [[ -f "$mcp_bin" && ! -f "$mcp_version_file" ]]; then
		log "No version file for cached MCP binary; re-downloading..."
		rm -f "$mcp_bin" "${mcp_bin}.sha256"
	elif [[ -f "$mcp_bin" && -f "$mcp_version_file" ]]; then
		local cached_version
		cached_version=$(cat "$mcp_version_file" 2>/dev/null || echo "")
		if [[ "$cached_version" != "$mcp_version" ]]; then
			log "Cached MCP binary version ($cached_version) differs from requested ($mcp_version); re-downloading..."
			rm -f "$mcp_bin" "${mcp_bin}.sha256" "$mcp_version_file"
		fi
	fi

	if [[ ! -f "$mcp_bin" ]]; then
		local mcp_base_url="https://github.com/PayRam/analytics-mcp-server/releases/download/${mcp_version}"
		log "Downloading Analytics MCP server binary (${mcp_version})..."
		if ! fetch_file "${mcp_base_url}/mcp.bin" "$mcp_bin"; then
			echo "Failed to download MCP server binary."
			return 1
		fi
		if ! fetch_file "${mcp_base_url}/mcp.bin.sha256" "${mcp_bin}.sha256"; then
			rm -f "$mcp_bin"
			echo "Failed to download MCP server checksum."
			return 1
		fi
		log "Verifying MCP server binary checksum..."
		(
			cd "$(dirname "$mcp_bin")" &&
			if command -v sha256sum >/dev/null 2>&1; then
				sha256sum -c "$(basename "$mcp_bin").sha256"
			elif command -v shasum >/dev/null 2>&1; then
				shasum -a 256 -c "$(basename "$mcp_bin").sha256"
			else
				echo "Neither sha256sum nor shasum is available; cannot verify binary."
				exit 1
			fi
		) || {
			rm -f "$mcp_bin" "${mcp_bin}.sha256"
			echo "MCP server checksum verification failed. Binary removed."
			return 1
		}
		chmod +x "$mcp_bin"
		echo "$mcp_version" > "$mcp_version_file"
	fi

	# Stop any previously started instance managed by this script
	if [[ -f "$pid_file" ]]; then
		local old_pid
		old_pid=$(cat "$pid_file" 2>/dev/null || echo "")
		if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
			local old_cmd
			old_cmd=$(ps -p "$old_pid" -o args= 2>/dev/null || true)
			if [[ "$old_cmd" == *"$mcp_bin"* ]]; then
				log "Stopping existing MCP server (PID $old_pid)..."
				kill "$old_pid" 2>/dev/null || true
				for ((w=0; w<5; w++)); do
					kill -0 "$old_pid" 2>/dev/null || break
					sleep 1
				done
				if kill -0 "$old_pid" 2>/dev/null; then
					log "MCP server did not exit gracefully; sending SIGKILL..."
					kill -9 "$old_pid" 2>/dev/null || true
					sleep 1
				fi
			else
				log "Ignoring stale MCP PID file; PID $old_pid is not the MCP server."
			fi
		fi
		rm -f "$pid_file"
	fi

	local base_url="${PAYRAM_API_URL}"
	# Prefer env vars; fall back to whatever the signin/setup flow saved in the token file
	local email="${PAYRAM_EMAIL:-${MEMBER_EMAIL:-}}"
	local password="${PAYRAM_PASSWORD:-}"

	if [[ -z "$email" ]]; then
		load_tokens
		email="${MEMBER_EMAIL:-}"
	fi

	if [[ -z "$email" && -t 0 ]]; then
		read -p "Email for MCP server: " email
	fi
	if [[ -z "$password" && -t 0 ]]; then
		read -s -p "Password for MCP server: " password
		echo
	fi

	if [[ -z "$email" || -z "$password" ]]; then
		echo "MCP server requires credentials. Set PAYRAM_EMAIL/PAYRAM_PASSWORD or run interactively."
		return 1
	fi

	log "Starting Analytics MCP server on port $port..."
	PAYRAM_ANALYTICS_BASE_URL="$base_url" \
	USER_EMAIL="$email" \
	USER_PASSWORD="$password" \
	nohup "$mcp_bin" --http ":${port}" >> "$log_file" 2>&1 &
	local mcp_pid=$!
	disown "$mcp_pid"
	echo "$mcp_pid" > "$pid_file"

	local max_tries=15
	for ((i=1; i<=max_tries; i++)); do
		sleep 1
		if ! kill -0 "$mcp_pid" 2>/dev/null; then
			echo "MCP server process exited unexpectedly. Check logs: $log_file"
			rm -f "$pid_file"
			return 1
		fi
		if curl -s --connect-timeout 1 --max-time 2 "http://localhost:${port}/health" 2>/dev/null | grep -q "ok"; then
			log "Analytics MCP server running (PID $mcp_pid)"
			echo "  Endpoint: http://localhost:${port}/"
			echo "  Health:   http://localhost:${port}/health"
			echo "  Logs:     $log_file"
			return 0
		fi
	done

	kill "$mcp_pid" 2>/dev/null || true
	rm -f "$pid_file"
	echo "MCP server did not respond within ${max_tries}s. Check logs: $log_file"
	return 1
}

cmd_menu() {
	echo "PayRam Agent - choose a step"
	echo "API: $PAYRAM_API_URL"
	echo ""
	echo "  1) status             - Check API and auth status"
	echo "  2) setup              - First-time: register root user + create default project"
	echo "  3) signin             - Sign in (saves token; required for most steps)"
	echo "  4) ensure-config      - Seed payram.frontend / payram.backend (local API)"
	echo "  5) ensure-wallet      - Starter deposit wallet (BTC+EVM xpub, no gas) or link existing"
	echo "  6) deploy-scw         - Deploy ETH/EVM smart-contract deposit wallet (admin)"
	echo " 10) deploy-scw-flow    - Generate mnemonic -> fund -> deploy SCW"
	echo "  7) create-payment-link - Create a payment link"
	echo " 11) start-mcp-server   - Start the Analytics MCP server"
	echo "  8) run                - Full flow: setup/signin -> wallet -> payment link -> MCP server (set PAYRAM_SKIP_MCP_SERVER=1 to omit)"
	echo "  9) reset-local        - Clear database and API data; re-run install"
	echo "  0) exit"
	echo ""
	read -p "Choice [0]: " choice
	choice="${choice:-0}"
	case "$choice" in
		1) cmd_status ;;
		2) cmd_setup ;;
		3) cmd_signin ;;
		4) ensure_config ;;
		5) ensure_wallet ;;
		6) cmd_deploy_scw ;;
		10) cmd_deploy_scw_flow ;;
		7) cmd_create_payment_link "$@" ;;
		11) cmd_start_mcp_server ;;
		8) cmd_run ;;
		9) cmd_reset_local ;;
		0) echo "Bye." ; return 0 ;;
		*) echo "Invalid choice." ; return 1 ;;
	esac
}

cmd_run() {
	echo "PayRam headless - setup to payment link"
	echo "API: $PAYRAM_API_URL"
	echo ""

	local res code body
	res=$(curl -s -w "\n%{http_code}" "${PAYRAM_API_URL}/api/v1/member/root/exist" 2>/dev/null || echo -e "\n000")
	body=$(echo "$res" | sed '$d')
	code=$(echo "$res" | tail -1)
	if [[ "$code" != "200" ]]; then
		echo "API unreachable. Is PayRam running? (e.g. ./setup_payram_agents.sh)"
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
			parse_auth_tokens "$HTTP_BODY"
			save_tokens
			echo "Signed in."
		fi
	else
		echo "First-time setup: create root user and project"
		local email="${PAYRAM_EMAIL:-}"
		read -p "Email for root user [admin@example.com]: " email_in
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
		parse_auth_tokens "$HTTP_BODY"
		save_tokens
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
	project_id=$(get_first_project_id) || return 1

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

	if [[ -z "${PAYRAM_SKIP_MCP_SERVER:-}" ]]; then
		echo ""
		cmd_start_mcp_server || true
	fi
}

headless_main() {
	echo ""
	echo "============================================================"
	echo "  PayRam Agent CLI (BETA)"
	echo "  Self-hosted payments - no signup, no KYB, yours."
	echo "============================================================"
	echo "  This tool is currently in BETA and under active testing."
	echo "  Bugs or unexpected behavior? Open an issue (Bug Bounty):"
	echo "    https://github.com/PayRam/payram-scripts/issues"
	echo "  Questions and ideas - join the community on Telegram:"
	echo "    https://t.me/PayRamChat"
	echo "============================================================"
	echo ""

	local cmd="${1:-menu}"
	shift 2>/dev/null || true
	case "$cmd" in
		status)   cmd_status ;;
		setup)    cmd_setup ;;
		signin)   cmd_signin ;;
		ensure-config) ensure_config ;;
		setup-mode)
			ensure_token || exit 1
			if [[ -n "${1:-}" ]]; then
				ensure_setup_mode "$1"
			else
				echo "Setup mode: $(get_setup_mode)"
			fi
			;;
		ensure-operator-config) ensure_token || exit 1; ensure_operator_config ;;
		ensure-api-key) ensure_api_key ;;
		ensure-wallet) ensure_wallet ;;
		deploy-scw) cmd_deploy_scw ;;
		deploy-scw-flow) cmd_deploy_scw_flow ;;
		create-payment-link) cmd_create_payment_link "$@" ;;
		start-mcp-server) cmd_start_mcp_server ;;
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

flow_main() {
	local network_mode="${PAYRAM_NETWORK:-}"
	local restart_mode="false"
	# MVF by default: an EVM smart-contract wallet on BASE, then a payment
	# link that accepts USDC. The master (deployer) wallet is created locally
	# and is ops-only; on mainnet the sweep destination must be a HUMAN-provided
	# cold address (PAYRAM_FUND_COLLECTOR). The one human wait is gas funding.
	# BTC is progressive - add it later: $0 ensure-wallet
	# (--ensure-wallet flips back to the BTC-first, no-gas fast lane.)
	local wallet_mode="deploy-scw"
	local attempt_scw="true"
	local create_payment_link="true"
	# Role: merchant by default. Operator mode (run PayRam as a platform for
	# other merchants, taking a bps fee) only when explicitly requested.
	local setup_mode="${PAYRAM_SETUP_MODE:-merchant}"
	local start_mcp_server="true"
	local mcp_port="${PAYRAM_MCP_PORT:-3333}"
	local node_mode="${PAYRAM_NODE_MODE:-docker}"
	local wallet_choice="${PAYRAM_WALLET_CHOICE:-}"

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--testnet)
				network_mode="testnet"
				shift
				;;
			--mainnet)
				network_mode="mainnet"
				shift
				;;
			--restart)
				restart_mode="true"
				shift
				;;
			--deploy-scw)
				wallet_mode="deploy-scw"
				shift
				;;
			--ensure-wallet)
				wallet_mode="ensure-wallet"
				shift
				;;
			--skip-scw)
				# No-gas escape hatch: skip the SCW entirely. With the SCW-first
				# default this downgrades the flow to the BTC fast lane.
				attempt_scw="false"
				wallet_mode="ensure-wallet"
				shift
				;;
			--operator)
				setup_mode="operator"
				shift
				;;
			--merchant)
				setup_mode="merchant"
				shift
				;;
			--wallet-choice=*)
				wallet_choice="${1#*=}"
				shift
				;;
			--skip-payment-link)
				create_payment_link="false"
				shift
				;;
			--create-payment-link)
				create_payment_link="true"
				shift
				;;
			--skip-mcp-server)
				start_mcp_server="false"
				shift
				;;
			--mcp-port=*)
				mcp_port="${1#*=}"
				if ! [[ "$mcp_port" =~ ^[0-9]+$ ]] || (( mcp_port < 1 || mcp_port > 65535 )); then
					echo "Invalid port: $mcp_port (must be 1-65535)"
					exit 1
				fi
				shift
				;;
			--node-mode=*)
				node_mode="${1#*=}"
				shift
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				echo "Unknown option: $1"
				usage
				exit 1
				;;
		esac
	done

	echo ""
	echo "====================================================================="
	echo "  Welcome to PayRam - your own payment gateway."
	echo ""
	echo "  No signup. No KYB. No middleman. In a few minutes this server"
	echo "  becomes payment infrastructure that answers only to you: payment"
	echo "  links, hosted checkout, BTC + EVM deposits, sweeps to YOUR cold"
	echo "  wallet. The kind of power that used to require a payments company."
	echo ""
	echo "  Every self-hosted gateway makes money a little more open. Glad"
	echo "  you're here - let's get you to your first payment link."
	echo "====================================================================="
	echo ""

	if [[ -z "$network_mode" ]]; then
		if [[ -t 0 ]]; then
			echo "Choose network:"
			echo "  1) mainnet - real payments (default)"
			echo "  2) testnet - try everything first with free test coins"
			echo "     Heads-up: test tokens are free but often a hassle to get - faucets"
			echo "     usually want an account, a mainnet balance, or a social post."
			echo "     With ~\$10 of real ETH, mainnet is often the faster path."
			read -p "Selection [1]: " net_choice
			net_choice="${net_choice:-1}"
			if [[ "$net_choice" == "2" ]]; then
				network_mode="testnet"
			else
				network_mode="mainnet"
			fi
		else
			network_mode="mainnet"
		fi
	fi
	if [[ "$network_mode" == "testnet" ]]; then
		log "Testnet mode. Note: faucets often have requirements (account, mainnet balance,"
		log "social post) - if they block you, mainnet with ~\$10 of ETH is the faster path."
	fi

	export PAYRAM_NODE_MODE="$node_mode"
	export PAYRAM_NETWORK="$network_mode"

	if [[ "$wallet_mode" == "ensure-wallet" && -z "$wallet_choice" ]]; then
		wallet_choice="1"
	fi
	[[ -n "$wallet_choice" ]] && export PAYRAM_WALLET_CHOICE="$wallet_choice"
	[[ -n "$wallet_choice" ]] && export PAYRAM_WALLET_QUIET=1

	# RPC defaults for deploy-scw live in cmd_deploy_scw_flow (per-chain aware);
	# nothing to pre-set here.

	log "Using assets at $ASSET_DIR"
	log "Working directory: $WORK_DIR"
	log "API: $PAYRAM_API_URL"
	log "Node mode: $PAYRAM_NODE_MODE"

	if [[ "$restart_mode" == "true" ]]; then
		log "Restarting PayRam container..."
		(cd "$SCRIPT_DIR" && run_as_root ./setup_payram.sh --restart)
	elif ! is_payram_running; then
		# A FRESH install delegates to setup_payram.sh - the working installer
		# from main, UNMODIFIED. It asks its one-time DB/SSL/port questions
		# interactively, so this single step needs a terminal; everything
		# after the install is fully headless. Without a TTY, fail fast with
		# directions instead of letting the installer's prompts die on EOF.
		if [[ ! -t 0 ]]; then
			troubleshoot install-interactive
			exit 1
		fi
		log "Installing/starting PayRam (${network_mode})..."
		log "The installer will ask a few one-time questions (database, SSL, port)."
		log "Tip: defaults are fine to start - SSL and ports can be changed later."
		local install_rc=0
		if [[ "$network_mode" == "mainnet" ]]; then
			(cd "$SCRIPT_DIR" && run_as_root ./setup_payram.sh --mainnet) || install_rc=$?
		else
			(cd "$SCRIPT_DIR" && run_as_root ./setup_payram.sh --testnet) || install_rc=$?
		fi
		if [[ "$install_rc" -ne 0 ]]; then
			troubleshoot install-interactive
			exit "$install_rc"
		fi
		# The install may have just created config.env - re-derive the real
		# port/dirs from it rather than keeping pre-install guesses.
		load_install_config
		export PAYRAM_API_URL="${PAYRAM_API_URL_OVERRIDE:-$DERIVED_API_URL}"
		echo ""
		log "Gateway installed. That was the hard part - the rest is automatic."
	else
		log "PayRam container already running."
	fi

	log "Waiting for API readiness at $PAYRAM_API_URL..."
	if ! wait_for_api; then
		echo "API did not become ready at $PAYRAM_API_URL"
		troubleshoot api-unreachable
		exit 1
	fi

	log "Auth setup..."
	export PAYRAM_SETUP_MODE="$setup_mode"
	if root_exists; then
		cmd_signin
		# Existing install: make sure the role matches what was asked for
		# (no-op when already set; refuses with directions when locked).
		ensure_setup_mode "$setup_mode" || true
	else
		cmd_setup
	fi

	log "Ensuring config..."
	ensure_config

	if [[ "$setup_mode" == "operator" ]]; then
		log "Operator lane: configuring fee collectors + default fees..."
		if ! ensure_operator_config; then
			log "Operator fee config incomplete - wallet and payment-link steps need it."
			log "Provide the env vars above (or use the dashboard) and re-run; everything is resumable."
			wallet_mode="skip"
			create_payment_link="false"
			attempt_scw="false"
		fi
	fi

	if [[ "$wallet_mode" == "deploy-scw" ]]; then
		# Default MVF: SCW first (blocking, guided funding). Chain defaults to
		# BASE so the resulting link takes USDC with sub-cent gas; override
		# with PAYRAM_BLOCKCHAIN_CODE=ETH/POLYGON. When WE pick the chain
		# (defaulted), mark it so re-runs stay idempotent (no double deploy);
		# an explicitly chosen chain keeps its add-another-chain semantics.
		if [[ -z "${PAYRAM_BLOCKCHAIN_CODE:-}" ]]; then
			export PAYRAM_BLOCKCHAIN_CODE="BASE"
			export PAYRAM_SCW_CHAIN_DEFAULTED=1
		fi
		log "Deploying SCW wallet on ${PAYRAM_BLOCKCHAIN_CODE} (USDC-ready)..."
		cmd_deploy_scw_flow
	elif [[ "$wallet_mode" == "skip" ]]; then
		log "Skipping wallet setup (operator fee config pending)."
	else
		log "Ensuring deposit wallet (BTC xpub - instant, no gas)..."
		ensure_wallet
	fi

	if [[ "$create_payment_link" == "true" ]]; then
		log "Creating payment link..."
		cmd_create_payment_link
	else
		log "Skipping payment link creation."
	fi

	# Mint the merchant API key so integrations (and the PayRam MCP) can take
	# over without a dashboard visit. Non-fatal: the link above already works.
	if [[ "$wallet_mode" != "skip" ]]; then
		log "Ensuring merchant API key..."
		ensure_api_key || log "API key step deferred - run '$0 ensure-api-key' anytime."
	fi

	# Quick-setup continuation: BTC link is live; now unlock USDC/EVM via the
	# ETH smart-contract wallet. Best-effort - with a TTY it guides funding;
	# headless and unfunded it defers with instructions instead of blocking.
	if [[ "$wallet_mode" == "ensure-wallet" && "$attempt_scw" == "true" ]]; then
		log "Enabling USDC/EVM payments (ETH smart-contract wallet)..."
		if [[ -t 0 ]]; then
			cmd_deploy_scw_flow || log "SCW deploy deferred - run '$0 deploy-scw-flow' when ready."
		else
			PAYRAM_SCW_FUND_MAX_ATTEMPTS=1 cmd_deploy_scw_flow \
				|| log "SCW deploy deferred (deployer not funded). BTC payments work now; for USDC/EVM run '$0 deploy-scw-flow' after funding the deployer."
		fi
	fi

	if [[ "$start_mcp_server" == "true" ]]; then
		export PAYRAM_MCP_PORT="$mcp_port"
		log "Starting Analytics MCP server..."
		cmd_start_mcp_server || log "MCP server start failed (non-fatal; run 'start-mcp-server' manually)."
	else
		log "Skipping Analytics MCP server."
	fi

	echo ""
	echo "================== PayRam is ready =================="
	if [[ -n "${payment_url:-}" ]]; then
		echo "Try your first payment now:"
		echo ""
		echo "  $payment_url"
		echo ""
	fi
	echo "Network: ${network_mode}    Role: ${setup_mode}    API: $PAYRAM_API_URL"
	echo "State:   $PAYRAM_INFO_DIR  (tokens, wallet mnemonic - back it up)"
	if [[ "$setup_mode" == "operator" ]]; then
		echo "Operator: fees from merchant volume route to YOUR fee collectors."
		echo "  Dashboard -> Operator shows earnings; tune fees: $0 ensure-operator-config"
	fi
	echo ""
	echo "Everything set up today can be changed later:"
	echo "  - SSL/HTTPS: not set up yet (HTTP first keeps setup simple). Add anytime:"
	echo "    sudo ./setup_payram.sh   (menu -> SSL Configuration; Let's Encrypt or custom certs)"
	echo "  - Ports / database: also changeable via  sudo ./setup_payram.sh  (update flow)"
	echo "  - Add/replace deposit wallets:  dashboard -> Project -> Wallet  (or: $0 ensure-wallet)"
	if grep -q '^SCW_LINKED=1' "$SCW_STATE_FILE" 2>/dev/null; then
		echo "  - USDC/EVM payments: ENABLED (smart-contract wallet linked)"
		echo "  - More chains later:  PAYRAM_BLOCKCHAIN_CODE=ETH $0 deploy-scw   (POLYGON likewise)"
		echo "  - Add BTC payments:  $0 ensure-wallet"
		echo "  - Master wallet is local + ops-only ($PAYRAM_INFO_DIR/headless-wallet-secret.txt)."
		echo "    KEEP it for now - it's needed to deploy on more chains and to change the"
		echo "    cold-wallet config on-chain. Back it up offline FIRST; only remove it from"
		echo "    this host once ALL chains are deployed and the cold-wallet config is final."
	else
		echo "  - USDC/EVM payments: NOT yet enabled. Fund the deployer with gas and run:"
		echo "    $0 deploy-scw-flow"
		echo "  - More chains after that:  PAYRAM_BLOCKCHAIN_CODE=ETH $0 deploy-scw"
		echo "  - Add BTC payments:  $0 ensure-wallet"
	fi
	if [[ "$network_mode" != "mainnet" ]]; then
		echo "  - Going LIVE? Re-run with --mainnet and set PAYRAM_FUND_COLLECTOR to YOUR"
		echo "    cold-wallet address (that is where swept customer funds land)."
	else
		echo "  - You are on MAINNET: confirm the fund collector is YOUR cold wallet before"
		echo "    taking real payments (dashboard -> Wallets)."
	fi
	echo "  - More payment links anytime:  $0 create-payment-link"
	if [[ -f "$API_KEY_FILE" ]]; then
		echo "  - Integrate into your app: credentials saved at $API_KEY_FILE"
		echo "    Connect the PayRam MCP (https://mcp.payram.com/mcp) and it can generate"
		echo "    routes/webhooks for your stack using PAYRAM_BASE_URL + PAYRAM_API_KEY."
	else
		echo "  - Integrate into your app: $0 ensure-api-key   (then connect mcp.payram.com)"
	fi
	echo ""
	echo "Thank you for self-hosting PayRam. You now run payment rails that no"
	echo "platform can switch off - and every independent gateway like yours"
	echo "nudges money a little further toward open. Welcome to the revolution."
	echo ""
	echo "Questions, ideas, or stuck on anything? Come say hi - the community"
	echo "and the team hang out here:"
	echo "  Telegram:  https://t.me/PayRamChat"
	echo "  Issues:    https://github.com/PayRam/payram-scripts/issues"
	echo "====================================================="
}

main() {
	local cmd="${1:-}"
	case "$cmd" in
		status|setup|signin|ensure-config|setup-mode|ensure-operator-config|ensure-api-key|ensure-wallet|deploy-scw|deploy-scw-flow|create-payment-link|start-mcp-server|reset-local|menu|run)
			MODE="headless"
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			MODE="flow"
			;;
	esac

	ensure_assets
	SCRIPT_DIR="$ASSET_DIR"
	cd "$SCRIPT_DIR"

	# Remember whether the caller pinned the API URL explicitly - a fresh
	# install re-derives the URL from the new config.env unless they did.
	PAYRAM_API_URL_OVERRIDE="${PAYRAM_API_URL:-}"

	# Read the installed truth (port/dirs/network) from setup_payram.sh's
	# config.env before choosing any defaults - never assume them.
	load_install_config

	# State dirs: anchor to the same home the installer uses (it hard-assigns
	# $HOME/.payram* regardless of env), so tokens/wallet/reset all act on the
	# REAL install. PAYRAM_WORK_DIR is an explicit override; the old cwd default
	# is kept only when a legacy cwd install actually exists.
	local state_home="${INSTALL_HOME:-$HOME}"
	if [[ -z "$INSTALL_CONFIG_FILE" && -d "${ORIG_DIR}/.payraminfo" ]]; then
		state_home="$ORIG_DIR"
	fi
	WORK_DIR="${PAYRAM_WORK_DIR:-$state_home}"
	export PAYRAM_LOCAL_SETUP=1
	export PAYRAM_INFO_DIR="${PAYRAM_INFO_DIR:-${WORK_DIR}/.payraminfo}"
	export PAYRAM_CORE_DIR="${PAYRAM_CORE_DIR:-${WORK_DIR}/.payram-core}"
	export LOG_FILE="${LOG_FILE:-${WORK_DIR}/.payram-setup.log}"
	export PAYRAM_API_URL="${PAYRAM_API_URL:-$DERIVED_API_URL}"
	export PAYRAM_NODE_MODE="${PAYRAM_NODE_MODE:-docker}"
	export PAYRAM_NODE_DOCKER_IMAGE="${PAYRAM_NODE_DOCKER_IMAGE:-node:20-bullseye-slim}"
	if [[ -z "${PAYRAM_NETWORK:-}" && -n "$INSTALL_NETWORK" ]]; then
		export PAYRAM_NETWORK="$INSTALL_NETWORK"
	fi

	PAYRAM_INFO_DIR="$PAYRAM_INFO_DIR"
	PAYRAM_CORE_DIR="$PAYRAM_CORE_DIR"
	PAYRAM_API_URL="$PAYRAM_API_URL"
	TOKEN_FILE="${PAYRAM_INFO_DIR}/headless-tokens.env"
	SCW_STATE_FILE="${PAYRAM_INFO_DIR}/scw-state.env"
	API_KEY_FILE="${PAYRAM_INFO_DIR}/merchant-api-key.env"
	CREDENTIALS_FILE="${PAYRAM_INFO_DIR}/root-credentials.env"
	PAYRAM_NODE_MODE="$PAYRAM_NODE_MODE"
	PAYRAM_NODE_DOCKER_IMAGE="$PAYRAM_NODE_DOCKER_IMAGE"

	if [[ "$MODE" == "headless" ]]; then
		headless_main "$@"
	else
		flow_main "$@"
	fi
}

main "$@"
