#!/bin/bash
# Tests for the update path of setup_payram.sh: which version counts as
# "current", how a same-version run recreates the container, and which ports
# a recreated container publishes. They run the real functions against the
# stand-in docker, curl and df in tests/fake-bin, so no container, image or
# network is touched. Run them as a regular user, on every bash that merchants
# use (macOS ships bash 3.2):
#
#   bash tests/setup_payram_update_test.sh
#   BASH_BIN=/bin/bash bash tests/setup_payram_update_test.sh
#   SETUP_SCRIPT=/path/to/older/setup_payram.sh bash tests/setup_payram_update_test.sh
#   KEEP_TEST_DIR=1 bash tests/setup_payram_update_test.sh   # keep each case's output and docker calls
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SETUP_SCRIPT="${SETUP_SCRIPT:-$REPO_DIR/setup_payram.sh}"
BASH_BIN="${BASH_BIN:-bash}"

if [[ "$(id -u)" == "0" ]]; then
  echo "Run these tests as a regular user: as root, setup_payram.sh uses /root instead of the test's home."
  exit 1
fi

WORK_DIR="$(mktemp -d)"
if [[ -n "${KEEP_TEST_DIR:-}" ]]; then
  echo "Keeping test files in $WORK_DIR"
else
  trap 'rm -rf "$WORK_DIR"' EXIT
fi

# setup_payram.sh ends by calling main; a copy without that line can be sourced.
if [[ "$(grep -v '^[[:space:]]*$' "$SETUP_SCRIPT" | tail -1)" != 'main "$@"' ]]; then
  echo "$SETUP_SCRIPT no longer ends with 'main \"\$@\"'; update this test."
  exit 1
fi
LIB="$WORK_DIR/setup_payram_functions.sh"
sed '/^main "\$@"$/d' "$SETUP_SCRIPT" > "$LIB"

PASSED=0
FAILED=0
CASE=""
CASE_DIR=""
STATE=""
HOME_DIR=""
RC=0

# --- scenario setup -----------------------------------------------------------

# new_case NAME: a fresh docker state and home directory for one scenario.
new_case() {
  CASE="$1"
  CASE_DIR="$WORK_DIR/$CASE"
  STATE="$CASE_DIR/docker"
  HOME_DIR="$CASE_DIR/home"
  mkdir -p "$STATE/images" "$HOME_DIR/.payraminfo"
  : > "$STATE/calls"
}

# add_container IMAGE "PORT TOKENS" [stopped]
add_container() {
  local token
  mkdir -p "$STATE/container"
  printf '%s' "$1" > "$STATE/container/image"
  : > "$STATE/container/ports"
  for token in $2; do printf '%s\n' "$token" >> "$STATE/container/ports"; done
  if [[ "${3:-running}" == "running" ]]; then touch "$STATE/container/running"; fi
}

# add_image REF: a local image, named the way tests/fake-bin/docker names it.
add_image() {
  printf 'sha256:%s' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)" \
    > "$STATE/images/$(printf '%s' "$1" | tr '/:@' '___')"
}

# write_config IMAGE_TAG RETAINED_PORTS: config.env as setup_payram.sh writes it.
# RETAINED_PORTS "-" leaves the line out, like an install made before June 2026.
write_config() {
  {
    echo "IMAGE_TAG=\"$1\""
    echo 'NETWORK_TYPE="mainnet"'
    echo 'SERVER="PRODUCTION"'
    echo 'AES_KEY="test-aes-key"'
    if [[ "$2" != "-" ]]; then echo "RETAINED_PORTS=\"$2\""; fi
    echo 'DB_HOST="localhost"'
    echo 'DB_PORT="5432"'
    echo 'DB_NAME="payram"'
    echo 'DB_USER="payram"'
    echo 'DB_PASSWORD="test-db-password"'
    echo 'POSTGRES_SSLMODE="prefer"'
    echo 'SSL_CERT_PATH=""'
    echo 'SSL_MODE=""'
    echo 'OS_FAMILY="debian"'
    echo 'OS_DISTRO="ubuntu"'
    echo "ORIGINAL_USER=\"$(whoami)\""
    echo "PAYRAM_HOME=\"$HOME_DIR\""
  } > "$HOME_DIR/.payraminfo/config.env"
}

# run_setup "CODE" KEYSTROKES [NEW_IMAGE_TAG]: runs CODE in a shell that has
# sourced setup_payram.sh with the same options main runs under. KEYSTROKES
# answer the prompts (printf format: "2\n\n" picks option 2, then Enter).
run_setup() {
  : > "$STATE/calls"
  # shellcheck disable=SC2059
  printf "$2" | FAKE_DOCKER_STATE="$STATE" PATH="$TESTS_DIR/fake-bin:$PATH" "$BASH_BIN" -c '
    set -euo pipefail
    source "$1"
    sleep() { :; }
    LOG_FILE="$2/setup.log"
    ORIGINAL_USER="$(whoami)"
    ORIGINAL_HOME="$3"
    NEW_IMAGE_TAG="$4"
    eval "$5"
  ' run_setup "$LIB" "$CASE_DIR" "$HOME_DIR" "${3:-}" "$1" > "$CASE_DIR/out" 2>&1
  RC=$?
}

run_update() { run_setup "update_payram_container" "$@"; }

# --- assertions ---------------------------------------------------------------

pass() { PASSED=$((PASSED + 1)); }
fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL [$CASE] $*"
}

expect_rc() {
  if [[ "$RC" == "$1" ]]; then pass; else fail "exit status $RC, expected $1"; fi
}
expect_called() {
  if grep -q -E -- "$1" "$STATE/calls"; then pass; else fail "no call matching: $1"; fi
}
expect_not_called() {
  if grep -q -E -- "$1" "$STATE/calls"; then
    fail "unexpected call: $(grep -E -- "$1" "$STATE/calls" | head -1 | cut -c1-160)"
  else
    pass
  fi
}
# expect_order A B: the first call matching A comes before the first matching B.
expect_order() {
  local a b
  a="$(grep -n -E -- "$1" "$STATE/calls" | head -1 | cut -d: -f1)"
  b="$(grep -n -E -- "$2" "$STATE/calls" | head -1 | cut -d: -f1)"
  if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then pass; else fail "expected '$1' (line ${a:-none}) before '$2' (line ${b:-none})"; fi
}
expect_output() {
  if grep -q -F -- "$1" "$CASE_DIR/out"; then pass; else fail "output lacks: $1"; fi
}
expect_no_output() {
  if grep -q -F -- "$1" "$CASE_DIR/out"; then fail "output has: $1"; else pass; fi
}
# expect_container IMAGE running|stopped, or expect_container none
expect_container() {
  if [[ "$1" == "none" ]]; then
    if [[ -d "$STATE/container" ]]; then fail "a container exists"; else pass; fi
    return
  fi
  local image="" status="none"
  if [[ -d "$STATE/container" ]]; then
    image="$(cat "$STATE/container/image")"
    status="stopped"
    if [[ -f "$STATE/container/running" ]]; then status="running"; fi
  fi
  if [[ "$image" == "$1" && "$status" == "$2" ]]; then pass; else fail "container is '$image' ($status), expected '$1' ($2)"; fi
}
# expect_ports "TOKENS": exactly these published ports, in any order.
expect_ports() {
  local actual expected
  actual="$(sort "$STATE/container/ports" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  expected="$(printf '%s\n' $1 | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ *$//')"
  if [[ "$actual" == "$expected" ]]; then pass; else fail "published ports '$actual', expected '$expected'"; fi
}
expect_image() {
  if [[ -f "$STATE/images/$(printf '%s' "$1" | tr '/:@' '___')" ]]; then pass; else fail "image $1 is not local"; fi
}
expect_no_image() {
  if [[ -f "$STATE/images/$(printf '%s' "$1" | tr '/:@' '___')" ]]; then fail "image $1 is still local"; else pass; fi
}
# expect_config KEY VALUE: the value saved in config.env.
expect_config() {
  local actual
  actual="$(set +u; source "$HOME_DIR/.payraminfo/config.env"; eval "printf '%s' \"\${$1-<unset>}\"")"
  if [[ "$actual" == "$2" ]]; then pass; else fail "config.env $1='$actual', expected '$2'"; fi
}

# expect_config_ports "TOKENS": RETAINED_PORTS in config.env holds exactly these, in any order.
expect_config_ports() {
  local actual expected
  actual="$(set +u; source "$HOME_DIR/.payraminfo/config.env"; printf '%s\n' ${RETAINED_PORTS-<unset>} | sort | tr '\n' ' ' | sed 's/ *$//')"
  expected="$(printf '%s\n' $1 | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ *$//')"
  if [[ "$actual" == "$expected" ]]; then pass; else fail "config.env RETAINED_PORTS '$actual', expected '$expected'"; fi
}

# --- scenarios ----------------------------------------------------------------
# Image references: the container is created from payramapp/payram:<tag>.
OLD="payramapp/payram:3.8.0"
CURRENT="payramapp/payram:3.10.0"
NEXT="payramapp/payram:3.11.0"
LEGACY_PORTS="5432:5432 80:80 443:443 8080:8080 8443:8443"
WEB_PORTS="80:80 443:443 8080:8080 8443:8443"

# Audit F1. Installed with 3.8.0, updated to 3.10.0 from the dashboard (which
# never writes config.env), still publishing 5432. "Keep current version"
# must keep 3.10.0, not start 3.8.0 on a database 3.10.0 already migrated.
test_keep_version_uses_running_tag() {
  new_case keep-version-uses-running-tag
  write_config 3.8.0 -
  add_container "$CURRENT" "$LEGACY_PORTS"
  add_image "$CURRENT"
  run_update "2\n\n" 3.11.0
  expect_rc 0
  expect_output "Keep current version: 3.10.0"
  expect_output "config.env recorded PayRam 3.8.0"
  expect_container "$CURRENT" running
  expect_ports "$WEB_PORTS"
  expect_config IMAGE_TAG 3.10.0
  expect_config_ports "$WEB_PORTS"
  expect_not_called "^docker (pull|rmi)"
  expect_not_called "3\.8\.0"
  expect_not_called "run-implicit-pull"
}

# The real version is saved before anything else happens, even on cancel, so
# a later run that finds no container still knows which version PayRam ran.
# An install made before June 2026 has no RETAINED_PORTS yet: the save must
# record the container's real ports, not invent "80:80".
test_cancel_saves_running_tag() {
  new_case cancel-saves-running-tag
  write_config 3.8.0 -
  add_container "$CURRENT" "$LEGACY_PORTS"
  add_image "$CURRENT"
  run_update "3\n" 3.11.0
  expect_rc 0
  expect_config IMAGE_TAG 3.10.0
  expect_config_ports "$WEB_PORTS"
  expect_container "$CURRENT" running
  expect_ports "$LEGACY_PORTS"
  expect_not_called "^docker (stop|rm|rmi|pull|run|restart)"
}

# A digest-only image reference has no version to read: config.env stays the
# source of truth and the merchant is told why.
test_digest_reference_falls_back_to_config() {
  new_case digest-reference-falls-back
  write_config 3.10.0 "$WEB_PORTS"
  add_container "payramapp/payram@sha256:0123456789abcdef" "$WEB_PORTS"
  run_update "3\n" 3.11.0
  expect_rc 0
  expect_output "Keep current version: 3.10.0"
  expect_output "has no payramapp/payram version tag"
  expect_config IMAGE_TAG 3.10.0
}

# The version is read only from a payramapp/payram reference, in every form
# docker records it; anything else falls back to config.env.
test_image_tag_reference_forms() {
  local ref expected actual
  new_case image-tag-reference-forms
  for ref in \
    "payramapp/payram:3.10.0=3.10.0" \
    "payramapp/payram:3.10.0-arm64=3.10.0-arm64" \
    "docker.io/payramapp/payram:3.10.0=3.10.0" \
    "payramapp/payram:3.10.0@sha256:0123=3.10.0" \
    "payramapp/payram@sha256:0123=" \
    "payramapp/payram=" \
    "sha256:4b1e0c7d9a2f=" \
    "localhost:5000/payram:3.10.0=" \
    "payram-e2e/payram:99.0.1-arm64=" \
    'payramapp/payram:3.10.0$(id)='; do
    expected="${ref##*=}"
    ref="${ref%=*}"
    run_setup "payram_image_tag '$ref'" ""
    actual="$(cat "$CASE_DIR/out")"
    if [[ "$RC" == "0" && "$actual" == "$expected" ]]; then pass; else fail "tag of '$ref' read as '$actual' (exit $RC), expected '$expected'"; fi
  done
  add_container "$CURRENT" ""
  run_setup "detect_container_image" ""
  if [[ "$RC" == "0" && "$(cat "$CASE_DIR/out")" == "$CURRENT" ]]; then pass; else fail "detect_container_image gave '$(cat "$CASE_DIR/out")'"; fi
  rm -rf "$STATE/container"
  run_setup "detect_container_image" ""
  if [[ "$RC" == "0" && -z "$(cat "$CASE_DIR/out")" ]]; then pass; else fail "no container should give no image (exit $RC)"; fi
}

# Audit F2. Same version, image on disk, 5432 published: recreate from the
# local image. Nothing is downloaded and no image is deleted.
test_same_version_recreates_from_local_image() {
  new_case same-version-local-image
  write_config 3.10.0 -
  add_container "$CURRENT" "$LEGACY_PORTS"
  add_image "$CURRENT"
  run_update "2\n\n" 3.11.0
  expect_rc 0
  expect_container "$CURRENT" running
  expect_ports "$WEB_PORTS"
  expect_image "$CURRENT"
  expect_not_called "^docker (pull|rmi)"
  expect_not_called "run-implicit-pull"
}

# Same version, image missing: download it while the old container still runs.
test_same_version_pulls_missing_image_first() {
  new_case same-version-pulls-first
  write_config 3.10.0 -
  add_container "$CURRENT" "$LEGACY_PORTS"
  run_update "2\n\n" 3.11.0
  expect_rc 0
  expect_order "^docker pull $CURRENT" "^docker stop payram"
  expect_order "^docker pull $CURRENT" "^docker rm"
  expect_container "$CURRENT" running
  expect_ports "$WEB_PORTS"
  expect_not_called "^docker rmi"
}

# The download fails (Docker Hub rate limit): stop there, old container untouched.
test_same_version_pull_failure_keeps_container() {
  new_case same-version-pull-failure
  write_config 3.10.0 -
  add_container "$CURRENT" "$LEGACY_PORTS"
  FAKE_PULL_FAIL=1 run_update "2\n\n" 3.11.0
  expect_rc 1
  expect_container "$CURRENT" running
  expect_ports "$LEGACY_PORTS"
  expect_not_called "^docker (stop|rm|rmi|run)"
  expect_output "toomanyrequests"
  expect_output "container is untouched"
  expect_no_output "updated successfully"
}

# A re-run after an earlier failed update left no container: the same-version
# choice starts PayRam from the local image instead of restarting nothing.
test_rerun_without_container_starts_local_image() {
  new_case rerun-no-container-local-image
  write_config 3.10.0 "$WEB_PORTS"
  add_image "$CURRENT"
  run_update "y\n2\n\n" 3.11.0
  expect_rc 0
  expect_output "no PayRam container"
  expect_container "$CURRENT" running
  expect_ports "$WEB_PORTS"
  expect_not_called "^docker (restart|pull|rmi)"
  expect_not_called "run-implicit-pull"
}

# Same, but the image is gone too: download it, then start it.
test_rerun_without_container_or_image_pulls() {
  new_case rerun-no-container-no-image
  write_config 3.10.0 "$WEB_PORTS"
  run_update "y\n2\n\n" 3.11.0
  expect_rc 0
  expect_order "^docker pull $CURRENT" "^docker run"
  expect_container "$CURRENT" running
  expect_not_called "^docker restart"
}

# Same, and the download fails: report failure, never success.
test_rerun_without_container_pull_failure() {
  new_case rerun-no-container-pull-failure
  write_config 3.10.0 "$WEB_PORTS"
  FAKE_PULL_FAIL=1 run_update "y\n2\n\n" 3.11.0
  expect_rc 1
  expect_container none
  expect_not_called "^docker (restart|run)"
  expect_no_output "restarted on"
  expect_no_output "updated successfully"
}

# Same version without 5432: a plain restart, as before.
test_same_version_restart() {
  new_case same-version-restart
  write_config 3.10.0 "$WEB_PORTS"
  add_container "$CURRENT" "$WEB_PORTS"
  add_image "$CURRENT"
  run_update "2\n\n" 3.11.0
  expect_rc 0
  expect_called "^docker restart payram"
  expect_not_called "^docker (stop|rm|rmi|pull|run)"
  expect_output "PayRam restarted on 3.10.0"
}

# Same version, container stopped: it is started again, nothing else changes.
test_same_version_starts_stopped_container() {
  new_case same-version-stopped
  write_config 3.10.0 "$WEB_PORTS"
  add_container "$CURRENT" "$WEB_PORTS" stopped
  add_image "$CURRENT"
  run_update "2\n\n" 3.11.0
  expect_rc 0
  expect_called "^docker start payram"
  expect_not_called "^docker (stop|rm|rmi|pull|run)"
  expect_container "$CURRENT" running
}

# The restart fails: no success message.
test_same_version_restart_failure() {
  new_case same-version-restart-failure
  write_config 3.10.0 "$WEB_PORTS"
  add_container "$CURRENT" "$WEB_PORTS"
  FAKE_RESTART_FAIL=1 run_update "2\n\n" 3.11.0
  expect_rc 1
  expect_no_output "PayRam restarted on"
}

# Same-version recreate where the new container cannot start (port taken).
test_same_version_run_failure_reports_failure() {
  new_case same-version-run-failure
  write_config 3.10.0 -
  add_container "$CURRENT" "$LEGACY_PORTS"
  add_image "$CURRENT"
  FAKE_RUN_FAIL=1 run_update "2\n\n" 3.11.0
  expect_rc 1
  expect_output "PayRam container failed to start"
  expect_no_output "updated successfully"
}

# A version update downloads the new image before touching the old container,
# then removes the images it no longer needs.
test_version_update_pulls_first_then_cleans() {
  new_case version-update
  write_config 3.10.0 -
  add_container "$CURRENT" "$LEGACY_PORTS"
  add_image "$CURRENT"
  add_image "$OLD"
  run_update "1\n\n" 3.11.0
  expect_rc 0
  expect_order "^docker pull $NEXT" "^docker stop payram"
  expect_container "$NEXT" running
  expect_ports "$WEB_PORTS"
  expect_config IMAGE_TAG 3.11.0
  expect_image "$NEXT"
  expect_no_image "$CURRENT"
  expect_no_image "$OLD"
}

# A version update whose download fails leaves the old version running.
test_version_update_pull_failure_keeps_container() {
  new_case version-update-pull-failure
  write_config 3.10.0 "$WEB_PORTS"
  add_container "$CURRENT" "$WEB_PORTS"
  add_image "$CURRENT"
  FAKE_PULL_FAIL=1 run_update "1\n\n" 3.11.0
  expect_rc 1
  expect_container "$CURRENT" running
  expect_image "$CURRENT"
  expect_config IMAGE_TAG 3.10.0
  expect_not_called "^docker (stop|rm|rmi|run)"
}

# Audit F4. A container whose only published port was the database port is
# recreated publishing nothing, and stays that way on the next update.
test_only_database_port_publishes_nothing() {
  new_case only-database-port
  write_config 3.10.0 -
  add_container "$CURRENT" "127.0.0.1:5432:5432"
  add_image "$CURRENT"
  run_update "2\n\n" 3.11.0
  expect_rc 0
  expect_container "$CURRENT" running
  expect_ports ""
  expect_not_called "^docker run .*--publish"
  expect_output "Publishing no ports"
  expect_config RETAINED_PORTS ""
  # The next update finds no published port and an empty saved list.
  run_update "2\n\n" 3.11.0
  expect_rc 0
  expect_not_called "^docker run .*--publish"
  expect_ports ""
}

# The historical port set is still the fallback when nothing is known at all.
test_legacy_fallback_when_nothing_is_known() {
  new_case legacy-fallback
  write_config 3.10.0 -
  add_image "$CURRENT"
  run_update "y\n2\n\n" 3.11.0
  expect_rc 0
  expect_ports "$WEB_PORTS"
  expect_config_ports "$WEB_PORTS"
}

# The SSL wizard recreates through reconfigure_container: an empty port list
# must not crash bash 3.2 (an empty array under set -u) after the old
# container is gone.
test_reconfigure_with_no_ports() {
  new_case reconfigure-no-ports
  write_config 3.10.0 ""
  add_container "$CURRENT" ""
  add_image "$CURRENT"
  run_setup "get_payram_directories; load_configuration; reconfigure_container" ""
  expect_rc 0
  expect_container "$CURRENT" running
  expect_ports ""
}

# A fresh install still publishes the install-time mapping.
test_fresh_install_publishes_primary_mapping() {
  new_case fresh-install
  write_config 3.10.0 -
  run_setup "get_payram_directories; load_configuration; PRIMARY_PORT_MAPPING='80:80 443:443'; deploy_payram_container" ""
  expect_rc 0
  expect_container "$CURRENT" running
  expect_ports "80:80 443:443"
  expect_order "^docker pull $CURRENT" "^docker run"
}

TESTS=$(grep -E '^test_[a-z0-9_]+\(\)' "$0" | sed 's/().*//')
echo "Running setup_payram.sh update tests with $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"')"
for t in $TESTS; do "$t"; done
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
