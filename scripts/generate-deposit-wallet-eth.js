#!/usr/bin/env node
/**
 * Outputs JSON: { "mnemonic": "...", "xpub": "..." }
 * XPUB is Ethereum BIP44 (m/44'/60'/0') for use with PayRam deposit wallet (ETH_Family / EVM).
 * Same deps as generate-deposit-wallet.js (bip39, bip32, tiny-secp256k1).
 * Run: node scripts/generate-deposit-wallet-eth.js
 */
const bip39 = require('bip39');
const { BIP32Factory } = require('bip32');
const ecc = require('tiny-secp256k1');

const bip32 = BIP32Factory(ecc);
const mnemonic = bip39.generateMnemonic(128);
const seed = bip39.mnemonicToSeedSync(mnemonic);
const root = bip32.fromSeed(seed);
const account = root.derivePath("m/44'/60'/0'");
const xpub = account.neutered().toBase58();

console.log(JSON.stringify({ mnemonic, xpub, family: "ETH_Family" }));
