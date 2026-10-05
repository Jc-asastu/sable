import test from 'node:test';
import assert from 'node:assert/strict';
import { onRegistryEvent, onLocalFill, onFillRate, onBalance, LIMITS } from '../src/rules.js';

test('every registry change alerts; grants and ownership moves are critical', () => {
  assert.equal(onRegistryEvent({ eventName: 'KeeperSet', args: { keeper: '0xk', allowed: true } })[0].level, 'critical');
  assert.equal(onRegistryEvent({ eventName: 'KeeperSet', args: { keeper: '0xk', allowed: false } })[0].level, 'info');
  assert.equal(onRegistryEvent({ eventName: 'OwnershipTransferStarted', args: {} })[0].level, 'critical');
  assert.equal(onRegistryEvent({ eventName: 'FeeSet', args: { feeBps: 30n } })[0].level, 'info');
  assert.deepEqual(onRegistryEvent({ eventName: 'Transfer', args: {} }), []);
});

test('fills well below a fresh quote strike the keeper, and three in an hour revoke it', () => {
  const strikes = new Map();
  const fill = (at, amountOut) => onLocalFill({ keeper: '0xk', amountOut, quoteOut: 1_000n, at, tx: '0xt' }, strikes);
  assert.deepEqual(fill(0, 990n), [], 'within 2% of the quote is fine');
  assert.equal(fill(0, 900n).length, 1);
  assert.equal(fill(100, 900n).length, 1);
  const third = fill(200, 900n);
  assert.deepEqual(third.map((a) => a.kind), ['alert', 'revokeKeeper', 'alert']);
  assert.equal(third[1].keeper, '0xk');
  assert.equal(fill(10_000, 900n).length, 1, 'old strikes age out of the window');
});

test('a burst of fills pauses cross-chain fills once', () => {
  assert.deepEqual(onFillRate(LIMITS.fillsPerMinute, false), []);
  assert.deepEqual(onFillRate(LIMITS.fillsPerMinute + 1, false).map((a) => a.kind), ['pauseCross', 'alert']);
  assert.deepEqual(onFillRate(100, true), [], 'no repeat while paused');
});

test('role wallets under their floor warn', () => {
  assert.equal(onBalance({ role: 'filler', address: '0xf', balance: 5n, floor: 10n, symbol: 'MON' }).length, 1);
  assert.equal(onBalance({ role: 'filler', address: '0xf', balance: 10n, floor: 10n, symbol: 'MON' }).length, 0);
});
