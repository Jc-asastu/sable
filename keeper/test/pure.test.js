import test from 'node:test';
import assert from 'node:assert/strict';
import { encodeFunctionData, pad } from 'viem';
import { multiplier, dollarDays, fillPoints } from '../src/points.js';
import { base58, fromBase58, recipientFor, currencyFor, depositIdFrom, gasFeeIn, depositoryAbi, SOLANA } from '../src/chain.js';

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

test('Solana keys round-trip through bytes32, and zero means native SOL', () => {
  const mint = 'DEW9dSN6QpWyNthphCpMmAbZP1Q4cEKR9xQXAri98WDP';
  const bytes = fromBase58(mint);
  assert.equal(bytes.length, 32);
  assert.equal(base58(bytes), mint);
  const b32 = '0x' + Buffer.from(bytes).toString('hex');
  assert.equal(recipientFor(SOLANA, b32), mint);
  assert.equal(currencyFor(SOLANA, '0x' + '00'.repeat(32)), '11111111111111111111111111111111');
});

test('EVM recipients and tokens come from the low 20 bytes', () => {
  const a = '0x64C5a9630C709F7454Feeb9302AC7a857F4774cF';
  assert.equal(recipientFor(56, pad(a)), a);
  assert.equal(currencyFor(8453, '0x' + '00'.repeat(32)), '0x0000000000000000000000000000000000000000');
});

test('a Relay deposit step is accepted only if it matches the deposit the contract makes', () => {
  const ctx = { depository: '0x4cd00e387622c35bddb9b4c962c136462338bc31', account: '0x12e053db3c550b591ac1bd12e610dc842ca58a73',
    token: '0x754704Bc059F8C67012fEd69BC8A327a5aafb603', amount: 298_000_000n };
  const id = '0x' + 'ab'.repeat(32);
  const data = (over = {}) => encodeFunctionData({ abi: depositoryAbi, functionName: 'depositErc20',
    args: [over.account ?? ctx.account, over.token ?? ctx.token, over.amount ?? ctx.amount, id] });
  assert.equal(depositIdFrom({ to: ctx.depository, value: '0', data: data() }, ctx), id);
  assert.throws(() => depositIdFrom({ to: '0x' + '11'.repeat(20), value: '0', data: data() }, ctx), /target/);
  assert.throws(() => depositIdFrom({ to: ctx.depository, value: '0', data: data({ amount: 1n }) }, ctx), /mismatch/);
  assert.throws(() => depositIdFrom({ to: ctx.depository, value: '0', data: data({ account: '0x' + '22'.repeat(20) }) }, ctx), /mismatch/);
  assert.throws(() => depositIdFrom({ to: ctx.depository, value: '5', data: data() }, ctx), /target/);
});

test('gas fee is converted into the paid token and refused above the 5% cap', () => {
  // $0.002 of gas paid in USDC (1 unit = $0.000001) on a $300 fill
  assert.equal(gasFeeIn(0.002, 1e-6, 300_000_000n), 2000n);
  assert.equal(gasFeeIn(20, 1e-6, 300_000_000n), null, '$20 of gas on $300 breaks the cap');
  assert.equal(gasFeeIn(0.002, 0, 300_000_000n), null, 'no price, no fee guess');
});
