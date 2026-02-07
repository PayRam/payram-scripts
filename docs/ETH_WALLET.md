# Ethereum wallet and payment method

## In this repo (headless)

- **Script:** `scripts/generate-deposit-wallet-eth.js` — same deps as BTC script. Outputs `{ mnemonic, xpub, family: "ETH_Family" }` with BIP44 path `m/44'/60'/0'`.
- **SCW deploy (EVM):** `scripts/deploy-scw-eth.js` — deploy a smart-contract deposit wallet from headless using mnemonic (we create the wallet and sign). Same flow as frontend but no browser. See **docs/FRONTEND_DEPLOY_AND_HEADLESS.md**.
- **Linking:** Use `ensure-wallet` → option (2) Link existing wallet, after creating an ETH wallet via dashboard or API (if backend supports ETH_Family).
- **CLI:** No `ensure-wallet` auto-create for ETH EOA yet; backend must accept ETH_Family in bulk API. SCW path: use deploy-scw-eth.js then link/register via API.

## Backend / core (read-only from here)

- **API:** Wallet create/link API must accept `ETH_Family` (or backend’s ETH family name) and ETH xpub format.
- **Contract deployment:** Smart-contract flows (e.g. receive-to-contract, forward to treasury) are implemented in payram-core / backend, not in headless. Required for full ETH payment method.
- **Gas fees:** Not in headless; backend must expose config or API. See **docs/ETH_CONTRACT_AND_GAS.md** for what this repo has, what backend needs, and flow/changes here once API exists.

## Summary

| Item | Where |
|------|--------|
| Generate ETH mnemonic + xpub | headless: `node scripts/generate-deposit-wallet-eth.js` |
| Create/link ETH wallet via API | headless when backend supports it; else dashboard |
| Contract deployment, gas fees, ETH payment flow | payram-core / backend; headless changes in docs/ETH_CONTRACT_AND_GAS.md |
