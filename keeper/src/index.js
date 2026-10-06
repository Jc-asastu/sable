// Sable keeper: follows accounts and orders, fills orders at their limit, returns expired ones,
// relays agent-signed calls and serves points. Configuration comes only from the environment;
// keys are never written anywhere (set them in Railway's variables, or keep them in Turnkey).
//
//   FACTORY=0x…  START_BLOCK=<factory deploy block>  [keys, see signers.js]  node src/index.js
//
// Without a filler key it runs watch-only: it reads, computes points and logs what it
// would send (KEEPER_ADDRESS must then name a registered keeper so simulations pass).
import http from 'node:http';
import { createPublicClient, http as rpcHttp, fallback, defineChain, getAddress } from 'viem';
import { factoryAbi, accountAbi, commitOf } from './chain.js';
import { createLedger } from './ledger.js';
import { createFiller } from './filler.js';
import { createRelay } from './relay.js';
import { createSender } from './sender.js';
import { ROLES, signerFor } from './signers.js';

const env = process.env;
const need = (name) => { if (!env[name]) throw new Error(`${name} is required`); return env[name]; };
const ORIGINS = (env.ALLOWED_ORIGIN || 'https://sabledex.vercel.app').split(',').map((o) => o.trim()); // comma-separated
const log = (m) => console.log(new Date().toISOString(), m);
// Each role's key serves every chain.
const signers = Object.fromEntries(await Promise.all(ROLES.map(async (r) => [r, await signerFor(r)])));
const keeper = signers.filler?.address ?? getAddress(need('KEEPER_ADDRESS'));
const relayer = signers.relayer?.address ?? keeper;

// Monad is always on (FACTORY, START_BLOCK…); Base joins when BASE_FACTORY is set (D19).
const CHAINS = [
  { id: 143, name: 'Monad', sym: 'MON', kyber: 'monad', rpc: env.RPC_URL || 'https://rpc.monad.xyz', factory: need('FACTORY'), start: need('START_BLOCK'),
    stateFile: env.STATE_FILE || 'state.json', usdc: '0x754704Bc059F8C67012fEd69BC8A327a5aafb603', wrapped: '0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A', nativeFloor: 10n ** 18n },
  env.BASE_FACTORY && { id: 8453, name: 'Base', sym: 'ETH', kyber: 'base', rpc: env.BASE_RPC_URL || 'https://developer-access-mainnet.base.org,https://base-rpc.publicnode.com,https://base.drpc.org,https://mainnet.base.org', factory: env.BASE_FACTORY, start: need('BASE_START_BLOCK'),
    stateFile: env.BASE_STATE_FILE || 'state-base.json', usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', wrapped: '0x4200000000000000000000000000000000000006', nativeFloor: 3n * 10n ** 14n },
].filter(Boolean);

const every = (ms, fn, tag) => { const run = async () => { try { await fn(); } catch (e) { log(`${tag} ${fn.name}: ${e.shortMessage ?? e.message}`); } setTimeout(run, ms); }; run(); };
const nets = new Map();
for (const c of CHAINS) {
  const chain = defineChain({ id: c.id, name: c.name, nativeCurrency: { name: c.sym, symbol: c.sym, decimals: 18 },
    rpcUrls: { default: { http: c.rpc.split(',') } }, contracts: { multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' } } });
  // Public RPCs rate-limit; a comma list in the RPC variable rotates to the next one on failure.
  const transport = () => fallback(c.rpc.split(',').map((u) => rpcHttp(u.trim(), { timeout: 15_000 })));
  const pub = createPublicClient({ chain, transport: transport(), batch: { multicall: true } });
  const tagged = (m) => log(`[${c.name}] ${m}`);
  // One sender per address and chain: two roles on the old shared key must share its nonce sequence.
  const senders = new Map();
  const senderOf = (a) => a && (senders.get(a.address) ?? senders.set(a.address, createSender({ pub, account: a, chainId: c.id, log: tagged })).get(a.address));
  const wallet = senderOf(signers.filler), relayWallet = senderOf(signers.relayer);
  const factory = getAddress(c.factory);
  const registry = await pub.readContract({ address: factory, abi: factoryAbi, functionName: 'registry' });
  const ledger = createLedger({ pub, factory, registry, usdc: c.usdc, stateFile: c.stateFile, startBlock: BigInt(c.start), secretsKey: env.SECRETS_KEY || null, log: tagged });
  const filler = createFiller({ pub, wallet, keeper, registry, secretOf: ledger.secretOf, crossFills: env.CROSS_FILLS === 'on', minUsd: Number(env.MIN_ORDER_USD || 1), wmon: c.wrapped, usdc: c.usdc, chainId: c.id, kyberChain: c.kyber, log: tagged });
  // Sponsored opening waits for a deposit: 1 USDC, or the chain's native floor (audit H-2).
  const relay = createRelay({ pub, wallet: relayWallet, keeper: relayer, factory, deposits: [{ token: c.usdc, min: 1_000_000n }, { token: null, min: c.nativeFloor }],
    minPlaceFee: BigInt(env.MIN_PLACE_FEE || 5_000), log: tagged }); // 0.005 USDC
  nets.set(c.id, { ledger, relay, wallet, pub });
  tagged(`filler ${wallet ? keeper : `${keeper} (watch-only)`} · relayer ${relayWallet ? relayer : 'none'} · factory ${factory} · registry ${registry}`);

  // One key, one nonce sequence per chain: every pass over orders waits for the previous one.
  let queue = Promise.resolve();
  const tick = (orders) => (queue = queue.then(() => filler.tick(orders)));
  // A new order gets its first look right after the sync that saw it, not on the next 5s pass.
  const seen = new Set();
  every(2_000, async function sync() {
    await ledger.sync();
    const fresh = ledger.openOrders().filter((o) => !seen.has(`${o.account}#${o.id}`));
    fresh.forEach((o) => seen.add(`${o.account}#${o.id}`));
    if (fresh.length) await tick(fresh);
  }, c.name);
  every(5_000, async function fill() { await tick(ledger.openOrders()); }, c.name);
}

/**
 * POST /secret {chainId, account, id, secret}: the hidden half of a placed order (D20). Kept only if it
 * hashes to the commitment that order holds on-chain, so nobody can fill the store with junk.
 */
async function keepSecret(net, { account, id, secret } = {}) {
  let commit;
  try {
    const { tokenOut, destChainId, recipient, destToken, salt } = secret; // only the known fields are kept
    const s = { tokenOut, destChainId: Number(destChainId), minOut: BigInt(secret.minOut), destMinOut: BigInt(secret.destMinOut), recipient, destToken, salt };
    commit = commitOf(s);
    const o = await net.pub.readContract({ address: getAddress(account), abi: accountAbi, functionName: 'order', args: [BigInt(id)] });
    if (o.p.commit !== commit) return [400, { error: 'does not match the order' }];
    net.ledger.remember(commit, s);
    return [200, { ok: true }];
  } catch {
    return [400, { error: 'account, id and secret required' }];
  }
}

// ── HTTP: health, points, relay, open, secret ──
const hits = new Map();
/** At most `max` requests per minute per key (in memory, per instance). */
function allow(key, max) {
  const now = Date.now(), recent = (hits.get(key) ?? []).filter((t) => now - t < 60_000);
  if (hits.size > 50_000) hits.clear();
  recent.push(now);
  hits.set(key, recent);
  return recent.length <= max;
}
let waiting = 0;
const MAX_WAITING = 200; // receipts waited on at once; each holds a connection up to 10s
const reply = (res, status, body) => {
  res.writeHead(status, { 'content-type': 'application/json', 'access-control-allow-headers': 'content-type', vary: 'origin' });
  res.end(JSON.stringify(body));
};
const netOf = (input) => nets.get(Number(input?.chainId ?? 143));
http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://keeper');
  res.setHeader('access-control-allow-origin', ORIGINS.includes(req.headers.origin) ? req.headers.origin : ORIGINS[0]);
  if (req.method === 'OPTIONS') return reply(res, 204, {});
  const monad = nets.get(143);
  if (req.method === 'GET' && url.pathname === '/health') return reply(res, 200, { ok: true, cursor: String(monad.ledger.cursor), open: monad.ledger.openOrders().length, watchOnly: !monad.wallet,
    chains: Object.fromEntries([...nets].map(([id, n]) => [id, { cursor: String(n.ledger.cursor), open: n.ledger.openOrders().length }])) });
  const points = url.pathname.match(/^\/points\/(0x[0-9a-fA-F]{40})$/);
  if (req.method === 'GET' && points) {
    // ponytail: points add up across chains; the multiplier is the best single chain's, until dollar-days are pooled.
    const all = [...nets.values()].map((n) => n.ledger.pointsOf(points[1]));
    return reply(res, 200, { points: all.reduce((a, p) => a + p.points, 0), multiplier: Math.max(...all.map((p) => p.multiplier)) });
  }
  const rcpt = url.pathname.match(/^\/receipt\/(\d+)\/(0x[0-9a-fA-F]{64})$/);
  if (req.method === 'GET' && rcpt) {
    const net = nets.get(Number(rcpt[1]));
    if (!net) return reply(res, 400, { error: 'unsupported chain' });
    if (!allow(`receipt:${req.socket.remoteAddress}`, 120) || waiting >= MAX_WAITING) return reply(res, 429, { error: 'slow down' });
    waiting++;
    try {
      const out = await net.relay.receipt(rcpt[2]);
      return reply(res, out.status, out.mined ? { mined: out.mined } : { error: out.error });
    } finally { waiting--; }
  }
  if (req.method === 'POST' && (url.pathname === '/relay' || url.pathname === '/open' || url.pathname === '/secret')) {
    let body = '';
    for await (const chunk of req) { body += chunk; if (body.length > 40_000) return reply(res, 413, { error: 'too large' }); }
    let input;
    try { input = JSON.parse(body); } catch { return reply(res, 400, { error: 'json body required' }); }
    const net = netOf(input);
    if (!net) return reply(res, 400, { error: 'unsupported chain' });
    if (url.pathname === '/secret') {
      if (!allow(`secret:${req.socket.remoteAddress}`, 60)) return reply(res, 429, { error: 'slow down' });
      return reply(res, ...(await keepSecret(net, input)));
    }
    const out = url.pathname === '/open' ? await net.relay.open(input, req.socket.remoteAddress) : await net.relay.relay(input, req.socket.remoteAddress);
    return reply(res, out.status, out.hash ? { hash: out.hash } : { error: out.error });
  }
  reply(res, 404, { error: 'not found' });
}).listen(Number(env.PORT || 8080), () => log(`listening on :${env.PORT || 8080}`));
