# Contract setup and gas fees — what this codebase has and needs

## Final check: backend (payram-core) APIs

**Contract-related APIs that exist:**

| Endpoint | What it does |
|----------|----------------|
| `POST /api/v1/blockchain-contract/blockchain/:blockchain_code/contract` | Create contract **metadata** in DB (ABI, bytecode, address, type). Does **not** deploy on-chain. |
| `GET /api/v1/blockchain-contract/contract/:contract_type` | Get contract by type. |
| `GET /api/v1/blockchain-contract/blockchain/:blockchain_code/contract/:contract_type` | Get contract by blockchain + type. |
| `POST /api/v1/contract-address/blockchain/:blockchain_code/contract/:contract_id` | Create **contract address** record (e.g. sweep address). Does **not** deploy on-chain. |
| `PATCH /api/v1/contract-address/.../id/:id` | Update contract address. |
| `GET /api/v1/contract-address/blockchain/:blockchain_code/contract/:contract_type` | Get contract address by blockchain + type. |

All require admin + permissions (`read_blockchain_contract`, `write_blockchain_contract`, etc.).

**What the backend does NOT expose:**

- **No "deploy contract" API** — No HTTP endpoint that signs and broadcasts a deployment transaction. On-chain deployment today is (1) **manual / from the Frontend** (user sends the tx), or (2) a **background job** (`BroadcastSCWDepositWalletProcessor`) that broadcasts pending deposit-wallet deployments. So contract deployment is **not** triggered via API; it's manual or job-driven.
- **No gas config API** — No endpoint to set/read ETH gas price or gas limit. Fee-related fields exist for withdrawal, sweep, and blockchain currency (e.g. deposit/withdraw/approval fees), but not "ETH gas price" style config.

**Conclusion:** Backend has **CRUD for contract metadata and contract addresses** (register after deploy). It does **not** have an API to **perform** contract deployment or to configure gas. So yes — deployment is effectively **manual** (or FE / job); we'd need to **add** an API if we want "deploy contract" and/or "set gas" from headless/CLI.

---

## Checked in this repo (payram-headless)

- **Contract deployment:** Not present. No API calls, no scripts, no config keys. script.sh “deploy” = Docker container only.
- **Gas fees:** Not present. No gas config, no API for gas or fee settings.
- **APIs we use today:** signup/signin/refresh, configuration (payram.frontend, payram.backend only), external-platform (projects, payment link), project wallet (get/link), wallets (list, deposit/eoa/bulk). No contract or gas endpoints.

**Conclusion:** Headless doesn't call contract or gas APIs yet. We *could* add CLI that calls the existing **blockchain-contract** and **contract-address** CRUD (to register metadata/address after manual deploy). Actual **deploy** and **gas** still need to be added in backend for full support.

---

## What the backend would need to expose (for deploy + gas)

| Need | Backend (payram-core) | Headless can do once API exists |
|------|------------------------|----------------------------------|
| Contract deployment or address | API to deploy or to set/read contract address (e.g. per chain or per project) | New CLI command(s) that call deploy/set-address/get-address |
| Gas fees | API or config keys (e.g. `payram.ethGasPrice`, `payram.ethGasLimit`, or per-tx override) | ensure-config style: seed gas config if missing; or new `set-gas` / `get-gas` CLI calling API |
| Contract + gas in payment flow | Backend uses contract address and gas settings when creating ETH payments | No change in headless if payment link API stays the same; only if API adds optional params (e.g. gas preference) we’d pass them in create-payment-link |

---

## Flow and changes in this repo only

**1. Contract**

- **If backend adds:** e.g. `POST /api/v1/project/{id}/contract` or `POST /api/v1/configuration` with keys like `payram.ethContractAddress`.
- **Here:** Add a command, e.g. `ensure-contract` or `set-contract`, that calls that API (and optionally reads address from env like `PAYRAM_ETH_CONTRACT_ADDRESS`). No deployment logic in headless; we only send address or trigger backend deploy if the API exists.

**2. Gas fees**

- **If backend adds:** Config keys (e.g. `payram.ethGasPrice`) or API like `GET/POST /api/v1/.../gas`.
- **Here:** Either extend `ensure-config` to set gas keys when missing (from env, e.g. `PAYRAM_ETH_GAS_PRICE`), or add `set-gas` / `get-gas` that call the gas API. Document env vars in headless help.

**3. Payment link**

- **Today:** We POST `customerID`, `customerEmail`, `amountInUSD` to create payment link. No contract or gas in payload.
- **If backend adds:** Optional body fields (e.g. `gasPrice`, `contractAddress`, or `useContract: true`), we’d add optional env vars and include them in the payload in `headless.sh` only if the backend documents them.

**4. Docs**

- **Here:** Keep `docs/ETH_WALLET.md` and this file; add a short “Contract & gas” section to the agentic checklist that points to this doc and says: “Contract + gas = backend first; headless will add CLI once API exists.”

---

## Summary

| Topic | Backend API? | In headless? | Notes |
|--------|----------------|--------------|--------|
| Contract metadata / address (CRUD) | Yes — `/api/v1/blockchain-contract/*`, `/api/v1/contract-address/*` | No | Headless could add CLI to register after manual deploy. |
| Contract deployment (on-chain tx) | No — manual or FE or job | No | Backend would need new API to trigger deploy. |
| Gas config | No | No | Backend would need config or API for gas. |
| Payment link | Yes | Yes | Optional body params only if API adds contract/gas. |

So: backend **has** contract/address CRUD; **no** deploy API and **no** gas API. Deployment is **manual** (or from frontend / background job). We'd have to **add** deploy + gas in backend to support them from headless; headless can add CLI for existing CRUD anytime.
