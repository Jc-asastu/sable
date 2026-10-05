// Fills open orders whose market price has reached their limit, and returns expired ones.
// Every transaction is simulated first: a fill that would revert costs nothing.
import { accountAbi, registryAbi, recipientFor, tokenFor, gasFeeIn } from './chain.js';

const ACROSS = 'https://app.across.to/api';
const SLIPPAGE_BPS = 50n;
const CROSS_GAS = 700_000n; // fillCrossOrder budget: vault redeem + fee + Across deposit, with headroom

async function json(url, options) {
  const r = await fetch(url, { ...options, signal: AbortSignal.timeout(8_000) });
  if (!r.ok) throw new Error(`${new URL(url).host} HTTP ${r.status}`);
  return r.json();
}

/**
 * `wallet` is null in watch-only mode: the filler then logs what it would send and sends nothing.
 * `send(request)` returns a tx hash and waits for its receipt.
 */
/** `secretOf(commit)` returns an order's hidden half, or nothing if the keeper never got it. */
/** `minUsd`: orders worth less (in USDC) are skipped, so dust can't slow every pass (audit M-1). */
export function createFiller({ pub, wallet, keeper, registry, wmon, usdc, secretOf, crossFills = false, minUsd = 1, chainId = 143, kyberChain = 'monad', log = console.log }) {
  const KYBER = `https://aggregator-api.kyberswap.com/${kyberChain}/api/v1`;
  let monUsd = 0, monUsdAt = 0;

  /** Native token price from a 100-unit Kyber quote (wrapped native → USDC), refreshed each minute. */
  async function monPrice() {
    if (Date.now() - monUsdAt < 60_000 && monUsd > 0) return monUsd;
    const q = await json(`${KYBER}/routes?tokenIn=${wmon}&tokenOut=${usdc}&amountIn=${10n ** 20n}`, { headers: { 'x-client-id': 'sable' } });
    monUsd = Number(q.data.routeSummary.amountOut) / 1e6 / 100;
    monUsdAt = Date.now();
    return monUsd;
  }
  const gasPrice = async () => (await pub.getGasPrice()) * 11n / 10n;
  // Monad charges the gas limit, not the gas used: pricing the limit is exact there and safe elsewhere.
  const gasUsd = async (limit) => Number(limit * (await gasPrice())) / 1e18 * (await monPrice());

  async function send(account, functionName, args, gas) {
    const request = { address: account, abi: accountAbi, functionName, args, account: keeper, gas, gasPrice: await gasPrice() };
    await pub.simulateContract(request);
    if (!wallet) return log(`[watch-only] would send ${functionName}(${args.map(String).join(', ')}) on ${account}`);
    const hash = await wallet.writeContract(request);
    const receipt = await pub.waitForTransactionReceipt({ hash, pollingInterval: 250 });
    log(`${functionName} ${receipt.status} ${hash}`);
    return hash;
  }

  async function fillLocal(account, id, p, s, spend, feeBps) {
    const net = spend - spend * feeBps / 10_000n;
    const head = { headers: { 'x-client-id': 'sable', 'Content-Type': 'application/json' } };
    const route = (await json(`${KYBER}/routes?tokenIn=${p.tokenIn}&tokenOut=${s.tokenOut}&amountIn=${net}`, head)).data;
    const out = BigInt(route.routeSummary.amountOut);
    if (out < s.minOut) return; // the market hasn't reached the limit yet
    const build = (await json(`${KYBER}/route/build`, { method: 'POST', ...head,
      body: JSON.stringify({ routeSummary: route.routeSummary, sender: account, recipient: account, slippageTolerance: Number(SLIPPAGE_BPS) }) })).data;
    const worst = BigInt(build.amountOut) * (10_000n - SLIPPAGE_BPS) / 10_000n;
    const gas = (await pub.estimateContractGas({ address: account, abi: accountAbi, functionName: 'fillOrder',
      args: [id, s, build.routerAddress, build.data, 0n], account: keeper })) * 12n / 10n;
    const unitUsd = Number(route.routeSummary.amountOutUsd) / Number(out);
    const gasFee = gasFeeIn(await gasUsd(gas), unitUsd, worst);
    if (gasFee === null || worst < s.minOut + gasFee) return; // too small to cover gas, or too close to the limit
    log(`fill ${account}#${id}: ${spend} in → ≥${worst} out (limit ${s.minOut}, gas ${gasFee})`);
    await send(account, 'fillOrder', [id, s, build.routerAddress, build.data, gasFee], gas);
  }

  // Across delivers to the order's own recipient and at least its own limit, checked on-chain by the
  // account and by Across: the keeper picks only when and how much above the limit (audit C-1).
  async function fillCross(account, id, p, s, spend, feeBps) {
    const afterFee = spend - spend * feeBps / 10_000n;
    const gasFee = gasFeeIn(await gasUsd(CROSS_GAS), 1e-6, afterFee); // paid in USDC (6 decimals)
    if (gasFee === null) return;
    const amount = afterFee - gasFee;
    const q = await json(`${ACROSS}/suggested-fees?inputToken=${p.tokenIn}&outputToken=${tokenFor(s.destChainId, s.destToken)}`
      + `&originChainId=${chainId}&destinationChainId=${s.destChainId}&amount=${amount}`);
    if (q.isAmountTooLow || BigInt(q.outputAmount ?? 0) < s.destMinOut) return; // not at the limit yet
    log(`cross fill ${account}#${id}: ${amount} → ${q.outputAmount} to ${recipientFor(s.destChainId, s.recipient)} in ~${q.estimatedFillTimeSec}s`);
    await send(account, 'fillCrossOrder', [id, s, BigInt(q.outputAmount), Number(q.timestamp), gasFee], CROSS_GAS);
  }

  /** One pass over the open orders. One at a time: a single keeper key has one nonce sequence. */
  async function tick(openOrders) {
    if (!openOrders.length) return;
    const [feeBps] = await pub.readContract({ address: registry, abi: registryAbi, functionName: 'fee' });
    const now = BigInt(Math.floor(Date.now() / 1000));
    // Dust is skipped and larger orders go first, so spam can't delay real fills (audit M-1).
    const queue = openOrders.filter((o) => o.usd == null || o.usd >= minUsd).sort((a, b) => (b.usd ?? 0) - (a.usd ?? 0));
    for (const o of queue) {
      const id = BigInt(o.id);
      try {
        const { p } = await pub.readContract({ address: o.account, abi: accountAbi, functionName: 'order', args: [id] });
        if (p.amountIn === 0n) continue; // already closed; the ledger catches up on its next sync
        if (now > p.deadline) { await send(o.account, 'cancelOrder', [id], 400_000n); continue; }
        const s = secretOf(p.commit);
        if (!s) continue; // the owner never sent the hidden half: the order waits until cancelled or expired
        const value = await pub.readContract({ address: o.account, abi: accountAbi, functionName: 'orderValue', args: [id] });
        const spend = value < p.amountIn ? value : p.amountIn;
        if (s.destChainId === 0) await fillLocal(o.account, id, p, s, spend, BigInt(feeBps));
        // Cross fills trust the keeper with the Relay request (audit C-1): off until Across replaces it.
        else if (crossFills) await fillCross(o.account, id, p, s, spend, BigInt(feeBps));
      } catch (e) {
        log(`order ${o.account}#${o.id}: ${e.shortMessage ?? e.message}`);
      }
    }
  }

  return { tick };
}
