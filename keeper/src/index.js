// Sable keeper: follows accounts and orders, fills orders at their limit, returns expired ones,
// relays agent-signed calls and serves points. Configuration comes only from the environment;
// the private key is never written anywhere (set it in Railway's variables).
//
//   FACTORY=0x…  START_BLOCK=<factory deploy block>  [KEEPER_PRIVATE_KEY=0x…]  node src/index.js
//
// Without KEEPER_PRIVATE_KEY it runs watch-only: it reads, computes points and logs what it
// would send (KEEPER_ADDRESS must then name a registered keeper so simulations pass).
import http from 'node:http';
import { createPublicClient, createWalletClient, http as transport, defineChain, getAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { factoryAbi } from './chain.js';
import { createLedger } from './ledger.js';
import { createFiller } from './filler.js';
import { createRelay } from './relay.js';

const env = process.env;
const need = (name) => { if (!env[name]) throw new Error(`${name} is required`); return env[name]; };
const RPC = env.RPC_URL || 'https://rpc.monad.xyz';
const FACTORY = getAddress(need('FACTORY'));
const USDC = '0x754704Bc059F8C67012fEd69BC8A327a5aafb603';
const WMON = '0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A';
const ORIGINS = (env.ALLOWED_ORIGIN || 'https://sabledex.vercel.app').split(',').map((o) => o.trim()); // comma-separated

const monad = defineChain({ id: 143, name: 'Monad', nativeCurrency: { name: 'MON', symbol: 'MON', decimals: 18 },
  rpcUrls: { default: { http: [RPC] } }, contracts: { multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' } } });
const pub = createPublicClient({ chain: monad, transport: transport(RPC), batch: { multicall: true } });
// MetaMask exports keys without 0x; accept both.
const rawKey = env.KEEPER_PRIVATE_KEY?.trim();
const signer = rawKey ? privateKeyToAccount(rawKey.startsWith('0x') ? rawKey : `0x${rawKey}`) : null;
const wallet = signer ? createWalletClient({ chain: monad, transport: transport(RPC), account: signer }) : null;
const keeper = signer ?? getAddress(need('KEEPER_ADDRESS'));
const registry = await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: 'registry' });

const log = (m) => console.log(new Date().toISOString(), m);
const ledger = createLedger({ pub, factory: FACTORY, usdc: USDC, stateFile: env.STATE_FILE || 'state.json', startBlock: BigInt(need('START_BLOCK')), log });
const filler = createFiller({ pub, wallet, keeper, registry, wmon: WMON, usdc: USDC, log });
const relay = createRelay({ pub, wallet, keeper, factory: FACTORY, log });
log(`keeper ${signer ? signer.address : `${keeper} (watch-only)`} · factory ${FACTORY} · registry ${registry}`);

// ── loops: follow the chain every 2s, look at open orders every 5s ──
const every = (ms, fn) => { const run = async () => { try { await fn(); } catch (e) { log(`${fn.name}: ${e.shortMessage ?? e.message}`); } setTimeout(run, ms); }; run(); };
// One keeper key, one nonce sequence: every pass over orders waits for the previous one.
let queue = Promise.resolve();
const tick = (orders) => (queue = queue.then(() => filler.tick(orders)));
// A new order gets its first look right after the sync that saw it, not on the next 5s pass.
const seen = new Set();
every(2_000, async function sync() {
  await ledger.sync();
  const fresh = ledger.openOrders().filter((o) => !seen.has(`${o.account}#${o.id}`));
  fresh.forEach((o) => seen.add(`${o.account}#${o.id}`));
  if (fresh.length) await tick(fresh);
});
every(5_000, async function fill() { await tick(ledger.openOrders()); });

// ── HTTP: health, points, relay ──
const reply = (res, status, body) => {
  res.writeHead(status, { 'content-type': 'application/json', 'access-control-allow-headers': 'content-type', vary: 'origin' });
  res.end(JSON.stringify(body));
};
http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://keeper');
  res.setHeader('access-control-allow-origin', ORIGINS.includes(req.headers.origin) ? req.headers.origin : ORIGINS[0]);
  if (req.method === 'OPTIONS') return reply(res, 204, {});
  if (req.method === 'GET' && url.pathname === '/health') return reply(res, 200, { ok: true, cursor: String(ledger.cursor), open: ledger.openOrders().length, watchOnly: !wallet });
  const points = url.pathname.match(/^\/points\/(0x[0-9a-fA-F]{40})$/);
  if (req.method === 'GET' && points) return reply(res, 200, ledger.pointsOf(points[1]));
  if (req.method === 'POST' && url.pathname === '/relay') {
    let body = '';
    for await (const chunk of req) { body += chunk; if (body.length > 40_000) return reply(res, 413, { error: 'too large' }); }
    let input;
    try { input = JSON.parse(body); } catch { return reply(res, 400, { error: 'json body required' }); }
    const out = await relay(input ?? {}, req.socket.remoteAddress);
    return reply(res, out.status, out.hash ? { hash: out.hash } : { error: out.error });
  }
  reply(res, 404, { error: 'not found' });
}).listen(Number(env.PORT || 8080), () => log(`listening on :${env.PORT || 8080}`));
