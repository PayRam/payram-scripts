#!/usr/bin/env bash
# Tests setup_payram_agents.sh sign-in (signin_with_password) against a fake
# PayRam: a member without two-factor sign-in is signed in as before, and a
# two-factor reply, a reply without tokens or a refused password never saves
# tokens or prints "Signed in.". No network is touched: curl in this test
# answers from files. Run it as a regular user, on bash 3.2 and 5:
#
#   bash tests/setup_payram_agents_signin_test.sh
#   BASH_BIN=/bin/bash bash tests/setup_payram_agents_signin_test.sh
#
# The no-terminal case runs only where /dev/tty can't be opened (CI, a piped
# run); in an interactive terminal it is skipped so the test never prompts.
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
AGENTS_SCRIPT="${AGENTS_SCRIPT:-$REPO_DIR/setup_payram_agents.sh}"
BASH_BIN="${BASH_BIN:-bash}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# setup_payram_agents.sh ends by calling main; a copy without that line can be sourced.
if [[ "$(grep -v '^[[:space:]]*$' "$AGENTS_SCRIPT" | tail -1)" != 'main "$@"' ]]; then
  echo "$AGENTS_SCRIPT no longer ends with 'main \"\$@\"'; update this test."
  exit 1
fi
LIB="$WORK_DIR/setup_payram_agents_functions.sh"
sed '/^main "\$@"$/d' "$AGENTS_SCRIPT" > "$LIB"

# curl answers like `curl -s -w "\n%{http_code}"`: the body, a newline, the
# status. The reply for a path is $WORK_DIR/<case>/reply-<name>: first line
# the status, the rest the body. Every call is recorded.
FAKE_BIN="$WORK_DIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do [[ "$arg" == http* ]] && url="$arg"; done
echo "$url" >> "$CASE_DIR/calls"
echo "$*" >> "$CASE_DIR/args"
# A change behind the app code: taken with the grant g-1, refused without.
if [[ "$url" == */api/v1/wallets/hot ]]; then
  if [[ "$*" == *"Two-Factor-Grant: g-1"* ]]; then printf '{"saved":true}\n200'; else printf '{"error":{"code":"TWO_FACTOR_CODE_REQUIRED"}}\n403'; fi
  exit 0
fi
case "$url" in
  */api/v1/signin/two-factor) reply="$CASE_DIR/reply-two-factor" ;;
  */api/v1/signin) reply="$CASE_DIR/reply-signin" ;;
  *) reply="" ;;
esac
if [[ -z "$reply" || ! -f "$reply" ]]; then printf '{}\n404'; exit 0; fi
printf '%s\n%s' "$(sed '1d' "$reply")" "$(head -1 "$reply")"
EOF
chmod +x "$FAKE_BIN/curl"

PASSED=0
FAILED=0
CASE=""
CASE_DIR=""
RC=0
pass() { PASSED=$((PASSED + 1)); }
fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL [$CASE] $*"
}

new_case() {
  CASE="$1"
  CASE_DIR="$WORK_DIR/$CASE"
  mkdir -p "$CASE_DIR"
  : > "$CASE_DIR/calls"
}

# reply NAME STATUS BODY: what the fake PayRam answers on that path.
reply() { printf '%s\n%s\n' "$2" "$3" > "$CASE_DIR/reply-$1"; }

# run_signin: signs in as merchant@example.com in a shell that sourced the
# script (so set -euo pipefail applies, as in a real run); sets RC.
run_signin() {
  RC=0
  PATH="$FAKE_BIN:$PATH" CASE_DIR="$CASE_DIR" "$BASH_BIN" -c '
    source "$1"
    PAYRAM_API_URL="http://payram.test"
    TOKEN_FILE="$2/tokens.env"
    troubleshoot() { :; }
    signin_with_password "merchant@example.com" "correct horse"
  ' run_signin "$LIB" "$CASE_DIR" > "$CASE_DIR/out" 2>&1 < /dev/null || RC=$?
}

out_has() { grep -qF -- "$1" "$CASE_DIR/out"; }
no_tokens_saved() { [[ ! -e "$CASE_DIR/tokens.env" ]]; }

# --- Without two-factor sign-in: signed in, tokens saved ---
new_case no_two_factor
reply signin 200 '{"accessToken":"acc-1","refreshToken":"ref-1","customer_id":"cust-1","email":"merchant@example.com"}'
run_signin
[[ "$RC" -eq 0 ]] && pass || fail "exit $RC, want 0: $(cat "$CASE_DIR/out")"
out_has "Signed in." && pass || fail "no 'Signed in.'"
grep -qF 'ACCESS_TOKEN="acc-1"' "$CASE_DIR/tokens.env" 2>/dev/null && pass || fail "access token not saved"
grep -qF 'REFRESH_TOKEN="ref-1"' "$CASE_DIR/tokens.env" 2>/dev/null && pass || fail "refresh token not saved"
grep -q 'two-factor' "$CASE_DIR/calls" && fail "called /signin/two-factor without being asked" || pass

# --- Two-factor sign-in on, no terminal to ask on: says how, saves nothing ---
if (exec </dev/tty) 2>/dev/null; then
  echo "SKIP [two_factor_no_terminal]: /dev/tty is available here; run without a terminal (CI) to cover it"
else
  new_case two_factor_no_terminal
  reply signin 200 '{"status":"two_factor_required","twoFactorToken":"step-1"}'
  run_signin
  [[ "$RC" -ne 0 ]] && pass || fail "exit 0, want an error"
  out_has "two-factor sign-in on" && pass || fail "no two-factor message: $(cat "$CASE_DIR/out")"
  out_has "signin" && pass || fail "does not say how to sign in"
  out_has "Signed in." && fail "printed 'Signed in.' without tokens" || pass
  no_tokens_saved && pass || fail "saved tokens: $(cat "$CASE_DIR/tokens.env")"
  grep -q 'two-factor' "$CASE_DIR/calls" && fail "sent a code it never asked for" || pass
fi

# --- A 200 without tokens: an error, not a silent exit or empty tokens ---
new_case reply_without_tokens
reply signin 200 '{"status":"ok"}'
run_signin
[[ "$RC" -ne 0 ]] && pass || fail "exit 0, want an error"
out_has "Sign-in returned no tokens" && pass || fail "no message (silent exit under set -e?): $(cat "$CASE_DIR/out")"
no_tokens_saved && pass || fail "saved empty tokens"

# --- Wrong password: the server's answer is shown, nothing saved ---
new_case wrong_password
reply signin 401 '{"message":"invalid email or password"}'
run_signin
[[ "$RC" -ne 0 ]] && pass || fail "exit 0, want an error"
out_has "Sign-in failed (HTTP 401)" && pass || fail "no failure message: $(cat "$CASE_DIR/out")"
no_tokens_saved && pass || fail "saved tokens after a refused password"

# run_api METHOD PATH: one api call with saved tokens; output in out, sets RC.
run_api() {
  RC=0
  printf 'ACCESS_TOKEN="acc-1"\n' > "$CASE_DIR/tokens.env"
  PATH="$FAKE_BIN:$PATH" CASE_DIR="$CASE_DIR" "$BASH_BIN" -c '
    source "$1"
    PAYRAM_API_URL="http://payram.test"
    TOKEN_FILE="$2/tokens.env"
    api "$3" "$4" "{}" true
  ' run_api "$LIB" "$CASE_DIR" "$1" "$2" > "$CASE_DIR/out" 2>&1 < /dev/null || RC=$?
}

# --- A change behind the app code goes through on the saved grant ---
new_case grant_sent
printf 'g-1\n' > "$CASE_DIR/two-factor-grant.env"
run_api POST /api/v1/wallets/hot
[[ "$RC" -eq 0 ]] && pass || fail "exit $RC"
out_has '"saved":true' && pass || fail "not taken with the grant: $(cat "$CASE_DIR/out")"
grep -q 'Authorization: Bearer acc-1' "$CASE_DIR/args" && pass || fail "no session sent"

# --- Without a terminal, a refusal goes to the caller and a stale grant is dropped ---
if (exec </dev/tty) 2>/dev/null; then
  echo "SKIP [code_refused_no_terminal]: /dev/tty is available here; run without a terminal (CI) to cover it"
else
  new_case code_refused_no_terminal
  printf 'g-old\n' > "$CASE_DIR/two-factor-grant.env"
  run_api POST /api/v1/wallets/hot
  [[ "$RC" -eq 0 ]] && pass || fail "exit $RC"
  out_has 'TWO_FACTOR_CODE_REQUIRED' && pass || fail "refusal not passed on: $(cat "$CASE_DIR/out")"
  [[ ! -e "$CASE_DIR/two-factor-grant.env" ]] && pass || fail "stale grant kept"
  [[ "$(wc -l < "$CASE_DIR/calls" | tr -d ' ')" == "1" ]] && pass || fail "sent again without a code"
fi

# --- A call without a session is sent as before ---
new_case no_session
RC=0
PATH="$FAKE_BIN:$PATH" CASE_DIR="$CASE_DIR" "$BASH_BIN" -c '
  source "$1"
  PAYRAM_API_URL="http://payram.test"
  TOKEN_FILE="$2/tokens.env"
  api POST /api/v1/signin "{}" false
' run_api "$LIB" "$CASE_DIR" > "$CASE_DIR/out" 2>&1 < /dev/null || RC=$?
grep -q 'Authorization' "$CASE_DIR/args" && fail "sent a session it was told not to" || pass

echo "signin tests: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
