// Relays what the agent key signed, so users never need gas (DECISIONS D16). The keeper pays gas;
// signed swaps and withdrawals reimburse it through their own gasFee, capped on-chain.
import { decodeFunctionData, parseAbi, isAddress, isHex } from 'viem';
import { factoryAbi, accountAbi } from './chain.js';

const order = '(address tokenIn, address vault, address tokenOut, uint64 deadline, uint32 destChainId, uint128 amountIn, uint128 minOut, uint128 destMinOut, bytes32 recipient, bytes32 destToken)';
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

  /** Only a real Sable account: its owner's predicted account must be this address. */
  async function genuine(account) {
    const owner = await pub.readContract({ address: account, abi: accountAbi, functionName: 'owner' });
    const expected = await pub.readContract({ address: factory, abi: factoryAbi, functionName: 'accountOf', args: [owner] });
    return expected.toLowerCase() === account.toLowerCase();
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
      const gasPrice = (await pub.getGasPrice()) * 11n / 10n;
      const gas = (await pub.estimateContractGas({ address: factory, abi: factoryAbi, functionName: 'createAccountFor', args, account: keeper })) * 12n / 10n;
      const hash = await wallet.writeContract({ address: factory, abi: factoryAbi, functionName: 'createAccountFor', args, gas, gasPrice, account: keeper });
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
      const gasPrice = (await pub.getGasPrice()) * 11n / 10n;
      const gas = (await pub.estimateGas({ account: keeper, to: account, data })) * 12n / 10n; // reverts here cost nothing
      const hash = await wallet.sendTransaction({ to: account, data, gas, gasPrice, account: keeper });
      log(`relayed ${fn} for ${account}: ${hash}`);
      return { status: 200, hash };
    } catch (e) {
      return { status: 422, error: e.shortMessage ?? 'the call would revert' };
    }
  }

  return { relay, open };
}
