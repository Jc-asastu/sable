import test from 'node:test';
import assert from 'node:assert/strict';
import { pad } from 'viem';
import { multiplier, dollarDays, fillPoints } from '../src/points.js';
import { base58, fromBase58, recipientFor, tokenFor, gasFeeIn, SOLANA } from '../src/chain.js';

const DAY = 86_400;

test('points match the D18 examples', () => {
  assert.equal(multiplier(0), 1);
  assert.equal(multiplier(2_000).toFixed(2), '1.35'); // $1,000 for 2 days
  assert.equal(multiplier(7_000).toFixed(2), '1.66');
  assert.equal(multiplier(35_000).toFixed(2), '2.14');
  assert.equal(multiplier(350_000).toFixed(2), '2.86');
  assert.equal(multiplier(1e12), 3, 'capped');
  const now = 100 * DAY;
  const orders = [
    { usd: 1000, openedAt: now - 2 * DAY, closedAt: null }, // another order waiting 2 days
    { usd: 1000, openedAt: now, closedAt: now }, // the one filling now
  ];
  assert.equal(Math.round(fillPoints(orders, 1000, now)), 13_483, '1.348x of 10,000');
});

test('only the last 7 days count, and closed orders stop counting', () => {
  const now = 100 * DAY;
  assert.equal(dollarDays([{ usd: 1000, openedAt: now - 30 * DAY, closedAt: null }], now), 7_000);
  assert.equal(dollarDays([{ usd: 1000, openedAt: now - 30 * DAY, closedAt: now - 20 * DAY }], now), 0);
  assert.equal(dollarDays([{ usd: 500, openedAt: now - 3 * DAY, closedAt: now - 1 * DAY }], now), 1_000);
});

test('Solana keys round-trip through bytes32', () => {
  const mint = 'DEW9dSN6QpWyNthphCpMmAbZP1Q4cEKR9xQXAri98WDP';
  const bytes = fromBase58(mint);
  assert.equal(bytes.length, 32);
  assert.equal(base58(bytes), mint);
  const b32 = '0x' + Buffer.from(bytes).toString('hex');
  assert.equal(recipientFor(SOLANA, b32), mint);
  assert.equal(tokenFor(SOLANA, b32), mint, "Across names Solana tokens by mint");
});

test('EVM recipients and tokens come from the low 20 bytes', () => {
  const a = '0x64C5a9630C709F7454Feeb9302AC7a857F4774cF';
  assert.equal(recipientFor(56, pad(a)), a);
  assert.equal(tokenFor(8453, pad(a)), a);
});

test('gas fee is converted into the paid token and refused above the 5% cap', () => {
  // $0.002 of gas paid in USDC (1 unit = $0.000001) on a $300 fill
  assert.equal(gasFeeIn(0.002, 1e-6, 300_000_000n), 2000n);
  assert.equal(gasFeeIn(20, 1e-6, 300_000_000n), null, '$20 of gas on $300 breaks the cap');
  assert.equal(gasFeeIn(0.002, 0, 300_000_000n), null, 'no price, no fee guess');
});

test('each role signs with its own key, the old shared key covers both, and none means watch-only', async () => {
  const { signerFor } = await import('../src/signers.js');
  const k1 = '0x' + '11'.repeat(32), k2 = '22'.repeat(32);
  const a = await signerFor('filler', { FILLER_PRIVATE_KEY: k1, RELAYER_PRIVATE_KEY: k2 });
  const b = await signerFor('relayer', { FILLER_PRIVATE_KEY: k1, RELAYER_PRIVATE_KEY: k2 });
  assert.notEqual(a.address, b.address);
  const shared = await signerFor('relayer', { KEEPER_PRIVATE_KEY: k2 });
  assert.equal(shared.address, b.address);
  assert.equal(await signerFor('filler', {}), null);
  // Turnkey: the address is taken as given and no local key is read.
  const tk = await signerFor('filler', { TURNKEY_ORGANIZATION_ID: 'org', TURNKEY_FILLER_ADDRESS: a.address, TURNKEY_API_PUBLIC_KEY: '02' + '00'.repeat(32), TURNKEY_API_PRIVATE_KEY: '01'.repeat(32), FILLER_PRIVATE_KEY: k2 });
  assert.equal(tk.address, a.address);
  assert.equal(await signerFor('relayer', { TURNKEY_ORGANIZATION_ID: 'org' }), null);
});
