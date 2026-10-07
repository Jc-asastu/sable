// Sable keeper: follows accounts and orders, fills orders at their limit, returns expired ones,
// relays agent-signed calls and serves points. Configuration comes only from the environment;
// the private key is never written anywhere (set it in Railway's variables).
//
//   FACTORY=0x…  START_BLOCK=<factory deploy block>  [KEEPER_PRIVATE_KEY=0x…]  node src/index.js
//
// Without KEEPER_PRIVATE_KEY it runs watch-only: it reads, computes points and logs what it
// would send (KEEPER_ADDRESS must then name a registered keeper so simulations pass).
import http from 'node:http';
import { createPublicClient, http as rpcHttp, fallback, defineChain, getAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { factoryAbi, accountAbi, commitOf } from './chain.js';
import { createLedger } from './ledger.js';
import { createFiller } from './filler.js';
import { createRelay } from './relay.js';
import { createSender } from './sender.js';

const env = process.env;
const need = (name) => { if (!env[name]) throw new Error(`${name} is required`); return env[name]; };
const ORIGINS = (env.ALLOWED_ORIGIN || 'https://sabledex.vercel.app').split(',').map((o) => o.trim()); // comma-separated
const log = (m) => console.log(new Date().toISOString(), m);
// MetaMask exports keys without 0x; accept both. One keeper key serves every chain.
const rawKey = env.KEEPER_PRIVATE_KEY?.trim();
const signer = rawKey ? privateKeyToAccount(rawKey.startsWith('0x') ? rawKey : `0x${rawKey}`) : null;
const keeper = signer ?? getAddress(need('KEEPER_ADDRESS'));

// Monad is always on (FACTORY, START_BLOCK…); Base joins when BASE_FACTORY is set (D19).
const CHAINS = [
  { id: 143, name: 'Monad', sym: 'MON', kyber: 'monad', rpc: env.RPC_URL || 'https://rpc.monad.xyz', factory: need('FACTORY'), start: need('START_BLOCK'),
    stateFile: env.STATE_FILE || 'state.json', usdc: '0x754704Bc059F8C67012fEd69BC8A327a5aafb603', wrapped: '0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A' },
  env.BASE_FACTORY && { id: 8453, name: 'Base', sym: 'ETH', kyber: 'base', rpc: env.BASE_RPC_URL || 'https://developer-access-mainnet.base.org,https://base-rpc.publicnode.com,https://base.drpc.org,https://mainnet.base.org', factory: env.BASE_FACTORY, start: need('BASE_START_BLOCK'),
    stateFile: env.BASE_STATE_FILE || 'state-base.json', usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', wrapped: '0x4200000000000000000000000000000000000006' },
  // Robinhood Chain joins when ROBINHOOD_FACTORY is set. Its dollar is USDG (6 decimals, like USDC); stocks trade here.
  env.ROBINHOOD_FACTORY && { id: 4663, name: 'Robinhood', sym: 'ETH', kyber: 'robinhood', rpc: env.ROBINHOOD_RPC_URL || 'https://rpc.mainnet.chain.robinhood.com', factory: env.ROBINHOOD_FACTORY, start: need('ROBINHOOD_START_BLOCK'),
    stateFile: env.ROBINHOOD_STATE_FILE || 'state-robinhood.json', usdc: '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168', wrapped: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73' },
].filter(Boolean);

const every = (ms, fn, tag) => { const run = async () => { try { await fn(); } catch (e) { log(`${tag} ${fn.name}: ${e.shortMessage ?? e.message}`); } setTimeout(run, ms); }; run(); };
const nets = new Map();
for (const c of CHAINS) {
  const chain = defineChain({ id: c.id, name: c.name, nativeCurrency: { name: c.sym, symbol: c.sym, decimals: 18 },
    rpcUrls: { default: { http: c.rpc.split(',') } }, contracts: { multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' } } });
  // Public RPCs rate-limit; a comma list in the RPC variable rotates to the next one on failure.
  const transport = () => fallback(c.rpc.split(',').map((u) => rpcHttp(u.trim(), { timeout: 15_000 })));
  const pub = createPublicClient({ chain, transport: transport(), batch: { multicall: true } });
  const wallet = signer ? createSender({ pub, account: signer, chainId: c.id, log: (m) => log(`[${c.name}] ${m}`) }) : null;
  const factory = getAddress(c.factory);
  const registry = await pub.readContract({ address: factory, abi: factoryAbi, functionName: 'registry' });
  const tagged = (m) => log(`[${c.name}] ${m}`);
  const ledger = createLedger({ pub, factory, usdc: c.usdc, stateFile: c.stateFile, startBlock: BigInt(c.start), log: tagged });
  const filler = createFiller({ pub, wallet, keeper, registry, secretOf: ledger.secretOf, crossFills: env.CROSS_FILLS === 'on', wmon: c.wrapped, usdc: c.usdc, chainId: c.id, kyberChain: c.kyber, log: tagged });
  const relay = createRelay({ pub, wallet, keeper, factory, log: tagged });
  nets.set(c.id, { ledger, relay, wallet, pub });
  tagged(`keeper ${signer ? signer.address : `${keeper} (watch-only)`} · factory ${factory} · registry ${registry}`);

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
    const out = await net.relay.receipt(rcpt[2]);
    return reply(res, out.status, out.mined ? { mined: out.mined } : { error: out.error });
  }
  if (req.method === 'POST' && (url.pathname === '/relay' || url.pathname === '/open' || url.pathname === '/secret')) {
    let body = '';
    for await (const chunk of req) { body += chunk; if (body.length > 40_000) return reply(res, 413, { error: 'too large' }); }
    let input;
    try { input = JSON.parse(body); } catch { return reply(res, 400, { error: 'json body required' }); }
    const net = netOf(input);
    if (!net) return reply(res, 400, { error: 'unsupported chain' });
    if (url.pathname === '/secret') return reply(res, ...(await keepSecret(net, input)));
    const out = url.pathname === '/open' ? await net.relay.open(input, req.socket.remoteAddress) : await net.relay.relay(input, req.socket.remoteAddress);
    return reply(res, out.status, out.hash ? { hash: out.hash } : { error: out.error });
  }
  reply(res, 404, { error: 'not found' });
}).listen(Number(env.PORT || 8080), () => log(`listening on :${env.PORT || 8080}`));
