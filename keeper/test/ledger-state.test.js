import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createLedger } from '../src/ledger.js';

const FACTORY = `0x${'11'.repeat(20)}`;
const USDC = `0x${'22'.repeat(20)}`;
const tempRoot = fs.realpathSync(os.tmpdir());
const ledgerAt = (stateFile) => createLedger({ pub: {}, factory: FACTORY, usdc: USDC, stateFile, startBlock: 10n });

function temporaryStateFile(t) {
  const directory = fs.mkdtempSync(path.join(tempRoot, 'sable-ledger-state-'));
  t.after(() => {
    const resolved = fs.realpathSync(directory);
    if (path.dirname(resolved) !== tempRoot || !path.basename(resolved).startsWith('sable-ledger-state-')) {
      throw new Error('Refusing to remove an unexpected temporary directory');
    }
    fs.rmSync(resolved, { recursive: true, force: true });
  });
  return path.join(directory, 'state.json');
}

test('a missing state file starts from the configured block', (t) => {
  const stateFile = temporaryStateFile(t);
  assert.equal(ledgerAt(stateFile).cursor, 9n);
  assert.equal(fs.existsSync(stateFile), false);
});

test('a valid saved state resumes from its cursor', (t) => {
  const stateFile = temporaryStateFile(t);
  fs.writeFileSync(stateFile, JSON.stringify({ cursor: '23', accounts: {}, orders: {}, points: {}, secrets: {} }));
  assert.equal(ledgerAt(stateFile).cursor, 23n);
});

test('malformed state fails without exposing or replacing its contents', (t) => {
  const stateFile = temporaryStateFile(t);
  const contents = '{"secrets":{"hidden":"PRIVATE_LIMIT_MARKER"},"cursor":';
  fs.writeFileSync(stateFile, contents);

  assert.throws(() => ledgerAt(stateFile), (error) => {
    assert.match(error.message, /Invalid keeper state JSON/);
    assert.doesNotMatch(String(error.stack), /PRIVATE_LIMIT_MARKER/);
    return true;
  });
  assert.equal(fs.readFileSync(stateFile, 'utf8'), contents);
  assert.equal(fs.existsSync(`${stateFile}.tmp`), false);
});

test('a denied state read fails instead of starting fresh', () => {
  const stateFile = 'synthetic-denied-state.json';
  const originalRead = fs.readFileSync;
  fs.readFileSync = (file, ...args) => {
    if (file === stateFile) {
      const error = new Error('permission denied');
      error.code = 'EACCES';
      throw error;
    }
    return originalRead.call(fs, file, ...args);
  };
  try {
    assert.throws(() => ledgerAt(stateFile), /Cannot read keeper state \(EACCES\)/);
  } finally {
    fs.readFileSync = originalRead;
  }
});
