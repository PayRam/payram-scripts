#!/usr/bin/env node
/**
 * Outputs JSON: { "mnemonic": "...", "xpub": "..." }
 * XPUB is Bitcoin BIP44 (m/44'/0'/0') for use with PayRam deposit wallet (BTC_Family).
 * Run from repo root: node scripts/generate-deposit-wallet.js
 * Requires: npm install in scripts/
 */
const bip39 = require('bip39');
const { BIP32Factory } = require('bip32');
const ecc = require('tiny-secp256k1');

const bip32 = BIP32Factory(ecc);
const mnemonic = bip39.generateMnemonic(128);
const seed = bip39.mnemonicToSeedSync(mnemonic);
const root = bip32.fromSeed(seed);
const account = root.derivePath("m/44'/0'/0'");
const xpub = account.neutered().toBase58();

console.log(JSON.stringify({ mnemonic, xpub }));
