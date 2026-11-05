import test from 'node:test';
import assert from 'node:assert/strict';
import { createTickQueue } from '../src/tick-queue.js';

test('a failed tick rejects its caller but does not block the next tick', async () => {
  const calls = [];
  const tick = createTickQueue(async (orders) => {
    calls.push(orders);
    if (calls.length === 1) throw new Error('temporary RPC failure');
    return 'processed';
  });

  await assert.rejects(tick(['first']), /temporary RPC failure/);
  assert.equal(await tick(['second']), 'processed');
  assert.deepEqual(calls, [['first'], ['second']]);
});

test('ticks remain serialized while the current tick is pending', async () => {
  let startFirst;
  let finishFirst;
  const firstStarted = new Promise((resolve) => { startFirst = resolve; });
  const firstPending = new Promise((resolve) => { finishFirst = resolve; });
  const calls = [];
  const tick = createTickQueue(async (orders) => {
    calls.push(orders);
    if (orders[0] === 'first') {
      startFirst();
      await firstPending;
    }
  });

  const first = tick(['first']);
  const second = tick(['second']);
  await firstStarted;
  assert.deepEqual(calls, [['first']]);
  finishFirst();
  await Promise.all([first, second]);
  assert.deepEqual(calls, [['first'], ['second']]);
});
