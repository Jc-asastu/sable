import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { encodeFunctionData, pad, parseAbi } from 'viem';
import { createLedger } from '../src/ledger.js';
import { createFiller } from '../src/filler.js';
import { createRelay } from '../src/relay.js';
import { depositoryAbi, SOLANA } from '../src/chain.js';

const DAY = 86_400;
const A = (n) => `0x${n.toString(16).padStart(40, '0')}`;
const USDC = '0x754704Bc059F8C67012fEd69BC8A327a5aafb603';
const WMON = '0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A';
const FACTORY = A(0xfac), REGISTRY = A(0x7e9), DEPOSITORY = '0x4cd00e387622c35bddb9b4c962c136462338bc31';
const ACCOUNT = A(0xacc), OWNER = A(0x0e1), KEEPER = A(0x6ee), MEME = A(0x111);

// ── ledger ──

test('ledger discovers accounts and orders, and a fill earns D18 points', async () => {
  const t0 = 1_800_000_000;
  const events = [
    { block: 10n, address: FACTORY, eventName: 'AccountCreated', args: { owner: OWNER, account: ACCOUNT } },
    { block: 20n, address: ACCOUNT, eventName: 'OrderPlaced', args: { id: 1n, tokenIn: USDC, vault: A(1), amountIn: 1_000_000_000n, destChainId: 0 } },
    { block: 30n, address: ACCOUNT, eventName: 'OrderPlaced', args: { id: 2n, tokenIn: USDC, vault: A(1), amountIn: 1_000_000_000n, destChainId: 0 } },
    { block: 230n, address: ACCOUNT, eventName: 'OrderFilled', args: { id: 2n, spent: 1_000_000_000n, amountOut: 1n, yieldKept: 0n } },
  ];
  const time = { 20n: t0, 30n: t0 + 2 * DAY, 230n: t0 + 2 * DAY };
  const pub = {
    getBlockNumber: async () => 250n,
    getBlock: async ({ blockNumber }) => ({ timestamp: BigInt(time[blockNumber] ?? t0) }),
    getLogs: async ({ address, fromBlock, toBlock }) => events
      .filter((e) => e.block >= fromBlock && e.block <= toBlock && (Array.isArray(address) ? address.map((x) => x.toLowerCase()).includes(e.address.toLowerCase()) : address === e.address))
      .filter((e) => (address === FACTORY) === (e.eventName === 'AccountCreated'))
      .map((e, i) => ({ ...e, blockNumber: e.block, logIndex: i })),
  };
  const stateFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'keeper-')), 'state.json');
  const ledger = createLedger({ pub, factory: FACTORY, usdc: USDC, stateFile, startBlock: 1n, log() {} });
  assert.equal(await ledger.sync(), 250n);
  assert.equal(ledger.openOrders().length, 1, 'order 1 still open');
  // $1,000 filled while another $1,000 had waited 2 days → 10,000 × 1.348
  assert.equal(ledger.pointsOf(OWNER).points, 13_483);
  assert.ok(ledger.isAccount(ACCOUNT));

  const again = createLedger({ pub, factory: FACTORY, usdc: USDC, stateFile, startBlock: 1n, log() {} });
  assert.equal(again.cursor, 250n, 'resumes from its saved cursor');
  assert.equal(await again.sync(), 0n);
  assert.equal(again.pointsOf(OWNER).points, 13_483);
});

// ── filler ──

function fillerHarness({ order, value, kyberOut, relayOut, depositOverride, wallet = true }) {
  const sent = [], logs = [];
  const pub = {
    readContract: async ({ functionName }) => ({
      fee: [30, A(0x7ea)], relayDepository: DEPOSITORY, order: { p: order, shares: 1n }, orderValue: value,
    })[functionName],
    getGasPrice: async () => 100_000_000_000n,
    estimateContractGas: async () => 600_000n,
    simulateContract: async (r) => r,
    waitForTransactionReceipt: async () => ({ status: 'success' }),
  };
  globalThis.fetch = async (url, options) => {
    const body = (x) => ({ ok: true, json: async () => x });
    if (url.includes('tokenIn=' + WMON)) return body({ data: { routeSummary: { amountOut: '3000000' } } }); // MON = $0.03
    if (url.includes('/routes')) return body({ data: { routeSummary: { amountOut: String(kyberOut), amountOutUsd: '300' } } });
    if (url.includes('/route/build')) return body({ data: { amountOut: String(kyberOut), routerAddress: A(0x60), data: '0xdeadbeef' } });
    if (url.includes('relay.link/quote')) {
      const amount = BigInt(JSON.parse(options.body).amount);
      const data = encodeFunctionData({ abi: depositoryAbi, functionName: 'depositErc20', args: [ACCOUNT, USDC, depositOverride ?? amount, pad('0x01')] });
      return body({ details: { currencyOut: { amount: String(relayOut), amountFormatted: '2.5', currency: { symbol: 'SOL' } } },
        steps: [{ id: 'deposit', items: [{ data: { to: DEPOSITORY, value: '0', data } }] }] });
    }
    throw new Error('unexpected ' + url);
  };
  const filler = createFiller({ pub, wallet: wallet ? { writeContract: async (r) => { sent.push(r); return '0xhash'; } } : null,
    keeper: KEEPER, registry: REGISTRY, wmon: WMON, usdc: USDC, log: (m) => logs.push(m) });
  return { filler, sent, logs };
}
const local = (minOut) => ({ tokenIn: USDC, vault: A(1), tokenOut: MEME, deadline: 9_999_999_999n, destChainId: 0, amountIn: 300_000_000n, minOut, destMinOut: 0n, recipient: pad('0x00'), destToken: pad('0x00') });
const cross = (destMinOut) => ({ ...local(0n), tokenOut: '0x0000000000000000000000000000000000000000', destChainId: SOLANA, destMinOut, recipient: '0x' + 'ab'.repeat(32) });
const open = [{ account: ACCOUNT, id: '1' }];

test('a local order waits below its limit and fills at it, paying gas in the bought token', async () => {
  const below = fillerHarness({ order: local(1_000n * 10n ** 18n), value: 300_000_000n, kyberOut: 999n * 10n ** 18n });
  await below.filler.tick(open);
  assert.equal(below.sent.length, 0);

  const at = fillerHarness({ order: local(1_000n * 10n ** 18n), value: 303_000_000n, kyberOut: 1_010n * 10n ** 18n });
  await at.filler.tick(open);
  assert.equal(at.sent.length, 1);
  assert.equal(at.sent[0].functionName, 'fillOrder');
  const [, router, data, gasFee] = at.sent[0].args;
  assert.equal(router, A(0x60));
  assert.equal(data, '0xdeadbeef');
  assert.ok(gasFee > 0n && gasFee < 10n ** 18n, 'about $0.002 of gas, in MEME units');
});

test('a cross-chain order fills only when Relay quotes its minimum, with the exact deposit', async () => {
  const short = fillerHarness({ order: cross(2_600_000_000n), value: 300_000_000n, relayOut: 2_527_000_000n });
  await short.filler.tick(open);
  assert.equal(short.sent.length, 0);

  const ok = fillerHarness({ order: cross(2_500_000_000n), value: 300_000_000n, relayOut: 2_527_000_000n });
  await ok.filler.tick(open);
  assert.equal(ok.sent.length, 1);
  assert.equal(ok.sent[0].functionName, 'fillCrossOrder');
  assert.equal(ok.sent[0].args[1], pad('0x01'), "Relay's deposit id");

  const tampered = fillerHarness({ order: cross(2_500_000_000n), value: 300_000_000n, relayOut: 2_527_000_000n, depositOverride: 1n });
  await tampered.filler.tick(open);
  assert.equal(tampered.sent.length, 0, 'a deposit that differs from what the contract pays is refused');
  assert.match(tampered.logs.join('\n'), /mismatch/);
});

test('expired orders are returned to the account, and watch-only mode sends nothing', async () => {
  const expired = fillerHarness({ order: { ...local(1n), deadline: 1n }, value: 300_000_000n, kyberOut: 1n });
  await expired.filler.tick(open);
  assert.equal(expired.sent[0].functionName, 'cancelOrder');

  const watch = fillerHarness({ order: local(1n), value: 300_000_000n, kyberOut: 10n ** 18n, wallet: false });
  await watch.filler.tick(open);
  assert.equal(watch.sent.length, 0);
  assert.match(watch.logs.join('\n'), /watch-only.*fillOrder/);
});

// ── relay ──

test('the relayer only sends agent-signed calls for real Sable accounts, within rate limits', async () => {
  const sent = [];
  const pub = {
    readContract: async ({ functionName, args }) => (functionName === 'owner' ? OWNER : args[0] === OWNER ? ACCOUNT : A(0xbad)),
    getGasPrice: async () => 1n, estimateGas: async () => 100_000n,
  };
  const { relay } = createRelay({ pub, wallet: { sendTransaction: async (tx) => { sent.push(tx); return '0xhash'; } }, keeper: KEEPER, factory: FACTORY, log() {} });
  const cancel = encodeFunctionData({ abi: parseAbi(['function cancelOrderWithSig(uint256 id, uint256 nonce, uint256 deadline, uint64 epoch, bytes sig)']),
    functionName: 'cancelOrderWithSig', args: [1n, 2n, 3n, 0n, '0x1234'] });
  const ownerOnly = encodeFunctionData({ abi: parseAbi(['function withdraw(address token, uint256 amount, address to)']),
    functionName: 'withdraw', args: [USDC, 1n, KEEPER] });

  assert.deepEqual(await relay({ account: ACCOUNT, data: cancel }, 'ip1'), { status: 200, hash: '0xhash' });
  assert.equal(sent[0].to, ACCOUNT);
  assert.equal((await relay({ account: ACCOUNT, data: ownerOnly }, 'ip1')).status, 400, 'owner-only functions are not relayed');
  assert.equal((await relay({ account: A(0xdead), data: cancel }, 'ip1')).status, 400, 'not a Sable account');
  assert.equal((await relay({ account: ACCOUNT, data: 'nothex' }, 'ip1')).status, 400);

  let limited;
  for (let i = 0; i < 40; i++) limited = await relay({ account: ACCOUNT, data: cancel }, 'ip2');
  assert.equal(limited.status, 429, 'per-account rate limit');
});

test('sponsored opening sends createAccountFor to the factory, and refuses bad input or a reverting signature', async () => {
  const sent = [];
  let reverts = false;
  const pub = { getGasPrice: async () => 1n, estimateContractGas: async () => { if (reverts) throw Object.assign(new Error('x'), { shortMessage: 'BadSignature' }); return 200_000n; } };
  const { open } = createRelay({ pub, wallet: { writeContract: async (tx) => { sent.push(tx); return '0xopen'; } }, keeper: KEEPER, factory: FACTORY, log() {} });
  const req = { owner: OWNER, agent: A(0xa9e), routers: [A(0x1234)], cooldown: 0, deadline: 9_999_999_999, sig: '0x1234' };

  assert.deepEqual(await open(req, 'ip9'), { status: 200, hash: '0xopen' });
  assert.equal(sent[0].address, FACTORY);
  assert.equal(sent[0].functionName, 'createAccountFor');
  assert.equal(sent[0].args[0], OWNER);
  assert.equal((await open({ ...req, sig: 'nothex' }, 'ip9')).status, 400);
  assert.equal((await open({ ...req, routers: 'x' }, 'ip9')).status, 400);
  reverts = true;
  assert.deepEqual(await open(req, 'ip9'), { status: 422, error: 'BadSignature' });
  const watch = createRelay({ pub, wallet: null, keeper: KEEPER, factory: FACTORY, log() {} });
  assert.equal((await watch.open(req, 'ip8')).status, 503);
});
