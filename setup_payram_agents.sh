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
	setup_payram_agents.sh [options]            One-step flow (install -> headless)
	setup_payram_agents.sh <command> [args]     Headless commands only

One-step options:
	--testnet               Install/run in testnet mode (default)
	--mainnet               Install/run in mainnet mode
	--restart               Restart PayRam container before headless steps
	--ensure-wallet         Ensure BTC wallet
	--deploy-scw            Deploy ETH/EVM SCW wallet (default)
	--wallet-choice=1|2|3   Wallet flow choice (1=create, 2=link, 3=skip)
	--skip-payment-link     Do not create a payment link
	--create-payment-link   Create a payment link (default)
	--skip-mcp-server       Do not start the Analytics MCP server
	--mcp-port=NUMBER       MCP server HTTP port (default 3333)
	--node-mode=host|docker Node runtime for JS (default docker)
	-h, --help              Show help

Headless commands:
	status | setup | signin | ensure-config | ensure-wallet | deploy-scw | deploy-scw-flow
	create-payment-link [projectId] [email] [amountUSD]
	start-mcp-server
	reset-local [-y]
	menu | run

Env vars:
	PAYRAM_NETWORK (testnet|mainnet)
	PAYRAM_API_URL, PAYRAM_EMAIL, PAYRAM_PASSWORD, PAYRAM_PROJECT_NAME
	PAYRAM_PAYMENT_EMAIL, PAYRAM_PAYMENT_AMOUNT, PAYRAM_CUSTOMER_ID
	PAYRAM_FRONTEND_URL
	PAYRAM_ETH_RPC_URL, PAYRAM_FUND_COLLECTOR, PAYRAM_SCW_NAME, PAYRAM_BLOCKCHAIN_CODE, PAYRAM_MNEMONIC
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
	docker ps --format '{{.Names}}' | grep -q '^payram$'
}

PAYRAM_INFO_DIR=""
PAYRAM_CORE_DIR=""
PAYRAM_API_URL=""
TOKEN_FILE=""
PAYRAM_NODE_MODE=""
PAYRAM_NODE_DOCKER_IMAGE=""
NODE_MODE_RESOLVED=""

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
		for var in PAYRAM_API_URL PAYRAM_ACCESS_TOKEN PAYRAM_MNEMONIC_FILE PAYRAM_ETH_RPC_URL PAYRAM_FUND_COLLECTOR PAYRAM_SCW_NAME PAYRAM_BLOCKCHAIN_CODE PAYRAM_MNEMONIC PAYRAM_DEPLOYER_ADDRESS PAYRAM_SCW_MIN_BALANCE_ETH; do
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
	if [[ "$code" == "500" && "$context" == "Create payment link" ]]; then
		echo ""
		echo "Possible causes: no wallet linked, missing config (e.g. payram.frontend), or address pool not ready."
		echo "  -> If no wallet: run $0 ensure-wallet   or link one in the dashboard (Project -> Wallet)."
		echo "  -> Check backend logs (below) for the actual error."
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
	mkdir -p "$(dirname "$TOKEN_FILE")"
	echo "ACCESS_TOKEN=\"$ACCESS_TOKEN\"" > "$TOKEN_FILE"
	echo "REFRESH_TOKEN=\"$REFRESH_TOKEN\"" >> "$TOKEN_FILE"
	return 0
}

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
		echo "API: unreachable (is PayRam running? try ./setup_payram_agents.sh)"
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
	local email="${PAYRAM_EMAIL:-}"
	local password="${PAYRAM_PASSWORD:-}"
	if [[ -z "$email" ]]; then
		read -p "Email for root user: " email
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
	local gen parsed mnemonic
	if ! gen=$(run_node "$script_dir" generate-deposit-wallet-eth.js 2>&1); then
		echo "Failed to generate ETH wallet mnemonic."
		echo "$gen"
		return 1
	fi
	parsed=$(echo "$gen" | run_node "$script_dir" -e "
		let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
			try { const j=JSON.parse(d); console.log('MNEMONIC', j.mnemonic); }
			catch(e) { process.exit(1); }
		});
	" 2>/dev/null)
	mnemonic=$(echo "$parsed" | grep '^MNEMONIC ' | sed 's/^MNEMONIC //')
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

check_eth_balance() {
	local script_dir="$SCRIPT_DIR/scripts"
	ensure_node_deps "$script_dir" || return 1
	PAYRAM_SCW_MIN_BALANCE_ETH="${PAYRAM_SCW_MIN_BALANCE_ETH:-0.01}" run_node "$script_dir" -e "
		const { ethers } = require('ethers');
		const rpc = process.env.PAYRAM_ETH_RPC_URL;
		const addr = process.env.PAYRAM_DEPLOYER_ADDRESS;
		const min = process.env.PAYRAM_SCW_MIN_BALANCE_ETH || '0.01';
		const provider = new ethers.JsonRpcProvider(rpc);
		(async () => {
			const bal = await provider.getBalance(addr);
			const ok = bal >= ethers.parseEther(min);
			console.log(ok ? 'OK' : 'WAIT');
			console.log(ethers.formatEther(bal));
		})().catch(() => process.exit(1));
	" 2>/dev/null
}

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
	if echo "$HTTP_BODY" | grep -q '"walletID"'; then
		echo "Project already has a wallet linked."
		return 0
	fi

	if [[ -z "${PAYRAM_WALLET_QUIET:-}" ]]; then
		echo ""
		echo "This project has no wallet linked. Payment links need a deposit wallet so"
		echo "customers get unique deposit addresses. The API uses XPUB only (no private key sent)."
		echo ""
		echo "  (1) Create a random wallet - mnemonic saved to .payraminfo (or printed)"
		echo "  (2) Link an existing wallet you already created"
		echo "  (3) Skip (link later via dashboard or API)"
		echo ""
	fi
	local choice
	if [[ -n "${PAYRAM_WALLET_CHOICE:-}" ]]; then
		choice="$PAYRAM_WALLET_CHOICE"
		[[ -z "${PAYRAM_WALLET_QUIET:-}" ]] && echo "Choice [1]: $choice"
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
		local mnemonic xpub parsed
		parsed=$(echo "$gen" | run_node "$script_dir/scripts" -e "
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
	resolve_node_mode || return 1
	echo "deploy-scw: installing deps if needed..."
	ensure_node_deps "$SCRIPT_DIR/scripts" || return 1
	export PAYRAM_API_URL
	export PAYRAM_ACCESS_TOKEN="$ACCESS_TOKEN"
	export PAYRAM_MNEMONIC_FILE="${PAYRAM_INFO_DIR}/headless-wallet-secret.txt"
	[[ -n "${PAYRAM_ETH_RPC_URL:-}" ]] && export PAYRAM_ETH_RPC_URL
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

cmd_deploy_scw_flow() {
	echo "deploy-scw-flow: preparing mnemonic and funding wallet..."
	ensure_token || { echo "Sign in first: $0 signin"; return 1; }
	ensure_eth_mnemonic || return 1

	if [[ -z "${PAYRAM_ETH_RPC_URL:-}" ]]; then
		if [[ "${PAYRAM_NETWORK:-}" == "mainnet" ]]; then
			PAYRAM_ETH_RPC_URL="https://eth.llamarpc.com"
		else
			PAYRAM_ETH_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
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

	if [[ -z "${PAYRAM_SCW_MIN_BALANCE_ETH:-}" ]]; then
		if [[ "${PAYRAM_NETWORK:-}" == "mainnet" ]]; then
			PAYRAM_SCW_MIN_BALANCE_ETH="0.02"
		else
			PAYRAM_SCW_MIN_BALANCE_ETH="0.01"
		fi
	fi

	if [[ -t 0 ]]; then
		echo ""
		echo "Fund the deployer address with ETH for gas."
		echo "Deployer address: $deployer"
		echo "RPC: $PAYRAM_ETH_RPC_URL"
	fi

	local attempts=0
	local max_attempts=60
	while true; do
		local status balance res
		res=$(check_eth_balance)
		status=$(echo "$res" | head -1)
		balance=$(echo "$res" | tail -1)
		if [[ -z "$status" ]]; then
			echo "Failed to check balance via RPC."
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
			echo "Balance ${balance} ETH is below ${PAYRAM_SCW_MIN_BALANCE_ETH}. Add funds and press Enter to recheck."
			read -r _
		else
			if [[ $attempts -ge $max_attempts ]]; then
				echo "Balance not confirmed after ${max_attempts} checks."
				return 1
			fi
			sleep 10
		fi
	done

	cmd_deploy_scw
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
		read -p "Generate a test payment link, Amount (USD) [$amount_usd]: " amount_in
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
	echo "  5) ensure-wallet      - Create BTC wallet or link existing (for payment links)"
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

	if [[ -z "${PAYRAM_SKIP_MCP_SERVER:-}" ]]; then
		echo ""
		cmd_start_mcp_server || true
	fi
}

headless_main() {
	echo ""
	echo "============================================================"
	echo "  PayRam Agent CLI (BETA)"
	echo "============================================================"
	echo "  This tool is currently in BETA and under active testing."
	echo "  If you encounter any bugs or unexpected behavior, please"
	echo "  open an issue on the repo for our Bug Bounty program:"
	echo ""
	echo "    https://github.com/PayRam/payram-scripts/issues"
	echo ""
	echo "  We appreciate your help in making PayRam better!"
	echo "============================================================"
	echo ""

	local cmd="${1:-menu}"
	shift 2>/dev/null || true
	case "$cmd" in
		status)   cmd_status ;;
		setup)    cmd_setup ;;
		signin)   cmd_signin ;;
		ensure-config) ensure_config ;;
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
	local wallet_mode="deploy-scw"
	local create_payment_link="true"
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

	if [[ -z "$network_mode" ]]; then
		if [[ -t 0 ]]; then
			echo "Choose network:"
			echo "  1) testnet"
			echo "  2) mainnet"
			read -p "Selection [1]: " net_choice
			net_choice="${net_choice:-1}"
			if [[ "$net_choice" == "2" ]]; then
				network_mode="mainnet"
			else
				network_mode="testnet"
			fi
		else
			network_mode="testnet"
		fi
	fi

	export PAYRAM_NODE_MODE="$node_mode"
	export PAYRAM_NETWORK="$network_mode"

	if [[ "$wallet_mode" == "ensure-wallet" && -z "$wallet_choice" ]]; then
		wallet_choice="1"
	fi
	[[ -n "$wallet_choice" ]] && export PAYRAM_WALLET_CHOICE="$wallet_choice"
	[[ -n "$wallet_choice" ]] && export PAYRAM_WALLET_QUIET=1

	if [[ "$wallet_mode" == "deploy-scw" && -z "${PAYRAM_ETH_RPC_URL:-}" ]]; then
		if [[ "$network_mode" == "mainnet" ]]; then
			export PAYRAM_ETH_RPC_URL="https://eth.llamarpc.com"
		else
			export PAYRAM_ETH_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
		fi
	fi

	log "Using assets at $ASSET_DIR"
	log "Working directory: $WORK_DIR"
	log "API: $PAYRAM_API_URL"
	log "Node mode: $PAYRAM_NODE_MODE"

	if [[ "$restart_mode" == "true" ]]; then
		log "Restarting PayRam container..."
		(cd "$SCRIPT_DIR" && run_as_root ./setup_payram.sh --restart)
	elif ! is_payram_running; then
		log "Installing/starting PayRam (${network_mode})..."
		if [[ "$network_mode" == "mainnet" ]]; then
			(cd "$SCRIPT_DIR" && run_as_root ./setup_payram.sh --mainnet)
		else
			(cd "$SCRIPT_DIR" && run_as_root ./setup_payram.sh --testnet)
		fi
	else
		log "PayRam container already running."
	fi

	log "Waiting for API readiness..."
	if ! wait_for_api; then
		echo "API did not become ready at $PAYRAM_API_URL"
		exit 1
	fi

	log "Auth setup..."
	if root_exists; then
		cmd_signin
	else
		cmd_setup
	fi

	log "Ensuring config..."
	ensure_config

	if [[ "$wallet_mode" == "deploy-scw" ]]; then
		log "Deploying SCW wallet..."
		cmd_deploy_scw_flow
	else
		log "Ensuring deposit wallet..."
		ensure_wallet
	fi

	if [[ "$create_payment_link" == "true" ]]; then
		log "Creating payment link..."
		cmd_create_payment_link
	else
		log "Skipping payment link creation."
	fi

	if [[ "$start_mcp_server" == "true" ]]; then
		export PAYRAM_MCP_PORT="$mcp_port"
		log "Starting Analytics MCP server..."
		cmd_start_mcp_server || log "MCP server start failed (non-fatal; run 'start-mcp-server' manually)."
	else
		log "Skipping Analytics MCP server."
	fi

	log "Done."
}

main() {
	local cmd="${1:-}"
	case "$cmd" in
		status|setup|signin|ensure-config|ensure-wallet|deploy-scw|deploy-scw-flow|create-payment-link|start-mcp-server|reset-local|menu|run)
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

	WORK_DIR="${PAYRAM_WORK_DIR:-$ORIG_DIR}"
	export PAYRAM_LOCAL_SETUP=1
	export PAYRAM_INFO_DIR="${PAYRAM_INFO_DIR:-${WORK_DIR}/.payraminfo}"
	export PAYRAM_CORE_DIR="${PAYRAM_CORE_DIR:-${WORK_DIR}/.payram-core}"
	export LOG_FILE="${LOG_FILE:-${WORK_DIR}/.payram-setup.log}"
	export PAYRAM_API_URL="${PAYRAM_API_URL:-http://localhost:8080}"
	export PAYRAM_NODE_MODE="${PAYRAM_NODE_MODE:-docker}"
	export PAYRAM_NODE_DOCKER_IMAGE="${PAYRAM_NODE_DOCKER_IMAGE:-node:20-bullseye-slim}"

	PAYRAM_INFO_DIR="$PAYRAM_INFO_DIR"
	PAYRAM_CORE_DIR="$PAYRAM_CORE_DIR"
	PAYRAM_API_URL="$PAYRAM_API_URL"
	TOKEN_FILE="${PAYRAM_INFO_DIR}/headless-tokens.env"
	PAYRAM_NODE_MODE="$PAYRAM_NODE_MODE"
	PAYRAM_NODE_DOCKER_IMAGE="$PAYRAM_NODE_DOCKER_IMAGE"

	if [[ "$MODE" == "headless" ]]; then
		headless_main "$@"
	else
		flow_main "$@"
	fi
}

main "$@"
