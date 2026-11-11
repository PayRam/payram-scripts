#!/usr/bin/env python3
"""Offline regression checks for the host-side Shopify installer blocks.

Run with Python 3; BASH_UNDER_TEST selects the Bash executable (default /bin/bash).
An optional source path allows the same checks to run against an older checkout.
Only the reviewed set_env function and store-list block are executed. Docker,
Shopify, real configuration, and the installer entrypoint are never invoked.
"""

import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else (
    Path(__file__).resolve().parents[1] / "setup_payram_shopify.sh"
)
TEXT = SOURCE.read_text()
BASH = os.environ.get("BASH_UNDER_TEST", "/bin/bash")
SET_ENV = re.search(r"^set_env\(\) \{\n.*?^\}", TEXT, re.M | re.S).group(0)
STORE_LIST = TEXT.split(
    "  # Extract .myshopify.com domains from CLI table output\n", 1
)[1].split('  store_domain_input=""', 1)[0]


class ShopifyPortabilityTests(unittest.TestCase):
    def run_bash(self, code, *args, env=None):
        result = subprocess.run(
            [BASH, "-c", "set -euo pipefail\n" + code, "portability-test", *args],
            text=True, capture_output=True, env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        return result.stdout

    def check_env(self, initial, value, expected):
        with tempfile.TemporaryDirectory(prefix="payram-portability-") as tmp:
            path = Path(tmp) / ".env"
            path.write_text(initial)
            path.chmod(0o600)
            output = self.run_bash(
                SET_ENV + '\nENV_FILE=$1\nset_env SHOPIFY_APP_URL "$2"\n'
                'printf "%s" "$SHOPIFY_APP_URL"\n', str(path), value,
            )
            self.assertEqual(output, value)
            self.assertEqual(path.read_text(), expected)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), [".env"])

    def test_append_new_key(self):
        self.check_env("OTHER=keep\n", "https://new.example",
                       "OTHER=keep\nSHOPIFY_APP_URL=https://new.example\n")

    def test_update_existing_key(self):
        self.check_env("# keep comment\nSHOPIFY_APP_URL=https://old.example\nOTHER=keep\n",
                       "https://new.example",
                       "# keep comment\nSHOPIFY_APP_URL=https://new.example\nOTHER=keep\n")

    def test_update_literal_replacement_characters(self):
        value = r"https://new.example/path?a=1&b=2|literal\suffix"
        self.check_env("SHOPIFY_APP_URL=https://old.example\n", value,
                       "SHOPIFY_APP_URL=" + value + "\n")

    def test_update_without_trailing_newline(self):
        self.check_env("OTHER=keep\nSHOPIFY_APP_URL=https://old.example",
                       "https://new.example", "OTHER=keep\nSHOPIFY_APP_URL=https://new.example")

    def test_failed_rewrite_keeps_original_and_removes_tempfile(self):
        with tempfile.TemporaryDirectory(prefix="payram-portability-") as tmp:
            path = Path(tmp) / ".env"
            original = "SHOPIFY_APP_URL=https://old.example\n"
            path.write_text(original)
            mock_bin = Path(tmp) / "bin"
            mock_bin.mkdir()
            mock_sed = mock_bin / "sed"
            # The escaping pass succeeds; the subsequent file rewrite fails.
            mock_sed.write_text('#!/bin/bash\nif [ "$#" -eq 1 ]; then /bin/cat; else exit 9; fi\n')
            mock_sed.chmod(0o700)
            env = dict(os.environ, PATH=str(mock_bin) + os.pathsep + os.environ["PATH"])
            result = subprocess.run(
                [BASH, "-c", "set -euo pipefail\n" + SET_ENV +
                 '\nENV_FILE=$1\nset_env SHOPIFY_APP_URL https://new.example\n',
                 "portability-test", str(path)], text=True, capture_output=True, env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), original)
            self.assertEqual(list(Path(tmp).glob(".env.tmp.*")), [])

    def check_stores(self, raw, expected):
        output = self.run_bash(
            'STORES_RAW=$1\n' + STORE_LIST +
            '\nprintf "%s\\n" "${#STORES_ARRAY[@]}"\n'
            'if [ "${#STORES_ARRAY[@]}" -gt 0 ]; then\n'
            '  printf "%s\\n" "${STORES_ARRAY[@]}"\nfi\n', raw,
        )
        self.assertEqual(output.splitlines(), [str(len(expected)), *expected])

    def test_empty_store_listing(self):
        self.check_stores("", [])

    def test_single_store_listing(self):
        self.check_stores("Store: alpha.myshopify.com\n", ["alpha.myshopify.com"])

    def test_multiple_stores_are_sorted_and_deduplicated(self):
        self.check_stores("zulu.myshopify.com\nalpha.myshopify.com\nzulu.myshopify.com\n",
                          ["alpha.myshopify.com", "zulu.myshopify.com"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
