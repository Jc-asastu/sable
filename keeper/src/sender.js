// The keeper's hot path to the chain. One sender per chain, shared by the relay and the filler:
// the keeper key has one nonce sequence, so nonces are handed out here in order instead of asked
// from the RPC, the gas price is refreshed in the background, and each transaction is signed
// locally and sent raw. Sending costs one RPC round trip instead of four or five.
import { encodeFunctionData } from 'viem';

export function createSender({ pub, account, chainId, log = console.log }) {
  let nonce = null, price = null, queue = Promise.resolve();
  const refresh = async () => { price = (await pub.getGasPrice()) * 11n / 10n; };
  const timer = setInterval(() => refresh().catch(() => {}), 2_000);
  timer.unref?.();

  function sendTransaction({ to, data, gas, value = 0n }) {
    const run = queue.then(async () => {
      if (price === null) await refresh();
      if (nonce === null) nonce = await pub.getTransactionCount({ address: account.address, blockTag: 'pending' });
      const raw = await account.signTransaction({ chainId, type: 'legacy', to, data, gas, gasPrice: price, nonce, value });
      try {
        const hash = await pub.sendRawTransaction({ serializedTransaction: raw });
        nonce += 1;
        return hash;
      } catch (e) {
        nonce = null; // a refused transaction may have left the sequence anywhere: ask the chain next time
        log(`send failed, nonce resyncs: ${e.shortMessage ?? e.message}`);
        throw e;
      }
    });
    queue = run.catch(() => {});
    return run;
  }

  const writeContract = ({ address, abi, functionName, args, gas }) =>
    sendTransaction({ to: address, data: encodeFunctionData({ abi, functionName, args }), gas });

  return { sendTransaction, writeContract, gasPrice: async () => price ?? (await refresh(), price) };
}
