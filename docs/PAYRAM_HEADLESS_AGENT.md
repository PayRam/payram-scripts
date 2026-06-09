# PayRam Headless — Agent skill

Use this when running or automating PayRam headless (CLI-only, no web UI). Only this repo may be modified; payram-core, payram-frontend, etc. are read-only.

---

## Prerequisites

- PayRam must be running (e.g. `./setup_payram_agents.sh` -> follow prompts).
- API URL is **derived automatically** from the install's `config.env` (or the
  running container); default `http://localhost` (the installer publishes
  `80:80`). Override with `PAYRAM_API_URL` only if you know better.
- Docker required if `PAYRAM_NODE_MODE=docker` (default) for JS tooling.
- A **fresh install needs a TTY** (the installer prompts for DB/SSL/ports). Run
  it once interactively; every step after that is fully headless.

---

## Commands

Run from repo root: `./setup_payram_agents.sh [command]`

**Entrypoint modes:**

- **One-step flow (install + headless):**
	- `./setup_payram_agents.sh` (prompts for network, then runs setup/signin/config/wallet/payment)
- **Headless-only commands:**
	- `./setup_payram_agents.sh status|setup|signin|ensure-config|ensure-wallet|deploy-scw|deploy-scw-flow|create-payment-link|reset-local|menu|run`

| Command | Purpose |
|--------|---------|
| *(none)* or `menu` | Show step menu; pick one step to run |
| `status` | Check API reachable and auth (token saved / valid) |
| `setup` | First-time: register root user + create default project |
| `signin` | Sign in; saves token to `.payraminfo/headless-tokens.env` |
| `ensure-config` | Seed `payram.frontend` and `payram.backend` for local API (needed for payment creation) |
| `ensure-wallet` | Create random BTC wallet or link existing to project (for payment links) |
| `deploy-scw` | Deploy ETH/EVM smart-contract deposit wallet; then auto-link to project |
| `deploy-scw-flow` | Generate mnemonic -> fund deployer -> balance check -> deploy SCW |
| `create-payment-link [projectId] [email] [amountUSD]` | Create payment link; outputs single URL to open |
| `run` | Full flow: setup/signin → ensure-config/ensure-wallet → create payment link (prompts) |
| `reset-local [-y]` | Wipe local DB and API data; then run `./setup_payram_agents.sh` again |

---

## Environment variables

Set these for non-interactive or scripted runs. For agents, prefer env-driven, non-interactive usage.

| Variable | Default | Notes |
|----------|---------|--------|
| `PAYRAM_API_URL` | derived (config.env / container; else `http://localhost`) | Backend API base |
| `PAYRAM_EMAIL` | — | Root user email (setup/signin) |
| `PAYRAM_PASSWORD` | — | Root user password |
| `PAYRAM_PROJECT_NAME` | `Default Project` | Project name on setup |
| `PAYRAM_PAYMENT_EMAIL` | — | Customer email for payment link |
| `PAYRAM_PAYMENT_AMOUNT` | `10` | Amount in USD for payment link |
| `PAYRAM_CUSTOMER_ID` | from signin | Usually from token file after signin |
| `PAYRAM_FRONTEND_URL` | `http://localhost` | Used by ensure-config (local) |
| `PAYRAM_NETWORK` | `testnet` | One-step flow network selection (`testnet` or `mainnet`) |
| `PAYRAM_NODE_MODE` | `docker` | JS runtime: `docker` or `host` |
| `PAYRAM_NODE_DOCKER_IMAGE` | `node:20-bullseye-slim` | Docker image used for JS scripts |
| **deploy-scw** | | |
| `PAYRAM_ETH_RPC_URL` | `https://ethereum-sepolia-rpc.publicnode.com` | No API key needed. Placeholder values (e.g. YOUR_ACTUAL_ALCHEMY_KEY) are ignored and default used. |
| `PAYRAM_FUND_COLLECTOR` | deployer address | Cold wallet 0x (40 hex). Omit or leave empty to use deployer address from mnemonic. |
| `PAYRAM_SCW_NAME` | `Headless SCW` | Name for the SCW wallet |
| `PAYRAM_BLOCKCHAIN_CODE` | `ETH` | e.g. ETH, BASE, POLYGON |
| `PAYRAM_MNEMONIC` | — | Or mnemonic in `.payraminfo/headless-wallet-secret.txt` |
| `PAYRAM_SCW_MIN_BALANCE_ETH` | `0.01` (testnet) | Balance threshold before deploying SCW |
| `PAYRAM_SCW_SKIP_BALANCE_CHECK` | — | If set, skip balance polling (not recommended) |
| `PAYRAM_WALLET_CHOICE` | — | `1` create, `2` link, `3` skip (non-interactive) |
| `PAYRAM_WALLET_QUIET` | — | If set, suppress wallet prompt text |
| `PAYRAM_FORCE_DEPLOY` | — | `1` = deploy another ETH SCW even if one is already linked |
| `PAYRAM_ACCEPT_MAINNET_COSTS` | — | `1` = confirm a non-interactive MAINNET deploy (spends real ETH) |

Token is read from `.payraminfo/headless-tokens.env` (created by signin). Deploy-scw uses mnemonic from that file or `PAYRAM_MNEMONIC`.

**Non-interactive defaults:**

- One-step flow defaults to `ensure-wallet` (**BTC** XPUB starter wallet, no
  gas) and creates the payment link immediately, then best-effort attempts the
  ETH SCW (USDC/EVM); `--deploy-scw` makes the SCW the blocking first step,
  `--skip-scw` skips it.
- If `PAYRAM_WALLET_CHOICE` is set, prompts are suppressed and that choice is used.
- With no TTY: wallet choice defaults to create (1); auth and mainnet-deploy
  steps **fail fast with instructions** instead of prompting.
- Mainnet `deploy-scw` requires `PAYRAM_FUND_COLLECTOR` (your cold wallet) and
  `PAYRAM_ACCEPT_MAINNET_COSTS=1` (or a typed confirmation on a TTY).

---

## Typical flow

1. **Start PayRam:** `./setup_payram_agents.sh` (installs or restarts).
2. **Auth:** `./setup_payram_agents.sh signin` (or setup if first time). Env: `PAYRAM_EMAIL`, `PAYRAM_PASSWORD`.
3. **Config (local):** `./setup_payram_agents.sh ensure-config` so payment creation works.
4. **Wallet:** Either `./setup_payram_agents.sh ensure-wallet` (BTC) or `./setup_payram_agents.sh deploy-scw-flow` (ETH SCW). deploy-scw-flow generates a mnemonic, shows deployer address, waits for funds, then deploys.
5. **Payment link:** `./setup_payram_agents.sh create-payment-link` or pass `[projectId] [email] [amountUSD]`. Use the printed URL as-is (keep `&host=...`).

## One-step flow details (agent behavior)

The one-step flow does:

1. Network selection (`testnet` or `mainnet`) unless `PAYRAM_NETWORK` is set.
2. Install or restart PayRam using `setup_payram.sh` (fresh install needs a TTY).
3. Re-reads `config.env` and waits for API readiness at the real port.
4. Auth (`setup` if no root user, else `signin`).
5. `ensure-config` for local frontend/backend settings.
6. Wallet flow:
	- Default: `ensure-wallet` - **BTC XPUB** starter wallet (instant, zero
	  gas). BTC payments work immediately.
	- `--deploy-scw`: run the ETH SCW deploy FIRST (blocking) instead.
7. Payment link creation (the deliverable - printed in the final summary).
8. SCW step (unless `--skip-scw`): attempts the ETH smart-contract wallet to
   unlock **USDC/EVM** payments. With a TTY it guides the gas funding; headless
   and unfunded it defers with instructions (`deploy-scw-flow` later) - the BTC
   link already works either way.

> Why two wallet kinds: **XPUB wallets are BTC-only.** payram-core derives EVM
> deposit addresses from the fund-sweeper CONTRACT (CREATE2 from the factory),
> never from an xpub - so USDC/ETH/BASE/POLYGON payments require the SCW
> deploy (gas). The SCW also IS the sweep mechanism: deposits drain to your
> cold wallet without any key on the server.

## Adding more chains later

`deploy-scw` is chain-parametric. After the first (ETH) SCW, deploy on other
EVM chains once the gateway is running:

```bash
# Base (mainnet defaults to base-rpc.publicnode.com)
PAYRAM_BLOCKCHAIN_CODE=BASE ./setup_payram_agents.sh deploy-scw

# Polygon
PAYRAM_BLOCKCHAIN_CODE=POLYGON ./setup_payram_agents.sh deploy-scw
```

- Each chain fetches its own factory contract from the API
  (`/api/v1/blockchain-contract/blockchain/<CODE>/contract/factory_contract`).
- The already-deployed skip only applies to the default ETH target; a non-ETH
  `PAYRAM_BLOCKCHAIN_CODE` always deploys (it is an explicit add-a-chain intent).
- On testnet, non-ETH chains need an explicit `PAYRAM_ETH_RPC_URL` (that
  chain's testnet RPC); mainnet has per-chain PublicNode defaults.
- The deployer needs gas **on that chain** - the funding card shows the address.

## Generating payment links later (the repeatable operation)

Three ways, lowest friction first:

1. **CLI** (this repo): `./setup_payram_agents.sh create-payment-link [projectId] [email] [amountUSD]`
2. **API** (what the CLI calls):
   `POST /api/v1/external-platform/{projectId}/payment` with
   `{"customerID":"...","customerEmail":"...","amountInUSD":10}` and a Bearer
   token - returns `{ "url": ... }`. Payment links are currency-agnostic: the
   payer picks the coin/chain at checkout from whatever your linked wallet
   families support.
3. **MCP for app integration**: the `payram-helper-mcp-server` repo provides an
   MCP server that teaches agents to integrate PayRam payments into an
   application. (The MCP server started by this script is **analytics-only**;
   it does not create payment links.)

## Deploy-scw flow details

`deploy-scw-flow` does:

1. Generate mnemonic if `.payraminfo/headless-wallet-secret.txt` is missing.
2. Derive deployer address from the mnemonic and show it.
3. Wait for balance >= `PAYRAM_SCW_MIN_BALANCE_ETH` by polling the RPC.
4. Deploy SCW using `scripts/deploy-scw-eth.js`.
5. Register SCW with backend and link to the project.

**Funding step:**

- You must send ETH to the deployer address manually (testnet faucet for Sepolia, or mainnet wallet).
- The script waits until the balance meets the threshold, then proceeds.

## Docker node runtime behavior

- When `PAYRAM_NODE_MODE=docker`, JS scripts run inside Docker.
- The script maps `PAYRAM_API_URL` from `localhost` to `host.docker.internal` so the container can reach the host API.
- `.payraminfo` is mounted into the container to access the mnemonic and tokens.

---

## Payment link URL

- Use the **exact** URL printed (one block: “Open this in your browser”). Do not strip `host` or change `&`.
- If the payment page loads forever or shows `undefined` in API calls: the link must include `reference_id` and `host` with a real `&`. Fix any `\u0026` → `&` if the link was mangled.

---

## Deploy-scw (ETH SCW)

- **RPC:** Default PublicNode Sepolia (no key). Override with `PAYRAM_ETH_RPC_URL` if needed.
- **Fund collector:** Optional. Omit or press Enter to use deployer address (sweep to self). Set `PAYRAM_FUND_COLLECTOR` to a valid 0x address for a different cold wallet.
- **Gas:** Deployer address (from mnemonic) must have Sepolia ETH. If you see `INSUFFICIENT_FUNDS`, send testnet ETH to the deployer address shown in the log; use e.g. https://sepoliafaucet.com or https://www.alchemy.com/faucets/ethereum-sepolia.
- After success, the script registers the SCW and links it to the current project; no extra step.

---

## Reset and reinstall

- `./setup_payram_agents.sh reset-local [-y]` clears DB and API data (and optionally Docker image).
- Then run `./setup_payram_agents.sh` again.

---

## Files and scripts

- **Token / secrets:** `.payraminfo/headless-tokens.env`, `.payraminfo/headless-wallet-secret.txt` (mnemonic). Do not commit.
- **Scripts:** `scripts/generate-deposit-wallet.js` (BTC), `scripts/generate-deposit-wallet-eth.js` (ETH xpub), `scripts/deploy-scw-eth.js` (SCW deploy). Run via headless commands; deploy-scw is invoked by `./setup_payram_agents.sh deploy-scw`.

## Agent automation tips

- Always set `PAYRAM_EMAIL`, `PAYRAM_PASSWORD`, and `PAYRAM_CUSTOMER_ID` for fully non-interactive runs.
- Use `PAYRAM_WALLET_CHOICE=1` and `PAYRAM_WALLET_QUIET=1` to avoid wallet prompts.
- For SCW, set `PAYRAM_SCW_MIN_BALANCE_ETH` to a known safe threshold if your RPC has delayed balance reporting.
- When using Docker node runtime, ensure Docker is running and has access to host networking.

---

## Troubleshooting

| Issue | Action |
|-------|--------|
| API unreachable | Ensure PayRam is running (`./setup_payram_agents.sh`). Check `PAYRAM_API_URL`. |
| Auth expired / 401 | Run `./setup_payram_agents.sh signin` again. |
| Payment creation 500 | Run `ensure-config` and `ensure-wallet` (or deploy-scw). Check backend logs: `docker logs payram 2>&1 \| tail -80`. |
| deploy-scw 401 on RPC | Do not use placeholder RPC URL; default (PublicNode) is used if env looks like a placeholder. |
| deploy-scw INSUFFICIENT_FUNDS | Send Sepolia ETH to the deployer address (from mnemonic) shown in the log. |
| Payment page loads forever | Use the payment URL exactly as returned; ensure `host` param and `&` are correct. |
