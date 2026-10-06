// Contract interfaces and the encoding helpers the keeper needs. No I/O here.
import { parseAbi, parseAbiParameters, encodeAbiParameters, keccak256, getAddress } from 'viem';

/** Across' chain id for Solana (order secrets carry Across ids, so it needs uint64). */
export const SOLANA = 34268394551451;

export const factoryAbi = parseAbi([
  'event AccountCreated(address indexed owner, address account)',
  'function createAccountFor(address owner, address agent, address[] routers, uint64 cooldown, uint256 deadline, bytes sig) returns (address)',
  'function accountOf(address owner) view returns (address)',
  'function registry() view returns (address)',
]);

export const registryAbi = parseAbi([
  'function fee() view returns (uint16 feeBps, address feeRecipient)',
  'function isKeeper(address) view returns (bool)',
  'function acrossSpokePool() view returns (address)',
  'function crossFillsPaused() view returns (bool)',
  'function vaultAllowed(address) view returns (bool)',
]);

const orderTuple = '((address tokenIn, address vault, uint64 deadline, uint128 amountIn, bytes32 commit) p, uint256 shares, bool byAgent)';
// The hidden half of an order (D20): on-chain there is only keccak256(abi.encode(secret)).
const secretTuple = '(address tokenOut, uint64 destChainId, uint128 minOut, uint128 destMinOut, bytes32 recipient, bytes32 destToken, bytes32 salt)';
const secretParams = parseAbiParameters(secretTuple);

/** The on-chain commitment to a secret; throws on a malformed one. */
export const commitOf = (s) => keccak256(encodeAbiParameters(secretParams, [s]));
export const accountAbi = parseAbi([
  'event OrderPlaced(uint256 indexed id, address indexed tokenIn, address indexed vault, uint128 amountIn, bytes32 commit)',
  'event OrderFilled(uint256 indexed id, uint256 spent, uint256 amountOut, uint256 yieldKept)',
  'event OrderCancelled(uint256 indexed id, uint256 returned)',
  'function owner() view returns (address)',
  `function order(uint256 id) view returns (${orderTuple})`,
  'function orderValue(uint256 id) view returns (uint256)',
  `function fillOrder(uint256 id, ${secretTuple} s, address router, bytes data, uint256 gasFee) returns (uint256)`,
  `function fillCrossOrder(uint256 id, ${secretTuple} s, uint256 outputAmount, uint32 quoteTimestamp, uint256 gasFee)`,
  'function cancelOrder(uint256 id)',
]);

// ── Solana keys are 32 bytes, written in base58 ──
const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

export function base58(bytes) {
  let n = 0n;
  for (const b of bytes) n = n * 256n + BigInt(b);
  let out = '';
  while (n > 0n) { out = B58[Number(n % 58n)] + out; n /= 58n; }
  for (const b of bytes) { if (b !== 0) break; out = '1' + out; }
  return out;
}

export function fromBase58(text) {
  let n = 0n;
  for (const c of text) {
    const i = B58.indexOf(c);
    if (i < 0) throw new Error('not base58');
    n = n * 58n + BigInt(i);
  }
  const bytes = [];
  while (n > 0n) { bytes.unshift(Number(n % 256n)); n /= 256n; }
  for (const c of text) { if (c !== '1') break; bytes.unshift(0); }
  return Uint8Array.from(bytes);
}

const hexBytes = (b32) => Uint8Array.from(b32.slice(2).match(/../g).map((h) => parseInt(h, 16)));

/** An order's bytes32 recipient as the destination chain writes it. */
export function recipientFor(chainId, b32) {
  return chainId === SOLANA ? base58(hexBytes(b32)) : getAddress(`0x${b32.slice(26)}`);
}

/** An order's bytes32 destination token as Across' API names it (an address, or a Solana mint). */
export function tokenFor(chainId, b32) {
  return chainId === SOLANA ? base58(hexBytes(b32)) : getAddress(`0x${b32.slice(26)}`);
}

/**
 * Gas reimbursement for a fill, in the token it is paid in. `gasUsd` is what the keeper spends;
 * `unitUsd` is the USD value of one base unit of that token. Null when it would break the
 * contract's 5% cap (the order is too small to fill profitably right now).
 */
export function gasFeeIn(gasUsd, unitUsd, moved, maxBps = 500n) {
  if (!(gasUsd >= 0) || !(unitUsd > 0)) return null;
  // toPrecision drops float noise (0.002 / 1e-6 = 2000.0000000000002) before rounding up.
  const fee = BigInt(Math.ceil(Number((gasUsd / unitUsd).toPrecision(12))));
  return fee * 10_000n > moved * maxBps ? null : fee;
}
