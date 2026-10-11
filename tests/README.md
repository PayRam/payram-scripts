# Agent credential regression checks

Run `python3 -m unittest discover -s tests -v` from the repository root.
Python 3 is required only for these tests; the CLI adds no runtime dependency.

The checks execute the actual Bash credential/auth functions with dummy values
and mock `curl`, token saving and project calls. They cover headless sign-in and
signup, interactive sign-in and signup, both credential-file writers, file mode
600, old ordinary credential files, and environment overrides. Password cases
include quotes, backslashes, all representable JSON control characters, Unicode,
dollar expressions, and command substitution; the latter must never execute.
Each roundtrip runs under both `C` and `C.UTF-8` locales.

The installer, gateway, Docker, wallets and payment-link code are not started.
These are local regression checks, not a live server or multiple-OS verification.
Previously written files whose passwords already expanded cannot recover the
original value; the new writer preserves values saved after this fix.

To reproduce failures on an old script, set `PAYRAM_AGENT_SCRIPT` to its absolute
path before running the same command.
