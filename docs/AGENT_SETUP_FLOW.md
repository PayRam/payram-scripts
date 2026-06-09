# Agent Setup Flow — Design

Goal: **any agent sets up PayRam with minimum friction and generates a payment
link as fast as possible** (TTFPL — time to first payment link). Everything
else is an upgrade that can happen later. `setup_payram.sh` is the source of
truth for installation and is never modified or bypassed — the agent delegates
to it and *reads* its outputs.

## Wallet / money model (drives the gates)

```
 CUSTOMER PAYS                                  PAYRAM SERVER STORES
 ──────────────                                 ─────────────────────
 deposit addresses  ──derived from──►  XPUB only         (no private keys
 (unique per payment)                                     for deposit funds)
        │
        │  sweep (needs gas)
        ▼
 HOT WALLET  ◄── "refill gas" ── small ops fuel, repeatable      [OPS]
        │  swept funds never stay here
        ▼
 COLD WALLET ── fund-collector address; keys never on server  [SECURITY]
```

- **Gas refill** is operational: small amounts, repeatable, agent guides
  (address + amount + faucet link) and polls. Not a scary gate.
- **Cold-wallet address** is the one real security decision. Only gated hard
  on **mainnet** (real money). On testnet a default is fine — "change before
  going live."

## Interaction tiers

| Tier | When | Behaviour |
|---|---|---|
| AUTO | reversible, free | just do it, report it |
| ASK | reversible but a real choice | suggest default, note "changeable later", proceed headlessly with the default |
| GATE | irreversible / spends real money / ownership | hard stop; explicit env flag or human input required |

## Two lanes

### Fast lane (default — "try it out", testnet)

```
 prechecks ─► install (delegate to setup_payram.sh, testnet)
   ─► read config.env  (REAL port / dirs / network — never assume :8080)
   ─► auth (env creds; fail fast if missing and no TTY)
   ─► project (reuse or create)
   ─► WALLET [ASK, default 1]:
        (1) agent creates starter deposit wallet now  (~10s, xpub only,
            BTC + ETH families, no keys sent to server)   ← default
        (2) link one you already created
        (3) skip — link later via dashboard
        "Either way you can add more wallets later."
   ─► PAYMENT LINK  ← the deliverable, printed unmissably
   ─► handoff summary (what was created / what to change later / upgrade path)
```

Zero gas, zero human waits after credentials. TTFPL ≈ install + ~1 minute.

### Upgrade lane (explicit `--deploy-scw`)

```
 idempotency pre-check (SCW already linked? → skip; PAYRAM_FORCE_DEPLOY=1 to override)
   ─► GAS REFILL card: deployer address + required amount + faucet link
      (testnet) + poll; resumable
   ─► mainnet only [GATE]: PAYRAM_FUND_COLLECTOR (cold wallet) required
      + PAYRAM_ACCEPT_MAINNET_COSTS=1 (or typed confirmation on a TTY)
   ─► deploy → persist wallet id (scw-state.env) → link
      (link failure ⇒ re-run retries LINK ONLY, never redeploys)
```

## Error handling contract

Every failure prints a **troubleshooting card**: ranked likely causes (with
rough probability based on observed symptoms) and the exact fix command.
Errors exit non-zero. Cards live in `troubleshoot()` in
`setup_payram_agents.sh`:

| Card | Symptom |
|---|---|
| api-unreachable | API probe fails |
| install-interactive | fresh install needs a TTY (setup_payram.sh prompts) |
| auth-env | creds missing and no TTY to prompt |
| auth-failed | signin/signup rejected |
| gas | deployer underfunded |
| rpc | RPC/balance check failed |
| deploy-failed | SCW deploy tx failed |
| link-failed | deploy ok, project link failed (resume = link only) |
| payment-link | payment link creation failed |

## Runtime truth (anti-drift rule)

Per-install facts are **read, never assumed**:

1. `PAYRAM_API_URL` env override, if set — respected as-is.
2. Installer's `config.env` (`$PAYRAM_HOME/.payraminfo/config.env`):
   `RETAINED_PORTS` → API port/scheme, `PAYRAM_HOME` → state dirs,
   `NETWORK_TYPE` → network, `SSL_CERT_PATH` → https.
3. Running container: `docker port payram 80`.
4. Last resort default: `http://localhost` (the installer's default mapping
   is `80:80` — **not** `:8080`).
