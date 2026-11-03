import test from 'node:test';
import assert from 'node:assert/strict';
import { sendAlert } from '../src/alert.js';

test('logs and posts an alert when the webhook succeeds', async () => {
  const logs = [];
  const calls = [];
  await sendAlert({ level: 'critical', text: 'guardian failed' }, {
    webhook: 'https://example.invalid/alerts',
    log: (message) => logs.push(message),
    fetchImpl: async (...args) => { calls.push(args); return { ok: true, status: 204 }; },
  });

  assert.deepEqual(logs, ['CRITICAL guardian failed']);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], 'https://example.invalid/alerts');
  assert.equal(calls[0][1].method, 'POST');
  assert.equal(calls[0][1].headers['content-type'], 'application/json');
  assert.deepEqual(JSON.parse(calls[0][1].body), { text: '[sable critical] guardian failed' });
});

test('logs a non-2xx webhook response as a delivery failure', async () => {
  const logs = [];
  await sendAlert({ level: 'critical', text: 'guardian failed' }, {
    webhook: 'https://example.invalid/alerts',
    log: (message) => logs.push(message),
    fetchImpl: async () => ({ ok: false, status: 500 }),
  });

  assert.deepEqual(logs, ['CRITICAL guardian failed', 'alert webhook failed: HTTP 500']);
});

test('logs a rejected webhook request without interrupting monitoring', async () => {
  const logs = [];
  await sendAlert({ level: 'warning', text: 'low balance' }, {
    webhook: 'https://example.invalid/alerts',
    log: (message) => logs.push(message),
    fetchImpl: async () => { throw new Error('connection refused'); },
  });

  assert.deepEqual(logs, ['WARNING low balance', 'alert webhook failed: connection refused']);
});

test('logs locally without posting when no webhook is configured', async () => {
  const logs = [];
  let called = false;
  await sendAlert({ level: 'info', text: 'registry updated' }, {
    webhook: '',
    log: (message) => logs.push(message),
    fetchImpl: async () => { called = true; },
  });

  assert.deepEqual(logs, ['INFO registry updated']);
  assert.equal(called, false);
});
