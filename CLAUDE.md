# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Deployment & operations tooling for the **self-hosted PayRam crypto payment gateway**. It does **not** contain the gateway application — that ships as the `payramapp/payram` Docker image, built from other repos (`payram-core`, `payram-frontend`, …). Those repos are **read-only** from here; this repo only installs, configures, updates, and drives that image.

Everything is shell + a little Node. There is no compiled app, no test suite, no package manager at the repo root.

## The three entrypoints

| Script | Role |
|--------|------|
| `setup_payram.sh` (~4k lines) | Primary installer/updater for the full gateway (Docker + UI). Fresh install, `--update`, `--reset`, `--testnet`/`--mainnet`, `--tag=<ver>`. |
| `setup_payram_agents.sh` | Headless CLI for AI agents / automation — installs *and* operates PayRam over its REST API (signin, config, wallet deploy, payment links, Analytics MCP server). Still in testing; not for regular clients. |
| `setup_payram_shopify.sh` | Optional add-on installer for the Shopify "Pay with Crypto" connector (Docker-only; handles Shopify CLI auth + deploys the checkout extension). |

`scripts/` holds Node helpers the agent flow invokes; `updater-configs/` holds JSON read by the in-container self-updater; `docs/` documents the agent and Shopify flows.

## Critical distribution model (read before editing any script)

These scripts are consumed by **piping `main` directly from the network**, not by cloning:

```bash
bash <(curl -fsSL https://payram.com/setup_payram.sh)                 # payram.com mirror
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram_agents.sh)"
```

Consequences that shape every change:
- **Merging to `main` makes a script instantly live** to every remote one-liner user. Treat `main` as production.
- **A script cannot assume sibling files exist on disk.** `setup_payram_agents.sh` bootstraps its own helpers (`ensure_assets`) by fetching `scripts/*.js` + `package.json` from `raw.githubusercontent.com/...`; if you add a runtime dependency file, wire it into that fetch list too.
- Must stay self-contained and idempotent; the one-liner form uses process substitution (`bash <(...)`) specifically so the interactive menu still reads from a TTY — never break that by assuming `curl ... | bash`.

## Commands

```bash
# Syntax-check before anything (this repo's de-facto "test" — see IMPLEMENTATION_SUMMARY.md)
bash -n setup_payram.sh
bash -n setup_payram_agents.sh
bash -n setup_payram_shopify.sh

# Run the installer locally (root needed for system/Docker changes)
sudo ./setup_payram.sh --testnet          # recommended for first run
sudo ./setup_payram.sh --update --tag=vX.Y.Z
sudo ./setup_payram.sh --reset            # must type DELETE to confirm

# Headless agent flow (no sudo unless it installs)
./setup_payram_agents.sh                  # one-step: network prompt -> setup/signin/config/wallet/payment
./setup_payram_agents.sh status|signin|ensure-config|ensure-wallet|deploy-scw|create-payment-link

# Node helpers (run from repo root; deps live in scripts/)
cd scripts && npm install && cd ..
node scripts/generate-deposit-wallet.js       # BTC xpub  (m/44'/0'/0')  -> {mnemonic, xpub}
node scripts/generate-deposit-wallet-eth.js   # ETH xpub  (m/44'/60'/0') -> {mnemonic, xpub}
node scripts/deploy-scw-eth.js                # deploy + register one EVM SCW deposit wallet
```

No linter is configured. Manual testing across OS families is the expected validation (see README requirements).

## Architecture notes

### `setup_payram.sh` — one monolithic file, organized in function bands
Built around a **single OS-detection function** (`detect_system_info`) whose output (family/distro/pkg-manager/service-manager) feeds universal wrappers (`pkg_install`, `service_start`, …) so there is no per-OS branching duplicated through the file. Bands, in order: core utils (logging, `show_progress`, `print_color`, `check_privileges`) → system detection/validation → Docker & PostgreSQL install → interactive config (DB, SSL, ports) → container lifecycle (`deploy_payram_container`, `update_payram_container`, `reset_payram_environment`) → health check → banners/menu → `main` (arg parsing). When adding OS support or a config step, extend the relevant band and reuse the universal wrappers — do not add OS-specific blocks.

### Runtime state (on the host, gitignored)
- `~/.payraminfo/` — `config.env` (chmod 600), `aes/` keys, `ssl/` certs, and the agent's `mcp.bin`/pid/log. **Fund-collection keys are never stored server-side.**
- `~/.payram-core/` — `data/` (persistent) + `logs/`.
- `run_local.sh`-style local runs use repo-local `.payraminfo/` / `.payram-core/` (both gitignored).

### `setup_payram_agents.sh` — headless operator
Subcommand dispatcher (`headless_main` → `cmd_*`) plus a guided `flow_main`. Talks to the running gateway's REST API at `PAYRAM_API_URL` (default `http://localhost:8080`) — endpoints like `/api/v1/signin`, `/api/v1/external-platform`, `/api/v1/member/root/exist`. Runs the Node helpers either on the host or inside Docker via `PAYRAM_NODE_MODE` (default `docker`), rewriting `localhost`/`127.0.0.1` → `host.docker.internal` so a containerized node can reach a host-port API. Also manages auth tokens (`ensure_token`/`refresh_token`) and can launch the Analytics **MCP server** (`start-mcp-server`, default port 3333). The wallet helpers mirror the frontend's `DepositWalletDeployDialog` flow but sign locally instead of in a browser.

### `updater-configs/` — consumed by the in-container updater, not by these scripts
- `upgrade-policy.json` — `latest`, full `releases` list, `breakpoints` (versions requiring a manual stop, e.g. 2.0.0), `arch_support` (e.g. arm64 floor), `dashboard_max`. Update this when cutting a gateway release so clients upgrade along a safe path.
- `runtime-manifest.json` — image repo (`payramapp/payram`) and health endpoint (`/api/v1/health`).

## Releases & commits

Releases are **semantic-release** (Angular preset), triggered manually via the `Release` GitHub Action (`workflow_dispatch` on `main`), and announced to Slack. **Commit messages drive version bumps**, so use Conventional Commit types:

- `feat:` → minor · `fix:` / `refactor:` → patch · breaking change → major
- `chore:` / `docs:` / `test:` / `ci:` → **no release**

`@semantic-release/github` tags and creates the GitHub release; there is no separate version file to bump in this repo (gateway versions live in `updater-configs/upgrade-policy.json`).
