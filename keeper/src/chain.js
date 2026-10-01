// Contract interfaces and the encoding helpers the keeper needs. No I/O here.
import { parseAbi, decodeFunctionData, getAddress, zeroAddress } from 'viem';

export const SOLANA = 792703809;

export const factoryAbi = parseAbi([
  'event AccountCreated(address indexed owner, address account)',
  'function accountOf(address owner) view returns (address)',
  'function registry() view returns (address)',
]);

export const registryAbi = parseAbi([
  'function fee() view returns (uint16 feeBps, address feeRecipient)',
  'function isKeeper(address) view returns (bool)',
  'function relayDepository() view returns (address)',
]);

const orderTuple = '((address tokenIn, address vault, address tokenOut, uint64 deadline, uint32 destChainId, uint128 amountIn, uint128 minOut, uint128 destMinOut, bytes32 recipient, bytes32 destToken) p, uint256 shares)';
export const accountAbi = parseAbi([
  'event OrderPlaced(uint256 indexed id, address indexed tokenIn, address indexed vault, uint128 amountIn, uint32 destChainId)',
  'event OrderFilled(uint256 indexed id, uint256 spent, uint256 amountOut, uint256 yieldKept)',
  'event OrderCancelled(uint256 indexed id, uint256 returned)',
  'function owner() view returns (address)',
  `function order(uint256 id) view returns (${orderTuple})`,
  'function orderValue(uint256 id) view returns (uint256)',
  'function fillOrder(uint256 id, address router, bytes data, uint256 gasFee) returns (uint256)',
  'function fillCrossOrder(uint256 id, bytes32 depositId, uint256 gasFee)',
  'function cancelOrder(uint256 id)',
]);

export const depositoryAbi = parseAbi(['function depositErc20(address depositor, address token, uint256 amount, bytes32 id)']);

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

/** An order's bytes32 destination token as Relay names it; zero means the chain's native coin. */
export function currencyFor(chainId, b32) {
  if (chainId === SOLANA) return base58(hexBytes(b32)); // 32 zero bytes = 111…1, Solana's native SOL
  return /^0x0{64}$/.test(b32) ? zeroAddress : getAddress(`0x${b32.slice(26)}`);
}

/**
 * Relay's deposit step must be exactly the deposit the contract itself will make: our depository,
 * this account as depositor, this token and amount. Returns Relay's deposit id, or throws.
 */
export function depositIdFrom(tx, { depository, account, token, amount }) {
  if (!tx || tx.to?.toLowerCase() !== depository.toLowerCase() || BigInt(tx.value ?? 0) !== 0n) throw new Error('deposit target mismatch');
  const { functionName, args } = decodeFunctionData({ abi: depositoryAbi, data: tx.data });
  if (functionName !== 'depositErc20') throw new Error('not a depositErc20');
  const [depositor, depositToken, depositAmount, id] = args;
  if (depositor.toLowerCase() !== account.toLowerCase() || depositToken.toLowerCase() !== token.toLowerCase() || depositAmount !== amount) {
    throw new Error('deposit arguments mismatch');
  }
  return id;
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
