# Agentic release — task list

**Goal:** CLI-first so agents can run PayRam from terminal. Phase-wise to release.

---

## Phase 1 — Environment

- [ ] POC on Linux
- [x] POC on Mac (done)
- [x] Default URL local: `http://localhost` (port 80)
- **Keep in mind:** Linux/Mac compatibility; local = localhost

---

## Phase 2 — Auth

- [x] CLI token refresh (no extra data)
- [ ] Optional: skill or doc for agents
- [ ] Optional: OAuth where needed
- **Keep in mind:** Refresh on 401; single “signin again” path

---

## Phase 3 — CLI & release

- [x] CLI exists (setup, signin, create-payment-link, ensure-wallet, ensure-config, reset-local)
- [x] Hot wallet input / ensure-wallet sorted
- [ ] Double-check: all key flows via env vars (non-interactive)
- [ ] Double-check: clear exit codes; one canonical payment URL
- [ ] Double-check: errors for no wallet, container down — clear message + exit code
- **SSL:** Optional. No change needed for agentic; production HTTPS = env for base URL if needed.
- **Keep in mind:** Parseable output; idempotent setup/ensure-*

---

## Phase 4 — Ethereum wallet & payment

- [x] ETH wallet generator script: `scripts/generate-deposit-wallet-eth.js` (mnemonic + xpub, BIP44 60)
- [ ] Backend supports ETH_Family (or equivalent) for create/link wallet
- [ ] ensure-wallet: option to create ETH wallet when API ready
- [ ] Contract deployment + ETH payment method: payram-core / backend (out of headless scope)
- [ ] Contract + gas: no API in headless today; add CLI here when backend exposes (see docs/ETH_CONTRACT_AND_GAS.md)
- **Keep in mind:** See `docs/ETH_WALLET.md` and `docs/ETH_CONTRACT_AND_GAS.md` for flow and changes here

---

*Details and sub-tasks can be added later.*
