import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ACCOUNT = `0x${'11'.repeat(20)}`;
const TOKEN_IN = `0x${'22'.repeat(20)}`;
const TOKEN_OUT = `0x${'33'.repeat(20)}`;
const script = fileURLToPath(new URL('./kyber-fixture.mjs', import.meta.url));
const tempRoot = realpathSync(tmpdir());
const fetchStub = `globalThis.fetch = async (url) => ({
  json: async () => String(url).endsWith('/route/build')
    ? { code: 0, data: { amountOut: '1000', routerAddress: '${ACCOUNT}', amountIn: '1000000', data: '0xab' } }
    : { code: 0, data: { routeSummary: { amountOut: '1000' } } },
});`;
const preload = `data:text/javascript,${encodeURIComponent(fetchStub)}`;

function withTemporaryCwd(run) {
  const cwd = mkdtempSync(join(tempRoot, 'sable-kyber-fixture-'));
  try {
    return run(cwd);
  } finally {
    const resolved = realpathSync(cwd);
    if (dirname(resolved) !== tempRoot || !basename(resolved).startsWith('sable-kyber-fixture-')) {
      throw new Error('Refusing to remove an unexpected temporary directory');
    }
    rmSync(resolved, { recursive: true, force: true });
  }
}

function runFixture(cwd, args) {
  execFileSync(process.execPath, ['--import', preload, script, ...args], { cwd, encoding: 'utf8' });
}

test('writes the default fixture under its default parent', () => withTemporaryCwd((cwd) => {
  runFixture(cwd, [ACCOUNT]);
  const fixture = JSON.parse(readFileSync(join(cwd, 'test/fixtures/kyber-usdc-wmon.json'), 'utf8'));
  assert.equal(fixture.account, ACCOUNT);
  assert.equal(fixture.minOut, '990');
}));

test('creates the parent of a nested custom fixture path', () => withTemporaryCwd((cwd) => {
  const output = 'test/fixtures/alternate/route.json';
  runFixture(cwd, [ACCOUNT, '1000000', 'monad', TOKEN_IN, TOKEN_OUT, output]);
  const fixture = JSON.parse(readFileSync(join(cwd, output), 'utf8'));
  assert.equal(fixture.account, ACCOUNT);
  assert.equal(fixture.minOut, '990');
}));
