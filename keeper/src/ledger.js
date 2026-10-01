// Follows the chain: accounts the factory created, their orders, and the points each fill earns.
// State is a small JSON file so a restart resumes from its cursor instead of rescanning history.
import fs from 'node:fs';
import { factoryAbi, accountAbi } from './chain.js';
import { fillPoints, dollarDays, multiplier } from './points.js';

const CHUNK = 100n; // Monad's eth_getLogs serves at most 100 blocks per call
const ADDRESSES_PER_CALL = 500;

export function createLedger({ pub, factory, usdc, stateFile, startBlock, log = console.log }) {
  const fresh = { cursor: String(startBlock - 1n), accounts: {}, orders: {}, points: {} };
  let state = fresh;
  try { state = { ...fresh, ...JSON.parse(fs.readFileSync(stateFile, 'utf8')) }; } catch { /* first run */ }

  const save = () => {
    const tmp = `${stateFile}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(state));
    fs.renameSync(tmp, stateFile);
  };
  const blockTimes = new Map();
  const timeOf = async (blockNumber) => {
    if (!blockTimes.has(blockNumber)) blockTimes.set(blockNumber, Number((await pub.getBlock({ blockNumber })).timestamp));
    if (blockTimes.size > 5_000) blockTimes.clear();
    return blockTimes.get(blockNumber);
  };
  const ordersOf = (owner) => Object.values(state.orders).filter((o) => o.owner === owner && o.usd !== null);
  // Orders here are spent in USDC; anything else has no reliable USD value and earns no points.
  const usdOf = (token, units) => (token.toLowerCase() === usdc.toLowerCase() ? Number(units) / 1e6 : null);

  async function apply(account, l) {
    const owner = state.accounts[account];
    const key = `${account}:${l.args.id}`;
    const at = await timeOf(l.blockNumber);
    if (l.eventName === 'OrderPlaced') {
      state.orders[key] = { account, owner, id: String(l.args.id), usd: usdOf(l.args.tokenIn, l.args.amountIn),
        tokenIn: l.args.tokenIn, destChainId: l.args.destChainId, openedAt: at, closedAt: null };
      return;
    }
    const o = state.orders[key];
    if (!o || o.closedAt !== null) return;
    o.closedAt = at;
    if (l.eventName === 'OrderFilled' && o.usd !== null) {
      const spent = usdOf(o.tokenIn, l.args.spent);
      const earned = fillPoints(ordersOf(owner), spent, at);
      state.points[owner] = (state.points[owner] ?? 0) + earned;
      log(`points: ${owner} +${Math.round(earned)} for a $${spent.toFixed(2)} fill`);
    }
  }

  /** Reads up to `maxBlocks` new blocks. Returns how many it read. */
  async function sync(maxBlocks = 2_000n) {
    const head = await pub.getBlockNumber();
    let from = BigInt(state.cursor) + 1n;
    const until = head < from + maxBlocks - 1n ? head : from + maxBlocks - 1n;
    let read = 0n;
    for (; from <= until; from += CHUNK) {
      const to = from + CHUNK - 1n > until ? until : from + CHUNK - 1n;
      // New accounts first, so an order placed in the same range is recognised.
      for (const l of await pub.getLogs({ address: factory, event: factoryAbi[0], fromBlock: from, toBlock: to })) {
        state.accounts[l.args.account.toLowerCase()] = l.args.owner.toLowerCase();
      }
      const accounts = Object.keys(state.accounts);
      for (let i = 0; i < accounts.length; i += ADDRESSES_PER_CALL) {
        const logs = await pub.getLogs({ address: accounts.slice(i, i + ADDRESSES_PER_CALL), events: accountAbi.filter((x) => x.type === 'event'), fromBlock: from, toBlock: to });
        logs.sort((a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber)));
        for (const l of logs) await apply(l.address.toLowerCase(), l);
      }
      state.cursor = String(to);
      read += to - from + 1n;
    }
    if (read) save();
    return read;
  }

  return {
    sync,
    get cursor() { return BigInt(state.cursor); },
    openOrders: () => Object.values(state.orders).filter((o) => o.closedAt === null),
    pointsOf(owner) {
      const o = owner.toLowerCase(), now = Math.floor(Date.now() / 1000);
      return { points: Math.round(state.points[o] ?? 0), multiplier: Number(multiplier(dollarDays(ordersOf(o), now)).toFixed(2)) };
    },
    isAccount: (account) => Boolean(state.accounts[account.toLowerCase()]),
  };
}
