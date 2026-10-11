"""Local regression checks: real CLI functions, dummy credentials, mocked curl.

Run: python3 -m unittest discover -s tests -v
PAYRAM_AGENT_SCRIPT can point to an upstream script to verify the failures.
The installer, gateway, Docker and wallet code are never started.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SCRIPT = Path(os.environ.get(
    "PAYRAM_AGENT_SCRIPT",
    Path(__file__).resolve().parents[1] / "setup_payram_agents.sh",
))
SOURCE = SCRIPT.read_text()
FUNCTIONS = []
for name in (
    "json_string", "auth_request_json", "save_root_credentials",
    "password_meets_complexity", "generate_compliant_password",
    "load_or_create_root_credentials", "cmd_setup", "cmd_signin", "cmd_run",
    "parse_response",
):
    match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", SOURCE, re.M | re.S)
    if match:
        FUNCTIONS.append(match.group())
    elif name not in {"json_string", "auth_request_json", "save_root_credentials"}:
        raise RuntimeError(f"Missing CLI function: {name}")

HARNESS = "\n".join(FUNCTIONS) + r'''
set -euo pipefail
umask 000
PAYRAM_API_URL=https://gateway.invalid
CREDENTIALS_FILE="$TEST_DIR/root-credentials.env"
parse_auth_tokens() { :; }
save_tokens() { :; }
load_tokens() { :; }
troubleshoot() { :; }
ensure_setup_mode() { return 0; }
# cmd_run stops before payment/project selection once auth has been tested.
ensure_token() { return 1; }
api() { printf '{}\n201'; }
curl() {
    local arg payload='' next_is_data=0 request_type=''
    for arg in "$@"; do
        if [[ "$next_is_data" == 1 ]]; then
            payload="$arg"
            next_is_data=0
        elif [[ "$arg" == '-d' ]]; then
            next_is_data=1
        elif [[ "$arg" == */api/v1/signin ]]; then
            request_type=signin
        elif [[ "$arg" == */api/v1/signup ]]; then
            request_type=signup
        elif [[ "$arg" == */api/v1/member/root/exist ]]; then
            printf '{"exist":%s}\n200' "$TEST_ROOT_EXISTS"
            return 0
        fi
    done
    printf '%s' "$payload" > "$TEST_DIR/request.json"
    printf '%s' "$payload" > "$TEST_DIR/request-$request_type.json"
    printf '{}\n200'
}
'''

PASSWORDS = {
    "ordinary": "Aa1!ordinary",
    "double_quote": 'Aa1!quoted"tail',
    "backslash_sequence": r"Aa1!literal\ttail",
    "trailing_backslash": "Aa1!tail\\",
    "tab": "Aa1!tab\ttail",
    "newlines": "Aa1!line\nend\n",
    "all_controls": "Aa1!" + "".join(chr(n) for n in range(1, 32)),
    "unicode": "Aa1!café-雪-🔒",
    "dollar_variable": "Aa1!$HOSTNAME",
    "double_dollar": "Aa1!$$tail",
    "command_substitution": "Aa1!$(touch command-executed)",
    "backticks": "Aa1!`touch command-executed`",
}


class CredentialTests(unittest.TestCase):
    def run_cli(self, command, password, *, email="dummy@example.invalid",
                root_exists=False, locale="C.UTF-8", stdin="\n\n\n"):
        with tempfile.TemporaryDirectory() as directory:
            env = {
                "PATH": os.environ["PATH"],
                "LC_ALL": locale,
                "PAYRAM_EMAIL": email,
                "PAYRAM_PASSWORD": password,
                "TEST_DIR": directory,
                "TEST_ROOT_EXISTS": "true" if root_exists else "false",
            }
            result = subprocess.run(
                ["bash", "--noprofile", "--norc", "-c", HARNESS + "\n" + command],
                input=stdin, text=True, env=env, cwd=directory,
                capture_output=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((Path(directory) / "command-executed").exists())
            request = Path(directory) / "request.json"
            decoded = json.loads(request.read_text()) if request.exists() else None
            for captured in Path(directory).glob("request-*.json"):
                self.assertEqual(json.loads(captured.read_text()), decoded)
            credentials = Path(directory) / "root-credentials.env"
            if credentials.exists():
                self.assertEqual(credentials.stat().st_mode & 0o777, 0o600)
            return decoded

    def assert_credentials(self, command, *, root_exists=False,
                           expected_email="dummy@example.invalid"):
        for name, password in PASSWORDS.items():
            for locale in ("C", "C.UTF-8"):
                with self.subTest(password=name, locale=locale):
                    actual = self.run_cli(command, password,
                                          root_exists=root_exists, locale=locale)
                    self.assertEqual(actual, {"email": expected_email,
                                              "password": password})

    def test_headless_signin(self):
        self.assert_credentials("cmd_signin")

    def test_headless_signup(self):
        self.assert_credentials("cmd_setup")

    def test_interactive_signin(self):
        self.assert_credentials("cmd_run || test $? -eq 1", root_exists=True)

    def test_interactive_signup_and_saved_file(self):
        self.assert_credentials('''
cmd_run || test $? -eq 1
unset PAYRAM_EMAIL PAYRAM_PASSWORD
cmd_signin
''')

    def test_headless_saved_file_roundtrip(self):
        self.assert_credentials('''
unset PAYRAM_EMAIL
load_or_create_root_credentials
unset PAYRAM_EMAIL PAYRAM_PASSWORD
cmd_signin
''', expected_email="admin@payram.local")

    def test_json_email_roundtrip(self):
        # Encoding is independent of whether the API accepts an email value.
        email = 'dummy"\\\t\n@example.invalid'
        actual = self.run_cli("cmd_signin", "Aa1!ordinary", email=email)
        self.assertEqual(actual, {"email": email, "password": "Aa1!ordinary"})

    def test_existing_ordinary_credentials_remain_readable(self):
        actual = self.run_cli('''
printf 'PAYRAM_EMAIL="legacy@example.invalid"\nPAYRAM_PASSWORD="Aa1!legacy"\n' > "$CREDENTIALS_FILE"
chmod 600 "$CREDENTIALS_FILE"
unset PAYRAM_EMAIL PAYRAM_PASSWORD
cmd_signin
''', "Aa1!ignored")
        self.assertEqual(actual, {"email": "legacy@example.invalid",
                                  "password": "Aa1!legacy"})

    def test_environment_overrides_saved_file(self):
        actual = self.run_cli('''
printf 'touch command-executed\n' > "$CREDENTIALS_FILE"
chmod 600 "$CREDENTIALS_FILE"
cmd_signin
''', "Aa1!override")
        self.assertEqual(actual, {"email": "dummy@example.invalid",
                                  "password": "Aa1!override"})

    def test_signup_complexity_check_remains(self):
        actual = self.run_cli("cmd_setup && exit 9 || test $? -eq 1", "weak")
        self.assertIsNone(actual)


if __name__ == "__main__":
    unittest.main()
