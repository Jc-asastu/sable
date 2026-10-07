// Fetches a real KyberSwap route built for a given SableAccount and saves it for a fork test.
//   node scripts/kyber-fixture.mjs <account> [amountIn=1000000]                 Monad USDC -> WMON (KyberFork)
//   node scripts/kyber-fixture.mjs <account> <amountIn> <chain> <tokenIn> <tokenOut> <file>
import { writeFileSync, mkdirSync } from "node:fs";

const SLIPPAGE_BPS = 100;
const [account, amountIn = "1000000", chain = "monad",
  tokenIn = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", tokenOut = "0x3bd359c1119da7da1d913d1c4d2b7c461115433a",
  file = "test/fixtures/kyber-usdc-wmon.json"] = process.argv.slice(2);
if (!/^0x[0-9a-fA-F]{40}$/.test(account ?? "")) {
  console.error("usage: node scripts/kyber-fixture.mjs <account> [amountIn] [chain tokenIn tokenOut file]");
  process.exit(1);
}

const API = `https://aggregator-api.kyberswap.com/${chain}/api/v1`;
const headers = { "Content-Type": "application/json", "x-client-id": "sable" };
const route = await fetch(`${API}/routes?tokenIn=${tokenIn}&tokenOut=${tokenOut}&amountIn=${amountIn}`, { headers }).then((r) => r.json());
if (route.code !== 0) throw new Error(`route: ${route.message}`);

const build = await fetch(`${API}/route/build`, {
  method: "POST",
  headers,
  body: JSON.stringify({
    routeSummary: route.data.routeSummary,
    sender: account,
    recipient: account,
    slippageTolerance: SLIPPAGE_BPS,
  }),
}).then((r) => r.json());
if (build.code !== 0) throw new Error(`build: ${build.message}`);

const amountOut = BigInt(build.data.amountOut);
const fixture = {
  account,
  router: build.data.routerAddress,
  amountIn: build.data.amountIn,
  minOut: (amountOut * BigInt(10_000 - SLIPPAGE_BPS) / 10_000n).toString(),
  data: build.data.data,
};
mkdirSync("test/fixtures", { recursive: true });
writeFileSync(file, JSON.stringify(fixture, null, 2));
console.log(`saved route on ${chain}: ${amountIn} units -> ~${amountOut} units via ${fixture.router} into ${file}`);
