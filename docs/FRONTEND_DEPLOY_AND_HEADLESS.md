# Frontend deploy + signing and headless replication

## What the frontend does (checked)

### 1. Deposit wallet (SCW) deploy — EVM

- **Where:** `DepositWalletDeployDialog.tsx` + `wagmiHelper.ts` + `sweepContract.ts`.
- **Flow:**
  1. User connects wallet (WalletConnect / MetaMask via wagmi).
  2. Frontend gets factory contract from backend: `GET /api/v1/blockchain-contract/blockchain/{code}/contract/factory_contract` → `id`, `address`, `abi`.
  3. User enters wallet name and cold wallet (fund collector) address.
  4. **Signing in browser:** `WagmiHelper.createERC20SmartContract(collector, abi, factoryAddress, salt)` uses wagmi’s `simulateContract` + `writeContract` → the **connected wallet signs and sends** the tx (createFundSweeperContract(salt, collector)).
  5. After success, frontend calls `POST /api/v1/wallets/deposit/scw/blockchains_contract/{contractId}` with `{ name, transactionHash }` to register the new SCW with the backend.

### 2. Deposit wallet (SCW) deploy — TRX

- Same idea: `TronwebHelper.createSmartContract(...)` builds the tx, then `walletClient.adapter.signTransaction(unsignedTx)` (TronLink / WalletConnect) signs; frontend sends raw tx and then same POST to register.

### 3. Wallet creation and signing

- **SCW:** The “wallet” is the smart contract (fund sweeper). The **deployer** is the user’s connected wallet (MetaMask/TronLink). So the frontend does **not** create an EOA; it triggers a contract deployment signed by the user’s wallet, then registers it via the API.
- **Signing:** All deploy and sweep-approval signing in the frontend is done by:
  - **EVM:** wagmi (writeContract, etc.) → browser wallet.
  - **TRX:** TronWeb adapter (signTransaction) → browser wallet.
- **Sweep signing (SidePanelSigningContent):** Uses **mnemonic** in the browser (getWalletPrivateKey from mnemonic) to sign approval txs — so signing can be done with a key derived from mnemonic, not only a connected wallet.

### 4. APIs used by frontend for this flow

| API | Purpose |
|-----|--------|
| `GET /api/v1/blockchain-contract/blockchain/{code}/contract/factory_contract` | Get factory ABI, address, id for deploy. |
| `POST /api/v1/wallets/deposit/scw/blockchains_contract/:blockchain_contract_id` | Register SCW after deploy; body: `{ name?, transactionHash }`. |

Backend does **not** deploy; it only stores contract metadata and, after the fact, registers the wallet when given a `transactionHash`.

---

## Replicating in headless: we create the wallet and handle signing

- **We have:** Mnemonic (e.g. from `generate-deposit-wallet-eth.js` or `.payraminfo`). We can derive the **private key** (e.g. path `m/44'/60'/0'/0/0`) and sign the deploy tx **outside the browser** (Node + ethers/viem).
- **Flow in headless:**
  1. **Auth:** Use existing headless token (signin / env) so we can call the APIs above.
  2. **Get factory:** `GET .../blockchain-contract/blockchain/ETH/contract/factory_contract` (or BASE/POLYGON if needed).
  3. **Build tx:** createFundSweeperContract(salt, fundCollector) — same as frontend. Salt = bytes32 (e.g. keccak256 of random UUID).
  4. **Sign and send:** Derive signer from mnemonic; sign the tx; broadcast via public RPC (need RPC URL, e.g. from env or backend blockchain config).
  5. **Register:** `POST .../wallets/deposit/scw/blockchains_contract/{id}` with `{ name, transactionHash }`.

No frontend or browser wallet needed; we create the deployer wallet from mnemonic and handle signing in Node.

---

## What’s in this repo

- **Doc:** This file.
- **Script:** `scripts/deploy-scw-eth.js` — deploys one ETH (or EVM) SCW from headless: loads mnemonic, gets factory from API, builds/signs/sends tx, then POSTs to register.
  - **Requires:** `PAYRAM_API_URL`, `PAYRAM_ACCESS_TOKEN` (or `.payraminfo/headless-tokens.env`), `PAYRAM_ETH_RPC_URL`, `PAYRAM_FUND_COLLECTOR` (cold wallet 0x address).
  - **Optional:** `PAYRAM_MNEMONIC` or mnemonic in `PAYRAM_MNEMONIC_FILE` (default `.payraminfo/headless-wallet-secret.txt`), `PAYRAM_SCW_NAME`, `PAYRAM_BLOCKCHAIN_CODE` (default ETH).
  - **Run:** `cd scripts && npm install && node deploy-scw-eth.js` (from repo root: `node scripts/deploy-scw-eth.js` after npm install in scripts).
- **CLI:** Optional later: add a headless command (e.g. `deploy-scw` or `ensure-wallet-scw`) that calls this script so agents can run it from the terminal.

---

## Summary

| Item | Frontend | Headless (we can do it) |
|------|----------|--------------------------|
| Get factory ABI + address | GET blockchain-contract | Same API with headless token. |
| Build deploy tx | createFundSweeperContract(salt, collector) | Same; script uses ethers. |
| Sign | Browser wallet (wagmi/TronLink) | Mnemonic → private key → sign in Node. |
| Broadcast | Via wagmi/TronWeb provider | Via RPC (e.g. PAYRAM_ETH_RPC_URL). |
| Register SCW | POST wallets/deposit/scw/... | Same API with headless token. |

So: deployment is done **directly** in the frontend (user’s wallet signs). We can do the same **from headless** by creating the wallet ourselves (from mnemonic) and handling signing in a Node script; no backend change required for this flow.
