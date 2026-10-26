#!/bin/bash
# Tests that setup_payram_agents.sh never downloads or starts the retired
# analytics MCP server, and that every run stops one an earlier version
# started (and only that one) and deletes its files. Uses throwaway looping
# scripts as processes; no network is touched (curl and wget in tests/fake-bin fail and
# record each call). Run it as a regular user, on bash 3.2 and 5:
#
#   bash tests/setup_payram_agents_mcp_test.sh
#   BASH_BIN=/bin/bash bash tests/setup_payram_agents_mcp_test.sh
#   AGENTS_SCRIPT=/path/to/older/setup_payram_agents.sh bash tests/setup_payram_agents_mcp_test.sh
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
AGENTS_SCRIPT="${AGENTS_SCRIPT:-$REPO_DIR/setup_payram_agents.sh}"
BASH_BIN="${BASH_BIN:-bash}"
WORK_DIR="$(mktemp -d)"
STARTED_PIDS=""
cleanup() {
  local pid
  for pid in $STARTED_PIDS; do kill -9 "$pid" 2>/dev/null || true; done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# setup_payram_agents.sh ends by calling main; a copy without that line can be sourced.
if [[ "$(grep -v '^[[:space:]]*$' "$AGENTS_SCRIPT" | tail -1)" != 'main "$@"' ]]; then
  echo "$AGENTS_SCRIPT no longer ends with 'main \"\$@\"'; update this test."
  exit 1
fi
LIB="$WORK_DIR/setup_payram_agents_functions.sh"
sed '/^main "\$@"$/d' "$AGENTS_SCRIPT" > "$LIB"

FAKE_BIN="$WORK_DIR/bin"
mkdir -p "$FAKE_BIN"
for tool in curl wget; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/network-calls"\nexit 22\n' "$tool" "$WORK_DIR" > "$FAKE_BIN/$tool"
  chmod +x "$FAKE_BIN/$tool"
done

PASSED=0
FAILED=0
CASE=""
INFO_DIR=""
RC=0
pass() { PASSED=$((PASSED + 1)); }
fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL [$CASE] $*"
}

new_case() {
  CASE="$1"
  INFO_DIR="$WORK_DIR/$CASE/.payraminfo"
  mkdir -p "$INFO_DIR"
}

# start_process PATH: starts a long-running script saved at PATH, so its
# command line holds PATH (like the real mcp.bin), and sets STARTED_PID.
STARTED_PID=""
start_process() {
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "$1"
  chmod +x "$1"
  "$1" >/dev/null 2>&1 &
  STARTED_PID="$!"
  disown "$STARTED_PID" 2>/dev/null || true
  STARTED_PIDS="$STARTED_PIDS $STARTED_PID"
  sleep 1
}

# run_agents "CODE": runs CODE in a shell that sourced setup_payram_agents.sh.
run_agents() {
  PATH="$FAKE_BIN:$PATH" PAYRAM_INFO_DIR="$INFO_DIR" "$BASH_BIN" -c '
    set -euo pipefail
    source "$1"
    eval "$2"
  ' run_agents "$LIB" "$1" > "$WORK_DIR/$CASE.out" 2>&1
  RC=$?
}

is_alive() { kill -0 "$1" 2>/dev/null; }

test_stops_own_mcp_server_and_removes_files() {
  local pid
  new_case stops-own-server
  start_process "$INFO_DIR/mcp.bin"
  pid="$STARTED_PID"
  echo "$pid" > "$INFO_DIR/mcp-server.pid"
  echo "sha" > "$INFO_DIR/mcp.bin.sha256"
  echo "v1.1.0" > "$INFO_DIR/mcp.bin.version"
  run_agents "remove_analytics_mcp_server"
  if [[ "$RC" == "0" ]]; then pass; else fail "exit status $RC"; fi
  if is_alive "$pid"; then fail "the analytics MCP server (PID $pid) is still running"; else pass; fi
  local f
  for f in mcp.bin mcp.bin.sha256 mcp.bin.version mcp-server.pid; do
    if [[ -e "$INFO_DIR/$f" ]]; then fail "$f was not removed"; else pass; fi
  done
}

test_leaves_unrelated_process_alone() {
  local pid
  new_case unrelated-process
  start_process "$WORK_DIR/$CASE/other/sleep"
  pid="$STARTED_PID"
  echo "$pid" > "$INFO_DIR/mcp-server.pid"
  run_agents "remove_analytics_mcp_server"
  if [[ "$RC" == "0" ]]; then pass; else fail "exit status $RC"; fi
  if is_alive "$pid"; then pass; else fail "an unrelated process (PID $pid) was killed"; fi
  if [[ -e "$INFO_DIR/mcp-server.pid" ]]; then fail "the stale PID file was not removed"; else pass; fi
  kill -9 "$pid" 2>/dev/null || true
}

test_nothing_to_clean_is_quiet() {
  new_case nothing-to-clean
  echo "not-a-pid" > "$INFO_DIR/mcp-server.pid"
  run_agents "remove_analytics_mcp_server"
  if [[ "$RC" == "0" ]]; then pass; else fail "exit status $RC"; fi
  run_agents "remove_analytics_mcp_server"
  if [[ "$RC" == "0" && ! -s "$WORK_DIR/$CASE.out" ]]; then pass; else fail "a second run printed: $(cat "$WORK_DIR/$CASE.out")"; fi
}

test_start_command_only_reports_retirement() {
  new_case start-command
  : > "$WORK_DIR/network-calls"
  run_agents "cmd_start_mcp_server"
  if [[ "$RC" == "0" ]]; then pass; else fail "exit status $RC"; fi
  if grep -q "retired" "$WORK_DIR/$CASE.out"; then pass; else fail "no retirement notice: $(cat "$WORK_DIR/$CASE.out")"; fi
  if [[ -s "$WORK_DIR/network-calls" ]]; then fail "it reached the network: $(head -1 "$WORK_DIR/network-calls")"; else pass; fi
  if [[ -e "$INFO_DIR/mcp.bin" ]]; then fail "mcp.bin was created"; else pass; fi
}

# The retired options still parse, so existing commands keep working.
test_retired_options_are_accepted() {
  local opt
  new_case retired-options
  for opt in --skip-mcp-server --mcp-port=3333; do
    run_agents "flow_main $opt --help"
    if [[ "$RC" == "0" ]]; then pass; else fail "$opt was rejected: $(tail -1 "$WORK_DIR/$CASE.out")"; fi
  done
}

# Only the start-mcp-server command reaches cmd_start_mcp_server: the menu,
# run and the one-step flow do not.
test_no_flow_starts_the_server() {
  local callers
  CASE="callers"
  callers="$(grep -n 'cmd_start_mcp_server' "$AGENTS_SCRIPT" | grep -v -E 'cmd_start_mcp_server\(\) \{|start-mcp-server\) cmd_start_mcp_server ;;|^[0-9]+:[[:space:]]*#')"
  if [[ -z "$callers" ]]; then pass; else fail "cmd_start_mcp_server is still called from: $callers"; fi
  if grep -q -E 'analytics-mcp-server/releases|nohup .*mcp' "$AGENTS_SCRIPT"; then fail "the script still downloads or launches the analytics MCP server"; else pass; fi
}

TESTS=$(grep -E '^test_[a-z0-9_]+\(\)' "$0" | sed 's/().*//')
echo "Running setup_payram_agents.sh MCP tests with $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"')"
for t in $TESTS; do "$t"; done
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
