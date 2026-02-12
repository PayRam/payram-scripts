#!/usr/bin/env node
/**
 * Deploy one ETH (EVM) SCW deposit wallet from headless: sign with mnemonic, then register via API.
 * Same flow as frontend DepositWalletDeployDialog but no browser — we create the wallet and sign ourselves.
 *
 * Requires: PAYRAM_API_URL, PAYRAM_ACCESS_TOKEN (or token in .payraminfo), PAYRAM_ETH_RPC_URL,
 *           PAYRAM_FUND_COLLECTOR (cold wallet address). Optional: PAYRAM_MNEMONIC or mnemonic file path,
 *           PAYRAM_SCW_NAME, PAYRAM_BLOCKCHAIN_CODE (default ETH).
 *
 * Run from repo root: node scripts/deploy-scw-eth.js
 * Dependencies: npm install ethers (in scripts/)
 */
const fs = require('fs');
const path = require('path');

const PAYRAM_API_URL = process.env.PAYRAM_API_URL || 'http://localhost:8080';
const PAYRAM_ACCESS_TOKEN = process.env.PAYRAM_ACCESS_TOKEN;
// Default: PublicNode Sepolia (free, no API key). Ignore placeholder env values.
const _rpc = (process.env.PAYRAM_ETH_RPC_URL || '').trim();
const PAYRAM_ETH_RPC_URL = (_rpc && !/YOUR_ACTUAL|YOUR_KEY|your_key/i.test(_rpc))
  ? _rpc
  : 'https://ethereum-sepolia-rpc.publicnode.com';
const PAYRAM_FUND_COLLECTOR = process.env.PAYRAM_FUND_COLLECTOR;
const PAYRAM_SCW_NAME = process.env.PAYRAM_SCW_NAME || 'Headless SCW';
const PAYRAM_BLOCKCHAIN_CODE = process.env.PAYRAM_BLOCKCHAIN_CODE || 'ETH';
const PAYRAM_MNEMONIC = process.env.PAYRAM_MNEMONIC;
const PAYRAM_MNEMONIC_FILE = process.env.PAYRAM_MNEMONIC_FILE || path.join(__dirname, '..', '.payraminfo', 'headless-wallet-secret.txt');

function getToken() {
  if (PAYRAM_ACCESS_TOKEN) return PAYRAM_ACCESS_TOKEN;
  const tokenFile = path.join(__dirname, '..', '.payraminfo', 'headless-tokens.env');
  if (fs.existsSync(tokenFile)) {
    const content = fs.readFileSync(tokenFile, 'utf8');
    const m = content.match(/ACCESS_TOKEN="([^"]+)"/);
    if (m) return m[1];
  }
  return null;
}

function getMnemonic() {
  if (PAYRAM_MNEMONIC) return PAYRAM_MNEMONIC.trim();
  const file = path.isAbsolute(PAYRAM_MNEMONIC_FILE) ? PAYRAM_MNEMONIC_FILE : path.join(process.cwd(), PAYRAM_MNEMONIC_FILE);
  if (fs.existsSync(file)) return fs.readFileSync(file, 'utf8').trim().split('\n')[0].trim();
  return null;
}

async function main() {
  const token = getToken();
  if (!token) {
    console.error('Missing PAYRAM_ACCESS_TOKEN or .payraminfo/headless-tokens.env with ACCESS_TOKEN');
    process.exit(1);
  }
  if (!PAYRAM_ETH_RPC_URL) {
    console.error('Missing PAYRAM_ETH_RPC_URL. Use e.g. https://ethereum-sepolia-rpc.publicnode.com (free, no key) or Alchemy/Infura.');
    process.exit(1);
  }

  const mnemonic = getMnemonic();
  if (!mnemonic) {
    console.error('Missing PAYRAM_MNEMONIC or mnemonic file at PAYRAM_MNEMONIC_FILE');
    process.exit(1);
  }

  const { ethers } = require('ethers');
  const wallet = ethers.Wallet.fromPhrase(mnemonic);
  const deployerAddress = wallet.address;

  // Fund collector: use env if valid 0x address, else use deployer (sweep to self)
  let fundCollector = (PAYRAM_FUND_COLLECTOR || '').trim();
  if (!fundCollector || !/^0x[a-fA-F0-9]{40}$/.test(fundCollector)) {
    fundCollector = deployerAddress;
    console.log('Using deployer address as fund collector (set PAYRAM_FUND_COLLECTOR for a different cold wallet):', deployerAddress);
  }

  if (PAYRAM_ETH_RPC_URL === 'https://ethereum-sepolia-rpc.publicnode.com') {
    console.log('Using default RPC: PublicNode Sepolia (free, no key)');
  }

  // 1) Get factory contract from API
  console.log('Fetching factory contract from API...');
  const factoryUrl = `${PAYRAM_API_URL}/api/v1/blockchain-contract/blockchain/${PAYRAM_BLOCKCHAIN_CODE}/contract/factory_contract`;
  const factoryRes = await fetch(factoryUrl, { headers: { Authorization: `Bearer ${token}` } });
  if (!factoryRes.ok) {
    console.error('Failed to get factory contract:', factoryRes.status, await factoryRes.text());
    process.exit(1);
  }
  const factoryData = await factoryRes.json();
  const factoryAddress = factoryData.address;
  const factoryId = factoryData.id;
  const abi = typeof factoryData.abi === 'string' ? JSON.parse(factoryData.abi) : factoryData.abi;
  if (!factoryAddress || !abi) {
    console.error('Factory contract missing address or abi');
    process.exit(1);
  }
  console.log('Factory contract OK:', factoryAddress);

  // 2) Connect wallet to RPC
  console.log('Connecting to RPC and building tx...');
  const provider = new ethers.JsonRpcProvider(PAYRAM_ETH_RPC_URL);
  const signer = wallet.connect(provider);

  // 3) Salt bytes32 (same idea as frontend: keccak256 of random)
  const salt = ethers.keccak256(ethers.toUtf8Bytes(`${Date.now()}-${Math.random().toString(36).slice(2)}`));

  // 4) Call createFundSweeperContract(salt, fundCollector)
  const contract = new ethers.Contract(factoryAddress, abi, signer);
  console.log('Sending deploy tx (createFundSweeperContract)...');
  const tx = await contract.createFundSweeperContract(salt, fundCollector, { gasLimit: 500000n });
  console.log('Tx sent, waiting for confirmation:', tx.hash);
  const receipt = await tx.wait();
  const txHash = receipt.hash;

  console.log('Deploy tx confirmed:', txHash);

  // 5) Register with backend
  const registerUrl = `${PAYRAM_API_URL}/api/v1/wallets/deposit/scw/blockchains_contract/${factoryId}`;
  const registerRes = await fetch(registerUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ name: PAYRAM_SCW_NAME, transactionHash: txHash }),
  });
  if (!registerRes.ok) {
    console.error('Failed to register SCW:', registerRes.status, await registerRes.text());
    process.exit(1);
  }
  const result = await registerRes.json();
  console.log('SCW registered:', JSON.stringify(result, null, 2));
  const raw = Array.isArray(result) ? result[0] : result;
  const walletId = raw && (raw.id ?? raw.ID);
  if (walletId != null) {
    console.log('PAYRAM_WALLET_ID=' + walletId);
    console.log('PAYRAM_WALLET_FAMILY=ETH_Family');
  } else {
    console.error('Could not read wallet id from response. Link wallet manually in dashboard.');
  }
}

main().catch((err) => {
  console.error(err);
  const url = err?.info?.requestUrl || '';
  if (err?.code === 'INSUFFICIENT_FUNDS') {
    console.error('\n→ Deployer address has 0 Sepolia ETH. Send testnet ETH to the deployer address shown above for gas.');
    console.error('  Faucets: https://sepoliafaucet.com or https://www.alchemy.com/faucets/ethereum-sepolia');
  } else if (String(url).includes('YOUR_ACTUAL') || String(url).includes('YOUR_KEY')) {
    console.error('\n→ Use a real RPC API key, not the placeholder. Get one at https://dashboard.alchemy.com or use PublicNode (default).');
  } else if (err?.code === 'SERVER_ERROR' && err?.info?.responseStatus === '401 Unauthorized') {
    console.error('\n→ RPC returned 401: check PAYRAM_ETH_RPC_URL uses a valid API key or use default (PublicNode).');
  }
  process.exit(1);
});
