// Sable monitor: follows the registry and every account on each chain, judges each fill and admin
// change with rules.js, and acts through the registry's guardian role (revoke a keeper, pause
// cross-chain fills). Runs apart from the keeper, with its own key, so a compromised keeper can't
// silence it. Alerts go to ALERT_WEBHOOK (POST {text}) and to the log.
import fs from 'node:fs';
import { createPublicClient, createWalletClient, http, fallback, parseAbi, defineChain, getAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { onRegistryEvent, onLocalFill, onFillRate, onBalance } from './rules.js';

const env = process.env;
const need = (k) => { if (!env[k]) throw new Error(`${k} is required`); return env[k]; };
const log = (m) => console.log(new Date().toISOString(), m);
const CHUNK = 100n; // Monad's eth_getLogs serves at most 100 blocks per call

const CHAINS = [
  { id: 143, name: 'Monad', sym: 'MON', kyber: 'monad', rpc: env.RPC_URL || 'https://rpc.monad.xyz', factory: need('FACTORY'), start: need('START_BLOCK'), stateFile: env.STATE_FILE || 'monitor.json', floor: 2n * 10n ** 18n },
  env.BASE_FACTORY && { id: 8453, name: 'Base', sym: 'ETH', kyber: 'base', rpc: env.BASE_RPC_URL || 'https://mainnet.base.org', factory: env.BASE_FACTORY, start: need('BASE_START_BLOCK'), stateFile: env.BASE_STATE_FILE || 'monitor-base.json', floor: 5n * 10n ** 14n },
].filter(Boolean);

const factoryAbi = parseAbi(['event AccountCreated(address indexed owner, address account)', 'function registry() view returns (address)']);
const registryAbi = parseAbi([
  'event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)',
  'event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)',
  'event KeeperSet(address indexed keeper, bool allowed)',
  'event VaultSet(address indexed vault, bool allowed)',
  'event AcrossSpokePoolSet(address indexed pool)',
  'event GuardianSet(address indexed guardian)',
  'event Listed(address indexed token, uint128 perTrade, uint128 daily)',
  'event Delisted(address indexed token)',
  'event FeeSet(uint16 feeBps, address feeRecipient)',
  'event Paused(bool newOrders, bool crossFills)',
  'event OrderBoundsSet(address indexed token, uint128 minAmount, uint128 maxCross)',
  'function fee() view returns (uint16, address)',
  'function newOrdersPaused() view returns (bool)',
  'function crossFillsPaused() view returns (bool)',
  'function revokeKeeper(address keeper)',
  'function setPaused(bool newOrders, bool crossFills)',
]);
const accountAbi = parseAbi([
  'event OrderFilled(uint256 indexed id, uint256 spent, uint256 amountOut, uint256 yieldKept)',
  'event Swapped(address indexed by, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut)',
]);

async function alert({ level, text }) {
  log(`${level.toUpperCase()} ${text}`);
  if (!env.ALERT_WEBHOOK) return;
  await fetch(env.ALERT_WEBHOOK, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: `[sable ${level}] ${text}` }) })
    .catch((e) => log(`alert webhook failed: ${e.message}`));
}

const guardianKey = env.GUARDIAN_PRIVATE_KEY?.trim();
const guardian = guardianKey ? privateKeyToAccount(guardianKey.startsWith('0x') ? guardianKey : `0x${guardianKey}`) : null;
// Role wallets to keep fed, "role:0xaddress" comma-separated (e.g. relayer, filler).
const watched = (env.WATCH_BALANCES || '').split(',').map((s) => s.trim()).filter(Boolean).map((s) => { const [role, address] = s.split(':'); return { role, address: getAddress(address) }; });

for (const c of CHAINS) {
  const chain = defineChain({ id: c.id, name: c.name, nativeCurrency: { name: c.sym, symbol: c.sym, decimals: 18 }, rpcUrls: { default: { http: c.rpc.split(',') } } });
  const transport = fallback(c.rpc.split(',').map((u) => http(u.trim(), { timeout: 15_000 })));
  const pub = createPublicClient({ chain, transport });
  const wallet = guardian ? createWalletClient({ chain, transport, account: guardian }) : null;
  const factory = getAddress(c.factory);
  const registry = await pub.readContract({ address: factory, abi: factoryAbi, functionName: 'registry' });
  const say = (a) => alert({ ...a, text: `[${c.name}] ${a.text}` });

  let state = { cursor: String(BigInt(c.start) - 1n), accounts: [] };
  try { state = { ...state, ...JSON.parse(fs.readFileSync(c.stateFile, 'utf8')) }; } catch { /* first run */ }
  const save = () => { fs.writeFileSync(`${c.stateFile}.tmp`, JSON.stringify(state)); fs.renameSync(`${c.stateFile}.tmp`, c.stateFile); };
  const strikes = new Map(), fillTimes = [];

  async function act(actions) {
    for (const a of actions) {
      if (a.kind === 'alert') { await say(a); continue; }
      if (!wallet) { await say({ level: 'critical', text: `would ${a.kind} ${a.keeper ?? ''} but no guardian key is set` }); continue; }
      const request = a.kind === 'revokeKeeper'
        ? { address: registry, abi: registryAbi, functionName: 'revokeKeeper', args: [a.keeper] }
        : { address: registry, abi: registryAbi, functionName: 'setPaused', args: [await pub.readContract({ address: registry, abi: registryAbi, functionName: 'newOrdersPaused' }), true] };
      const hash = await wallet.writeContract(request);
      await say({ level: 'critical', text: `guardian ${a.kind} sent: ${hash}` });
    }
  }

  /** A fill's output against what Kyber quotes for the same swap right now. */
  async function quote(tokenIn, tokenOut, amountIn) {
    const r = await fetch(`https://aggregator-api.kyberswap.com/${c.kyber}/api/v1/routes?tokenIn=${tokenIn}&tokenOut=${tokenOut}&amountIn=${amountIn}`, { headers: { 'x-client-id': 'sable-monitor' }, signal: AbortSignal.timeout(8_000) });
    return r.ok ? BigInt((await r.json()).data?.routeSummary?.amountOut ?? 0) : 0n;
  }

  async function pass() {
    const head = await pub.getBlockNumber();
    for (let from = BigInt(state.cursor) + 1n; from <= head; from += CHUNK) {
      const to = from + CHUNK - 1n > head ? head : from + CHUNK - 1n;
      for (const l of await pub.getLogs({ address: factory, event: factoryAbi[0], fromBlock: from, toBlock: to })) state.accounts.push(l.args.account);
      for (const l of await pub.getLogs({ address: registry, events: registryAbi.filter((x) => x.type === 'event'), fromBlock: from, toBlock: to })) await act(onRegistryEvent(l));
      if (state.accounts.length) {
        const logs = await pub.getLogs({ address: state.accounts, events: accountAbi, fromBlock: from, toBlock: to });
        const swaps = new Map(logs.filter((l) => l.eventName === 'Swapped').map((l) => [l.transactionHash, l]));
        for (const l of logs.filter((x) => x.eventName === 'OrderFilled')) {
          fillTimes.push(Date.now());
          const swap = swaps.get(l.transactionHash); // a local fill swaps in the same transaction; a cross fill doesn't
          if (!swap) continue;
          const tx = await pub.getTransaction({ hash: l.transactionHash });
          const quoteOut = await quote(swap.args.tokenIn, swap.args.tokenOut, swap.args.amountIn).catch(() => 0n);
          await act(onLocalFill({ keeper: tx.from, amountOut: swap.args.amountOut, quoteOut, at: Math.floor(Date.now() / 1000), tx: l.transactionHash }, strikes));
        }
      }
      state.cursor = String(to);
      save();
    }
    while (fillTimes.length && Date.now() - fillTimes[0] > 60_000) fillTimes.shift();
    await act(onFillRate(fillTimes.length, await pub.readContract({ address: registry, abi: registryAbi, functionName: 'crossFillsPaused' })));
    for (const w of watched) await act(onBalance({ ...w, balance: await pub.getBalance({ address: w.address }), floor: c.floor, symbol: c.sym }));
  }

  const loop = async () => { try { await pass(); } catch (e) { log(`[${c.name}] pass: ${e.shortMessage ?? e.message}`); } setTimeout(loop, 5_000); };
  log(`[${c.name}] watching factory ${factory} · registry ${registry} · guardian ${guardian?.address ?? 'none (alerts only)'}`);
  loop();
}
