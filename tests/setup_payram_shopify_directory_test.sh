#!/usr/bin/env bash
# Run the directory bootstrap and capture deploy arguments in disposable fixtures.
# Usage: bash tests/setup_payram_shopify_directory_test.sh [installer-source]
# BASH_UNDER_TEST selects the child Bash; no installer entrypoint is executed.
set -uo pipefail

SOURCE_FILE="${1:-$(cd "$(dirname "$0")/.." && pwd)/setup_payram_shopify.sh}"
BASH_BIN="${BASH_UNDER_TEST:-bash}"
if ! INSTALL_BLOCK=$(awk '
  /^read -rp .*Install directory.*INSTALL_DIR$/ { copying = 1 }
  /^load_env\(\) \{/ && copying { found_end = 1; exit }
  copying { print }
  END { if (!found_end) exit 2 }
' "$SOURCE_FILE"); then
  printf 'Could not find both installer bootstrap boundaries in %s\n' "$SOURCE_FILE" >&2
  exit 2
fi

if ! DEPLOY_BLOCK=$(awk '
  /^MOUNT_SOURCE=/ { print; next }
  /^DOCKER_DEPLOY_ARGS=\(/ { copying = 1 }
  /^\)$/ && copying { print; found_end = 1; exit }
  copying { print }
  END { if (!found_end) exit 2 }
' "$SOURCE_FILE"); then
  printf 'Could not find both deploy-argument boundaries in %s\n' "$SOURCE_FILE" >&2
  exit 2
fi
if ! NON_TTY_BLOCK=$(awk '
  /^  command -v script / { copying = 1 }
  /^fi$/ && copying { found_end = 1; exit }
  copying { print }
  END { if (!found_end) exit 2 }
' "$SOURCE_FILE"); then
  printf 'Could not find both non-TTY boundaries in %s\n' "$SOURCE_FILE" >&2
  exit 2
fi

TEST_PARENT=$(cd "${TMPDIR:-/tmp}" && pwd -P) || exit 2
TEST_ROOT=$(mktemp -d "$TEST_PARENT/payram-shopify-directory.XXXXXX") || exit 2

# Remove only the newly created fixture tree under the resolved temp directory.
cleanup() {
  case "$TEST_ROOT" in
    "$TEST_PARENT"/payram-shopify-directory.*) rm -rf -- "$TEST_ROOT" ;;
  esac
}
trap cleanup EXIT
PASSED=0
FAILED=0

PRELUDE='set -euo pipefail
BOLD=""
RESET=""
DEFAULT_INSTALL_DIR="$HOME/payram-shopify-connector"
'
REPORT='printf "BOOTSTRAP_INSTALL_DIR=%s\nBOOTSTRAP_ENV_FILE=%s\n" "$INSTALL_DIR" "$ENV_FILE"'

# Record one failed assertion while allowing the other directory cases to run.
fail_case() {
  FAILED=$((FAILED + 1))
  printf 'FAIL %s: %s\n' "$1" "$2" >&2
}

# Inputs reach read through stdin, never by interpolation into shell code.
run_case() {
  local name="$1" choice="$2" expected_relative="$3"
  local case_root="$TEST_ROOT/$name" work fixture_home expected code actual_dir actual_env
  work="$case_root/work"
  fixture_home="$case_root/home"
  expected="$case_root/$expected_relative"
  mkdir -p "$work" "$fixture_home" || exit 2
  if [ "$choice" = '@ABSOLUTE@' ]; then
    choice="$case_root/absolute target"
  fi
  case "$name" in
    symlink)
      mkdir -p "$case_root/real" || exit 2
      ln -s "$case_root/real" "$work/link" || exit 2
      ;;
    preserve)
      mkdir -p "$expected" || exit 2
      printf 'KEEP=fixture\n' > "$expected/.env"
      ;;
    conflict)
      printf 'KEEP=fixture\n' > "$expected"
      ;;
  esac

  if (
    cd "$work" || exit 2
    printf '%s\n' "$choice" | HOME="$fixture_home" "$BASH_BIN" -c \
      "$PRELUDE$INSTALL_BLOCK
$REPORT"
  ) > "$case_root/stdout" 2> "$case_root/stderr"; then
    code=0
  else
    code=$?
  fi

  if [ "$name" = conflict ]; then
    if [ "$code" -eq 0 ] || [ "$(cat "$expected")" != 'KEEP=fixture' ]; then
      fail_case "$name" 'an existing file must reject directory creation without changing it'
      return
    fi
  else
    if [ "$code" -ne 0 ]; then
      fail_case "$name" "bootstrap exited $code: $(cat "$case_root/stderr")"
      return
    fi
    if [ ! -f "$expected/.env" ]; then
      fail_case "$name" 'the selected directory does not contain .env'
      return
    fi
    expected=$(cd "$expected" && pwd -P) || exit 2
    actual_dir=$(sed -n 's/^BOOTSTRAP_INSTALL_DIR=//p' "$case_root/stdout")
    actual_env=$(sed -n 's/^BOOTSTRAP_ENV_FILE=//p' "$case_root/stdout")
    if [ "$actual_dir" != "$expected" ] || [ "$actual_env" != "$expected/.env" ]; then
      fail_case "$name" 'later paths must use the absolute physical directory'
      return
    fi
    if [ "$name" = preserve ] && [ "$(cat "$expected/.env")" != 'KEEP=fixture' ]; then
      fail_case "$name" 'existing .env content changed'
      return
    fi
  fi
  PASSED=$((PASSED + 1))
  printf 'PASS %s\n' "$name"
}

run_case default '' 'home/payram-shopify-connector'
run_case absolute '@ABSOLUTE@' 'absolute target'
run_case relative connector 'work/connector'
run_case dot_relative ./connector 'work/connector'
run_case nested apps/connector 'work/apps/connector'
run_case spaces 'my connector' 'work/my connector'
run_case parent ../connector connector
run_case current . work
run_case trailing connector/ 'work/connector'
run_case tilde '~/connector' 'home/connector'
run_case symlink link real
run_case preserve connector 'work/connector'
run_case conflict occupied 'work/occupied'
run_case literal 'literal $dollar & semi;' 'work/literal $dollar & semi;'

# Capture the production command through shims; never start Docker or Shopify.
run_deploy_case() {
  local name="$1" directory="$2" csv_directory="$3"
  local case_root="$TEST_ROOT/deploy_$name" work expected value index
  local -a captured
  work="$case_root/$directory"
  mkdir -p "$work" "$case_root/bin" || exit 2
  cat > "$case_root/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\0' "$@" > "$CAPTURE_ARGS"
EOF
  cat > "$case_root/bin/script" <<'EOF'
#!/bin/sh
[ "$#" -eq 3 ] && [ "$1" = -qec ] && [ "$3" = /dev/null ] || exit 2
[ "$SHELL" = "$EXPECTED_SHELL" ] || { echo 'Deploy command requires its producing Bash' >&2; exit 2; }
exec "$SHELL" -c "$2"
EOF
  chmod +x "$case_root/bin/docker" "$case_root/bin/script" || exit 2
  if ! (
    cd "$work" || exit 2
    printf '.\n' | LC_ALL=C SHELL=/bin/sh PATH="$case_root/bin:$PATH" \
      CAPTURE_ARGS="$case_root/args" "$BASH_BIN" -c "$PRELUDE
DOCKER_IMAGE=fixture/image:local
SHOPIFY_APP_URL=https://example.invalid
export EXPECTED_SHELL=\"\$BASH\"
die() { printf '%s\\n' \"\$*\" >&2; exit 1; }
$INSTALL_BLOCK
$DEPLOY_BLOCK
$NON_TTY_BLOCK"
  ) > "$case_root/stdout" 2> "$case_root/stderr"; then
    fail_case "deploy_$name" "argument capture failed: $(cat "$case_root/stderr")"
    return
  fi
  if [ ! -f "$case_root/args" ]; then
    fail_case "deploy_$name" 'the deploy command did not reach the Docker shim'
    return
  fi
  captured=()
  while IFS= read -r -d '' value; do
    captured+=("$value")
  done < "$case_root/args"
  value=''
  for ((index = 0; index + 1 < ${#captured[@]}; index++)); do
    if [ "${captured[index]}" = --mount ]; then
      value="${captured[index + 1]}"
    fi
  done
  expected="type=bind,\"source=$case_root/$csv_directory\",target=/workspace"
  if [ "$value" != "$expected" ]; then
    fail_case "deploy_$name" 'workspace mount source did not survive command quoting and CSV encoding'
    return
  fi
  PASSED=$((PASSED + 1))
  printf 'PASS deploy_%s\n' "$name"
}

run_deploy_case ascii plain plain
run_deploy_case unicode 'café' 'café'
run_deploy_case colon 'with:colon' 'with:colon'
run_deploy_case comma 'with,comma' 'with,comma'
run_deploy_case quote 'with"quote' 'with""quote'
run_deploy_case mixed 'café:with,"quote' 'café:with,""quote'

printf '%s passed, %s failed (%s)\n' "$PASSED" "$FAILED" "$BASH_VERSION"
[ "$FAILED" -eq 0 ]
