#!/bin/bash
# Exercise the real run_node function with argument-capturing Docker/Node
# stand-ins. No installer, gateway, wallet, Docker daemon or network is used.
# Run with bash 3.2 or newer; AGENTS_SCRIPT can select an older source file.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_SCRIPT="${AGENTS_SCRIPT:-$TESTS_DIR/../setup_payram_agents.sh}"
BASH_BIN="${BASH_BIN:-$BASH}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/work dir" "$WORK_DIR/home"
LIB="$WORK_DIR/run_node.sh"
sed -n '/^run_node() {$/,/^}$/p' "$AGENTS_SCRIPT" > "$LIB"
if ! grep -q '^run_node() {$' "$LIB"; then
  echo "Cannot find run_node in $AGENTS_SCRIPT" >&2
  exit 1
fi

PASSED=0
FAILED=0
# Verify a captured call for LABEL MODE INPUT EXPECTED, recording pass/fail.
# INPUT=UNSET leaves the URL absent; an empty EXPECTED requires Docker omission.
# A failed case is recorded so the remaining regression cases can still run.
run_case() {
  local label="$1" mode="$2" input="$3" expected="$4"
  local capture="$WORK_DIR/arguments" arg value='' count=0 project_count=0
  local i size
  local -a args=()
  # Only fixture values enter the child. Sourcing this extracted function
  # does not run the CLI's startup or read any existing configuration.
  if ! env -i PATH="$PATH" HOME="$WORK_DIR/home" \
    "$BASH_BIN" --noprofile --norc -c '
      set -euo pipefail
      source "$1"
      NODE_MODE_RESOLVED="$2"
      PAYRAM_NODE_DOCKER_IMAGE=fixture/never-run
      PAYRAM_INFO_DIR=""
      PAYRAM_PROJECT_ID=fixture-project
      export PAYRAM_PROJECT_ID
      if [[ "$3" != UNSET ]]; then
        PAYRAM_API_URL="$3"
        export PAYRAM_API_URL
      fi
      resolve_node_mode() { :; }
      docker() { printf "%s\0" "$@"; }
      node() { printf "%s\0" "PAYRAM_API_URL=${PAYRAM_API_URL:-}" "$@"; }
      run_node "$4" fixture.js "two words"
    ' node-url-test "$LIB" "$mode" "$input" "$WORK_DIR/work dir" > "$capture"; then
    echo "FAIL [$label] run_node failed"
    FAILED=$((FAILED + 1))
    return
  fi
  while IFS= read -r -d '' arg; do args+=("$arg"); done < "$capture"
  size=${#args[@]}
  if [[ "$mode" == host ]]; then
    if [[ "$size" -eq 3 && "${args[0]}" == "PAYRAM_API_URL=$expected" &&
          "${args[1]}" == fixture.js && "${args[2]}" == 'two words' ]]; then
      PASSED=$((PASSED + 1))
    else
      echo "FAIL [$label] host URL or arguments changed"
      FAILED=$((FAILED + 1))
    fi
    return
  fi
  for ((i=0; i+1<size; i++)); do
    if [[ "${args[i]}" == -e ]]; then
      case "${args[i+1]}" in
        PAYRAM_API_URL=*) count=$((count + 1)); value="${args[i+1]#PAYRAM_API_URL=}" ;;
        PAYRAM_API_URL) count=$((count + 1)); value=BARE_NAME ;;
        PAYRAM_PROJECT_ID) project_count=$((project_count + 1)) ;;
      esac
    fi
  done
  local expected_count=1
  [[ -n "$expected" ]] || expected_count=0
  if [[ "$count" -eq "$expected_count" && "$value" == "$expected" &&
        "$project_count" -eq 1 && "$size" -ge 4 &&
        "${args[size-4]}" == fixture/never-run && "${args[size-3]}" == node &&
        "${args[size-2]}" == fixture.js && "${args[size-1]}" == 'two words' ]]; then
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL [%s] expected %q (%s API argument), got %q (%s), project arguments %s\n' \
      "$label" "$expected" "$expected_count" "$value" "$count" "$project_count"
    FAILED=$((FAILED + 1))
  fi
}

run_case localhost docker 'http://localhost:8080' 'http://host.docker.internal:8080'
run_case ipv4 docker 'http://127.0.0.1:8080' 'http://host.docker.internal:8080'
run_case bare-host docker 'http://localhost' 'http://host.docker.internal'
run_case https docker 'https://localhost:9443/api' 'https://host.docker.internal:9443/api'
run_case empty-port docker 'http://localhost:/api' 'http://host.docker.internal:/api'
run_case uppercase-scheme docker 'HTTP://localhost/api' 'HTTP://host.docker.internal/api'
run_case mixed-case-host docker 'http://LocalHost:8080/api' 'http://host.docker.internal:8080/api'
run_case query docker 'http://localhost?return=127.0.0.1' 'http://host.docker.internal?return=127.0.0.1'
run_case fragment docker 'http://127.0.0.1#localhost' 'http://host.docker.internal#localhost'
run_case userinfo docker 'http://user:pass@localhost:8080/api' 'http://user:pass@host.docker.internal:8080/api'
run_case userinfo-and-path docker 'http://localhost:127.0.0.1@localhost/api/127.0.0.1' 'http://localhost:127.0.0.1@host.docker.internal/api/127.0.0.1'
run_case remote docker 'https://gateway.example.invalid' 'https://gateway.example.invalid'
run_case lan docker 'http://192.0.2.10:8080/api' 'http://192.0.2.10:8080/api'
run_case service docker 'http://payram:8080' 'http://payram:8080'
run_case remote-path docker 'https://gateway.example.invalid/api/localhost' 'https://gateway.example.invalid/api/localhost'
run_case remote-query docker 'https://gateway.example.invalid?upstream=127.0.0.1' 'https://gateway.example.invalid?upstream=127.0.0.1'
run_case remote-fragment docker 'https://gateway.example.invalid#localhost' 'https://gateway.example.invalid#localhost'
run_case hostname-prefix docker 'https://localhost-gateway.example.invalid' 'https://localhost-gateway.example.invalid'
run_case hostname-suffix docker 'https://gateway-localhost.example.invalid' 'https://gateway-localhost.example.invalid'
run_case ipv4-prefix docker 'https://127.0.0.1.example.invalid' 'https://127.0.0.1.example.invalid'
run_case remote-userinfo docker 'https://localhost@gateway.example.invalid' 'https://localhost@gateway.example.invalid'
run_case remote-userinfo-password docker 'https://localhost:password@gateway.example.invalid' 'https://localhost:password@gateway.example.invalid'
run_case remote-ipv6 docker 'http://[2001:db8::1]:8080/localhost' 'http://[2001:db8::1]:8080/localhost'
run_case unset docker UNSET ''
run_case empty docker '' ''
run_case host-remote host 'https://gateway.example.invalid' 'https://gateway.example.invalid'
run_case host-localhost host 'http://localhost:8080/api' 'http://localhost:8080/api'
run_case host-userinfo host 'http://user@127.0.0.1:8080/api' 'http://user@127.0.0.1:8080/api'
run_case host-unset host UNSET ''

echo "$PASSED passed, $FAILED failed ($("$BASH_BIN" -c 'printf "%s" "$BASH_VERSION"'))"
[[ "$FAILED" -eq 0 ]]
