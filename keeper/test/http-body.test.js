import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { encodeAbiParameters } from 'viem';

const FACTORY = `0x${'11'.repeat(20)}`;
const REGISTRY = `0x${'22'.repeat(20)}`;
const KEEPER = `0x${'33'.repeat(20)}`;
const MULTICALL = '0xcA11bde05977b3631167028862bE2a173976CA11';
const keeperScript = fileURLToPath(new URL('../src/index.js', import.meta.url));
const keeperDir = fileURLToPath(new URL('../', import.meta.url));
const registryResult = `0x${'0'.repeat(24)}${REGISTRY.slice(2)}`;
const multicallResult = encodeAbiParameters([
  { type: 'tuple[]', components: [{ name: 'success', type: 'bool' }, { name: 'returnData', type: 'bytes' }] },
], [[{ success: true, returnData: registryResult }]]);

const listen = (server) => new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const close = (server) => new Promise((resolve) => server.close(resolve));

test('POST routes reject malformed body and field types without stopping the server', async (t) => {
  const rpc = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const request = JSON.parse(Buffer.concat(chunks).toString());
    const response = (call) => ({
      jsonrpc: '2.0', id: call.id,
      result: call.method === 'eth_call' ? (call.params?.[0]?.to?.toLowerCase() === MULTICALL.toLowerCase() ? multicallResult : registryResult)
        : call.method === 'eth_chainId' ? '0x8f' : '0x0',
    });
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify(Array.isArray(request) ? request.map(response) : response(request)));
  });
  await listen(rpc);

  const portProbe = http.createServer();
  await listen(portProbe);
  const port = portProbe.address().port;
  await close(portProbe);

  const stateFile = join(tmpdir(), `sable-http-body-${randomUUID()}.json`);
  const child = spawn(process.execPath, [keeperScript], {
    cwd: keeperDir,
    env: {
      FACTORY, START_BLOCK: '1', KEEPER_ADDRESS: KEEPER,
      RPC_URL: `http://127.0.0.1:${rpc.address().port}`,
      PORT: String(port), STATE_FILE: stateFile,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill();
      await new Promise((resolve) => child.once('exit', resolve));
    }
    await close(rpc);
    if (existsSync(stateFile)) unlinkSync(stateFile);
  });

  await new Promise((resolve, reject) => {
    let output = '';
    const timeout = setTimeout(() => reject(new Error(`keeper did not start: ${output}`)), 5_000);
    child.stdout.on('data', (chunk) => {
      output += chunk;
      if (output.includes(`listening on :${port}`)) { clearTimeout(timeout); resolve(); }
    });
    child.stderr.on('data', (chunk) => { output += chunk; });
    child.once('exit', (code) => { clearTimeout(timeout); reject(new Error(`keeper exited before listening: ${code} ${output}`)); });
  });

  const post = async (route, body) => {
    const response = await fetch(`http://127.0.0.1:${port}${route}`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body,
      signal: AbortSignal.timeout(3_000),
    });
    return { status: response.status, body: await response.json() };
  };

  const objectErrors = {
    '/relay': 'account and calldata required',
    '/open': 'owner, agent, routers and sig required',
    '/secret': 'account, id and secret required',
  };
  for (const route of Object.keys(objectErrors)) {
    for (const body of ['null', '[]', '0', '"text"', 'true']) {
      assert.deepEqual(await post(route, body), { status: 400, body: { error: 'json object required' } });
    }
    assert.deepEqual(await post(route, '{'), { status: 400, body: { error: 'json body required' } });
    assert.deepEqual(await post(route, '{}'), { status: 400, body: { error: objectErrors[route] } });
    assert.deepEqual(await post(route, '{"chainId":999}'), { status: 400, body: { error: 'unsupported chain' } });
    for (const chainId of [null, 143, '143']) {
      assert.deepEqual(await post(route, JSON.stringify({ chainId })), { status: 400, body: { error: objectErrors[route] } });
    }
    for (const chainId of [[], true, { toString: null }]) {
      assert.deepEqual(await post(route, JSON.stringify({ chainId })), { status: 400, body: { error: 'unsupported chain' } });
    }
  }

  assert.deepEqual(await post('/relay', JSON.stringify({ account: { toString: null }, data: '0x' })),
    { status: 400, body: { error: objectErrors['/relay'] } });

  const open = { owner: FACTORY, agent: REGISTRY, routers: [KEEPER], sig: '0x' };
  for (const invalid of [
    { owner: { toString: null } },
    { agent: { toString: null } },
    { routers: [{ toString: null }] },
  ]) {
    assert.deepEqual(await post('/open', JSON.stringify({ ...open, ...invalid })),
      { status: 400, body: { error: objectErrors['/open'] } });
  }

  const health = await fetch(`http://127.0.0.1:${port}/health`);
  assert.equal(health.status, 200);
  assert.equal((await health.json()).ok, true);
});
