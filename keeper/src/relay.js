// Relays what the agent key signed, so users never need gas (DECISIONS D16). The keeper pays gas;
// signed swaps and withdrawals reimburse it through their own gasFee, capped on-chain.
import { decodeFunctionData, parseAbi, isAddress, isHex } from 'viem';
import { factoryAbi, accountAbi } from './chain.js';

const order = '(address tokenIn, address vault, uint64 deadline, uint128 amountIn, bytes32 commit)';
const relayable = parseAbi([
  `function placeOrderWithSig(${order} p, uint256 nonce, uint256 sigDeadline, uint64 epoch, bytes sig)`,
  'function cancelOrderWithSig(uint256 id, uint256 nonce, uint256 deadline, uint64 epoch, bytes sig)',
  'function swapWithSig((address router, address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, uint256 gasFee, uint256 nonce, uint256 deadline, uint64 epoch) o, bytes data, bytes sig)',
  'function withdrawWithSig((address token, uint256 amount, address to, uint256 gasFee, uint256 nonce, uint256 deadline, uint64 epoch) o, bytes sig)',
]);
const LIMIT = { perAccount: 30, perIp: 60, windowMs: 60_000 };
const MAX_DATA = 16_384; // bytes of calldata; a Kyber route fits easily

export function createRelay({ pub, wallet, keeper, factory, log = console.log }) {
  const hits = new Map();
  const allow = (key, max) => {
    const now = Date.now(), recent = (hits.get(key) ?? []).filter((t) => now - t < LIMIT.windowMs);
    if (hits.size > 50_000) hits.clear(); // ponytail: in-memory per instance; use a shared store if the keeper scales out
    recent.push(now);
    hits.set(key, recent);
    return recent.length <= max;
  };

  /** Only a real Sable account: its owner's predicted account must be this address. Checked once per account. */
  const verified = new Set();
  async function genuine(account) {
    if (verified.has(account.toLowerCase())) return true;
    const owner = await pub.readContract({ address: account, abi: accountAbi, functionName: 'owner' });
    const expected = await pub.readContract({ address: factory, abi: factoryAbi, functionName: 'accountOf', args: [owner] });
    const ok = expected.toLowerCase() === account.toLowerCase();
    if (ok) verified.add(account.toLowerCase());
    return ok;
  }

  /**
   * Sponsored opening (D19): the owner signed OpenAccount; the keeper pays the gas. The factory
   * checks the signature, so a bad one only costs a failed estimate here.
   */
  async function open({ owner, agent, routers, cooldown, deadline, sig }, ip) {
    if (!isAddress(owner) || !isAddress(agent) || !Array.isArray(routers) || routers.length > 8 || !routers.every(isAddress) || !isHex(sig)) return { status: 400, error: 'owner, agent, routers and sig required' };
    if (!allow(`ip:${ip}`, LIMIT.perIp) || !allow(`open:${owner.toLowerCase()}`, 5)) return { status: 429, error: 'slow down' };
    if (!wallet) return { status: 503, error: 'relayer is in watch-only mode' };
    try {
      const args = [owner, agent, routers, BigInt(cooldown ?? 0), BigInt(deadline), sig];
      const gas = (await pub.estimateContractGas({ address: factory, abi: factoryAbi, functionName: 'createAccountFor', args, account: keeper })) * 12n / 10n;
      const hash = await wallet.writeContract({ address: factory, abi: factoryAbi, functionName: 'createAccountFor', args, gas });
      log(`opened account for ${owner}: ${hash}`);
      return { status: 200, hash };
    } catch (e) {
      return { status: 422, error: e.shortMessage ?? 'the call would revert' };
    }
  }

  /** { account, data } → { hash } or { error, status }. */
  async function relay({ account, data }, ip) {
    if (!isAddress(account) || !isHex(data) || data.length > 2 + MAX_DATA * 2) return { status: 400, error: 'account and calldata required' };
    let fn;
    try { fn = decodeFunctionData({ abi: relayable, data }).functionName; } catch { return { status: 400, error: 'not a relayable call' }; }
    if (!allow(`ip:${ip}`, LIMIT.perIp) || !allow(`acct:${account.toLowerCase()}`, LIMIT.perAccount)) return { status: 429, error: 'slow down' };
    if (!(await genuine(account).catch(() => false))) return { status: 400, error: 'not a Sable account' };
    if (!wallet) return { status: 503, error: 'relayer is in watch-only mode' };
    try {
      const t0 = Date.now();
      const gas = (await pub.estimateGas({ account: keeper, to: account, data })) * 12n / 10n; // reverts here cost nothing
      const t1 = Date.now();
      const hash = await wallet.sendTransaction({ to: account, data, gas });
      const t2 = Date.now();
      log(`relayed ${fn} for ${account}: ${hash}`);
      log(`timing ${fn}: estimate ${t1 - t0}ms · send ${t2 - t1}ms`);
      // Answer as soon as it is sent: the browser shows "sent" and asks GET /receipt for the outcome.
      return { status: 200, hash };
    } catch (e) {
      return { status: 422, error: e.shortMessage ?? 'the call would revert' };
    }
  }

  /** Waits for a receipt next to the RPC (50ms polls): far faster than a browser polling from afar. */
  async function receipt(hash) {
    if (!/^0x[\da-fA-F]{64}$/.test(hash)) return { status: 400, error: 'transaction hash required' };
    const r = await pub.waitForTransactionReceipt({ hash, pollingInterval: 50, timeout: 10_000 }).catch(() => null);
    return r ? { status: 200, mined: r.status } : { status: 404, error: 'not mined yet' };
  }

  return { relay, open, receipt };
}
