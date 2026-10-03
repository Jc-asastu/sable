// Fills open orders whose market price has reached their limit, and returns expired ones.
// Every transaction is simulated first: a fill that would revert costs nothing.
import { accountAbi, registryAbi, recipientFor, currencyFor, depositIdFrom, gasFeeIn } from './chain.js';

const RELAY = 'https://api.relay.link';
const SLIPPAGE_BPS = 50n;
const CROSS_GAS = 700_000n; // fillCrossOrder budget: vault redeem + fee + Relay deposit, with headroom

async function json(url, options) {
  const r = await fetch(url, { ...options, signal: AbortSignal.timeout(8_000) });
  if (!r.ok) throw new Error(`${new URL(url).host} HTTP ${r.status}`);
  return r.json();
}

/**
 * `wallet` is null in watch-only mode: the filler then logs what it would send and sends nothing.
 * `send(request)` returns a tx hash and waits for its receipt.
 */
export function createFiller({ pub, wallet, keeper, registry, wmon, usdc, chainId = 143, kyberChain = 'monad', log = console.log }) {
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

  async function fillLocal(account, id, p, spend, feeBps) {
    const net = spend - spend * feeBps / 10_000n;
    const head = { headers: { 'x-client-id': 'sable', 'Content-Type': 'application/json' } };
    const route = (await json(`${KYBER}/routes?tokenIn=${p.tokenIn}&tokenOut=${p.tokenOut}&amountIn=${net}`, head)).data;
    const out = BigInt(route.routeSummary.amountOut);
    if (out < p.minOut) return; // the market hasn't reached the limit yet
    const build = (await json(`${KYBER}/route/build`, { method: 'POST', ...head,
      body: JSON.stringify({ routeSummary: route.routeSummary, sender: account, recipient: account, slippageTolerance: Number(SLIPPAGE_BPS) }) })).data;
    const worst = BigInt(build.amountOut) * (10_000n - SLIPPAGE_BPS) / 10_000n;
    const gas = (await pub.estimateContractGas({ address: account, abi: accountAbi, functionName: 'fillOrder',
      args: [id, build.routerAddress, build.data, 0n], account: keeper })) * 12n / 10n;
    const unitUsd = Number(route.routeSummary.amountOutUsd) / Number(out);
    const gasFee = gasFeeIn(await gasUsd(gas), unitUsd, worst);
    if (gasFee === null || worst < p.minOut + gasFee) return; // too small to cover gas, or too close to the limit
    log(`fill ${account}#${id}: ${spend} in → ≥${worst} out (limit ${p.minOut}, gas ${gasFee})`);
    await send(account, 'fillOrder', [id, build.routerAddress, build.data, gasFee], gas);
  }

  async function fillCross(account, id, p, spend, feeBps) {
    const depository = await pub.readContract({ address: registry, abi: registryAbi, functionName: 'relayDepository' });
    const afterFee = spend - spend * feeBps / 10_000n;
    const gasFee = gasFeeIn(await gasUsd(CROSS_GAS), 1e-6, afterFee); // paid in USDC (6 decimals)
    if (gasFee === null) return;
    const amount = afterFee - gasFee;
    const quote = await json(`${RELAY}/quote`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({
      user: account, recipient: recipientFor(p.destChainId, p.recipient), originChainId: chainId, destinationChainId: p.destChainId,
      originCurrency: p.tokenIn, destinationCurrency: currencyFor(p.destChainId, p.destToken), amount: String(amount), tradeType: 'EXACT_INPUT',
    }) });
    if (BigInt(quote.details?.currencyOut?.amount ?? 0) < p.destMinOut) return; // not at the limit yet
    const step = quote.steps?.find((s) => s.id === 'deposit');
    // Throws unless Relay asks for exactly the deposit the contract will make (D17 trust bound).
    const depositId = depositIdFrom(step?.items?.[0]?.data, { depository, account, token: p.tokenIn, amount });
    log(`cross fill ${account}#${id}: ${amount} → ${quote.details.currencyOut.amountFormatted} ${quote.details.currencyOut.currency.symbol} to ${recipientFor(p.destChainId, p.recipient)}`);
    await send(account, 'fillCrossOrder', [id, depositId, gasFee], CROSS_GAS);
  }

  /** One pass over the open orders. One at a time: a single keeper key has one nonce sequence. */
  async function tick(openOrders) {
    if (!openOrders.length) return;
    const [feeBps] = await pub.readContract({ address: registry, abi: registryAbi, functionName: 'fee' });
    const now = BigInt(Math.floor(Date.now() / 1000));
    for (const o of openOrders) {
      const id = BigInt(o.id);
      try {
        const { p } = await pub.readContract({ address: o.account, abi: accountAbi, functionName: 'order', args: [id] });
        if (p.amountIn === 0n) continue; // already closed; the ledger catches up on its next sync
        if (now > p.deadline) { await send(o.account, 'cancelOrder', [id], 400_000n); continue; }
        const value = await pub.readContract({ address: o.account, abi: accountAbi, functionName: 'orderValue', args: [id] });
        const spend = value < p.amountIn ? value : p.amountIn;
        if (p.destChainId === 0) await fillLocal(o.account, id, p, spend, BigInt(feeBps));
        else await fillCross(o.account, id, p, spend, BigInt(feeBps));
      } catch (e) {
        log(`order ${o.account}#${o.id}: ${e.shortMessage ?? e.message}`);
      }
    }
  }

  return { tick };
}
