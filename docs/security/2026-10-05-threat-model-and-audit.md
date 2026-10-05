# Sable v4 — threat model and internal audit

Date: 2026-10-05 · Scope: contracts v4 (`SableAccount`, `SableAccountFactory`, `TokenRegistry`), keeper (`keeper/src`), web app (`sable-app`) · Out of scope: `YieldBook`/`TickBitmap` (not deployed), third-party protocols (Kyber, Relay, Aave, Euler, Fluid) except where Sable trusts them.

Method:
- context building, following Trail of Bits `audit-context-building`;
- entry-point and privilege mapping;
- Slither 0.11 static analysis (triaged below);
- manual review of every privileged path and every off-chain trust assumption.

This is an **internal** review. It does not replace an external audit before larger deposits.

Live deployments reviewed:

| Chain | Factory v4 | Registry |
|---|---|---|
| Monad | `0xe3771074342fa61E0391276EFf639214930983B9` | `0xAAecB6180B27839da137Da04894Df3C544083678` |
| Base | `0x4bA7C6731Cba147F1b7ab950c1d54d9C9CDB99Da` | `0x732a60b051E64dD362512a200aD2586FCF1a2664` |

Admin of both: `0x76E19267933250D842389ba80be70e3a07fa411a` (single EOA). Keeper: `0x1dC0A81908e6063b85cd30cb4F3019Bca0d2254A` (one key, both chains, every role).

---

## 1. Actors and what each can do today

| Actor | Key lives in | Powers |
|---|---|---|
| **Owner** | user's wallet | Everything on their own account: trade, withdraw anywhere, place and cancel orders, set agent, payout, routers, caps, cross recipients. |
| **Agent** (fast key) | the browser (`localStorage`), derived from an owner signature | Signed swaps through allowed routers, within Shield caps (listed tokens, per-trade and daily); place and cancel orders; withdraw **only** to the owner or the payout wallet. |
| **Keeper** | Railway env var `KEEPER_PRIVATE_KEY` | `fillOrder`, `fillCrossOrder`, `cancelOrder` after expiry, on **every** account. Also relays agent signatures and sponsors account opening (pays gas). Knows every hidden limit. |
| **Admin** | one EOA | Registry: token listings (agent caps), fee (≤1%), fee recipient, **allowed vaults**, **keepers**, **Relay depository**. Factory: allowlist and opening to everyone. |
| **Relay solver** | third party | Delivers cross-chain fills once a deposit with a given `depositId` lands. |
| **Vaults** | third parties (Aave, Euler, Fluid) | Hold the funds of every waiting order. |
| **Web origin + CDN** | Vercel + jsdelivr | Run the code that holds the agent key and builds every owner transaction. |

### What nobody but the owner can do (verified)

These properties hold and are worth keeping in any redesign:

- **No one but the owner can move funds to an arbitrary address.**
  - `withdraw`, `withdrawNative` and `swap` are `onlyOwner`.
  - Agent withdrawals pay only the owner or `payout` (`withdrawWithSig`, the `o.to` check).
- **A local fill can never deliver less than the order's limit.** `_swap` checks the account's own balance delta against `minOut + gasFee`, and `fillOrder` passes the revealed `s.minOut`.
- **A wrong reveal can't fill.** `keccak256(abi.encode(s)) == p.commit` is checked in `_takeOrder`.
- **Funds never get stuck behind the keeper.** The owner can always `cancelOrder` and `withdraw`, keeper or not.
- **Every external entry point is `nonReentrant`.** State is deleted before redeem or swap (`_takeOrder`, `_cancel`).
- **Agent signatures** bind account (EIP-712 domain = clone address), nonce (one use), deadline and agent epoch.

---

## 2. Findings

Severity: **Critical** = theft of user funds at scale with one compromised key or one mistake. **High** = theft bounded by caps or protocol-wide outage. **Medium** = limited loss, privacy or liveness. **Low/Info** = hygiene.

### C-1 · A compromised keeper can redirect every open cross-chain order

**Where:** `SableAccount.fillCrossOrder`. The keeper passes `depositId`. The contract approves `net` to the Relay depository and calls `depositErc20(account, tokenIn, net, depositId)`. The Relay request behind that `depositId` (recipient, destination token, minimum output) lives **off-chain**, and the contract cannot see it. `TokenRegistry` acknowledges this (D17: "a cross-chain fill also trusts it with the Relay request").

**Scenario:**
1. An attacker with the keeper key asks Relay for quotes paying **their own** address.
2. They call `fillCrossOrder(id, s, theirDepositId, 0)` on every open cross order. The secret is in the keeper's own store, and expiry and price are not checked on-chain for cross fills.
3. Relay pays the attacker on the destination chain.

**Impact:** every dollar in open cross-chain orders, on every account, at once.

**Today's mitigations:** none on-chain. The keeper code checks the Relay quote (`depositIdFrom`), but that is the very code a compromise bypasses.

**Fix (architectural):** make the destination verifiable on-chain from the order's own fields.
- **Preferred:** a bridge whose deposit takes `recipient`, `outputToken` and `minOutputAmount` as contract arguments the protocol enforces (Across `SpokePool.depositV3` is the reference design; check that it is available on Monad and Base). The account builds the deposit from the revealed `s.recipient`, `s.destToken` and `s.destMinOut`. The keeper then chooses only *when*.
- **Alternative:** the owner or agent signs the bridge request at placement, which conflicts with fill-time quoting.
- **Interim, before any fix ships:**
  - a per-order and total cap on cross-chain orders (registry setting);
  - a monitor that checks every `CrossFilled` against Relay's API (recipient = `s.recipient`) and revokes the keeper on mismatch (see H-4, guardian).

### C-2 · A single admin EOA can redirect future deposits and empower an attacker keeper

**Where:** `TokenRegistry` is `Ownable2Step`, owned by one EOA on both chains.

**Scenario:** with that key, an attacker can:
1. `setVault(fakeVault, true)`: a malicious ERC-4626 whose `asset()` is USDC.
   - The app only offers vaults from `/api/vaults`, so users are not routed to it automatically.
   - But any agent-placed or owner-placed order naming it deposits into it, and a compromised app (H-3) would name it.
2. `setKeeper(attacker, true)`: gives C-1 to the attacker without stealing the keeper key.
3. `list(token, hugeCaps)`: widens what a stolen agent key can trade (H-3).
4. `setRelayDepository(attacker)`: a cross fill then approves `net` to the attacker. The honest keeper refuses, because `depositIdFrom` checks the quote's `to` against the registry value. An attacker keeper doesn't.

**Impact:** combined with an attacker keeper, the same as C-1, plus future vault deposits.

**Fix:**
- move ownership of both registries and factories to a **Safe multisig** (2-of-3 at least, hardware signers);
- add a **timelock** (24–48h) on `setVault`, `setKeeper(true)`, `setRelayDepository` and `list`, so the monitor and users see a malicious change before it takes effect;
- add a **guardian** role that can only *reduce* risk, instantly: `setKeeper(false)`, delist, pause new orders.

### H-1 · The keeper can keep the price improvement on local fills

**Where:** `fillOrder` → `_swap`. The keeper picks the router (it must be in the account's `routerAllowed`, which is Kyber by default) and builds its calldata. The contract only checks that the account received at least `minOut + gasFee`. Kyber's router runs an executor chosen in the calldata, so a route can deliver exactly the limit to the account and send the surplus elsewhere.

**Impact:** a user never gets less than their limit, but a malicious keeper can always fill *at* the limit and keep the difference to the market. Also, `gasFee` is set by the keeper up to `MAX_GAS_BPS` (5%) of the output. It goes to the fee recipient, not to the keeper.

**Fix options:**
- (a) **permissionless fills with competition:** anyone can fill, and fillers compete on output. This needs a commit-reveal-friendly design, because secrets are hidden.
- (b) the keeper commits to a quote and the contract requires `amountOut ≥ quoteOut × (1 − slippage)`. This is only as good as the keeper, so weak.
- (c) **accept and monitor:** compare every fill's output to a fresh quote, and alert when slippage stays persistently near the limit.

Recommendation: (c) now; (a) as part of the v5/v6 redesign.

### H-2 · Anyone can drain the relayer's gas

**Where:** `keeper/src/relay.js` sponsors `placeOrderWithSig` and `cancelOrderWithSig`, which **carry no gas fee**, and `createAccountFor`, which carries none either. The factory is open to everyone, so accounts and owners are free to create. Rate limits are per IP (60/min) and per account (30/min), in memory.

**Scenario:** a script generates owners, has the keeper open their accounts for free, deposits 1 wei of USDC in each, and loops place/cancel through many IPs or accounts. Each relay is paid by the keeper. Monad charges the gas **limit**.

**Impact:**
- the keeper's MON runs out, and fast trading and fills stop for everyone (liveness);
- the attacker pays nothing but RPC calls.

**Fix:**
- a gas fee on place/cancel too, taken from the order (as in swaps) or with a minimum order size;
- sponsored opening only for owners who deposit in the same flow, or a one-time proof of funds;
- a per-owner daily gas budget in the relayer;
- move rate limits to a shared store.

### H-3 · Web-origin or CDN compromise steals agent keys (theft within caps) and phishes owners

**Where:**
- The app imports `viem` (and its accounts module) and `lightweight-charts` as ES modules from `cdn.jsdelivr.net`, with no integrity check. The `/+esm` builds are generated by jsdelivr, so Subresource Integrity can't even be applied.
- `sabledex.vercel.app` sends **no Content-Security-Policy** and no `frame-ancestors`/`X-Frame-Options`.
- The agent key sits in `localStorage`.

**Scenario:** a compromised CDN response or an XSS can:
1. read every visitor's agent key and sign `swapWithSig` through Kyber with an attacker executor and a tiny `minOut`. This steals up to each listed token's per-trade and daily cap, per account, every day.
2. replace owner transactions with malicious ones (a wallet prompt the user approves).

**Impact:** bounded by Shield caps for agent theft, unbounded for phished owner signatures.

**Fix:**
- **vendor and hash** third-party code (bundle viem, the chart and Privy at build time, serve them from the same origin);
- a **strict CSP**: `script-src 'self'`, `connect-src` limited to the APIs used, `frame-ancestors 'none'`;
- keep Shield caps tight;
- consider an expiring agent: rotate `agentEpoch` on a schedule, or a short-lived session.

### H-4 · One raw keeper key for every role, on both chains, stored in a Railway env var

**Where:** `index.js`. The same `KEEPER_PRIVATE_KEY` signs relays, fills, expiry cancels and sponsored opens on Monad and Base. This contradicts the project rule "each blockchain service role uses a different wallet".

**Impact:**
- whoever reads Railway's variables (account takeover, a leaked token, a malicious dependency in the keeper image) gets C-1;
- there is no way to revoke one role without stopping all of them.

**Fix:**
- split roles into separate keys and separate registry rights:
  - a **relayer** key (no registry role: it only pays gas for user-signed calls);
  - a **filler** key (`isKeeper`);
  - a future **valuer** key (v5 `setWeight`);
- sign through a **KMS or policy signer** (Turnkey, AWS KMS, or a minimal signing service) with per-key allowlists of contracts and selectors;
- keep the hot balances small and top them up automatically;
- pin and audit the keeper's dependencies.

### M-1 · Dust orders can slow the filler (liveness)

**Where:** `filler.tick` quotes every open order on Kyber every 5s, one at a time.

**Scenario:** thousands of 1-wei orders make each pass slow and hit Kyber's rate limits, so genuine orders fill late.

**Fix:**
- a minimum order value, on-chain or at least keeper-side, so dust is skipped;
- prioritize orders by size and by distance to the limit;
- quote in batches.

### M-2 · Hidden limits are stored in plaintext on the keeper's volume

**Where:** `ledger.remember` writes `state.secrets` to the JSON state file on `/data`.

**Impact:** a leak of the volume or a backup reveals every user's limit (the very thing D20 hides).

**Fix:** encrypt the secrets at rest with a KMS key, and delete each secret when its order closes.

### M-3 · Third-party vault risk is inherited, unbounded

**Where:** every waiting order's funds sit in an allowlisted ERC-4626 (Aave stata, Euler Earn, Fluid). Their admins and upgrades are outside Sable's control. The app shows vaults as "Available" without per-vault limits.

**Fix:**
- per-vault deposit caps in the registry;
- show each vault's risk notes;
- add a "pause vault" action for the guardian.

### M-4 · Keeper HTTP endpoints have unbounded resource use

**Where:**
- `GET /receipt` holds a connection for up to 10s;
- `POST /secret` does an RPC read per request, with no rate limit.

**Fix:** rate-limit both endpoints and cap concurrent receipt waits.

### M-5 · (design, v5) `setWeight` as specified would let a keeper drain the reward pool

**Where:** `docs/specs/2026-10-05-csable-revenue-design.md`, keeper valuation.

**Impact:** a compromised valuer sets a huge weight on its own order and takes most of the pool.

**Fix before building:** cap weight per order and per day, use a separate valuer key (H-4), add a guardian pause, and consider two independent valuers that must agree.

### Low and informational

- **L-1:** the EIP-712 domain version is still `"3"` in v4. There is no replay across versions, because the PlaceOrder typehash changed and the domain uses the clone address. Rename it for clarity in v5.
- **L-2:** missing zero-address checks (`setAgent`, `setPayout`, `setRelayDepository`, `initialize`). `address(0)` is intentional for agent and payout (it removes them). `setRelayDepository(0)` disables cross fills (`NoDepository`), which is acceptable.
- **L-3:** events with unindexed address parameters (`AgentSet`, `PayoutSet`, `FeeSet`, `RelayDepositorySet`) make monitoring harder.
- **L-4:** old deposit addresses (v2 and v3 accounts) keep receiving funds if users reuse them. The app shows a "Move to my new account" card for v2/v3 on Monad only.

### Slither triage (0.11, `src/`, excluding YieldBook)

| Detector | Verdict |
|---|---|
| `arbitrary-send-eth` on `_sendNative` | False positive: the destination is the owner (`onlyOwner`) or the owner/payout check in `withdrawWithSig`. |
| `reentrancy-*` on `_swap`, `_place`, `_create` | Mitigated: every external entry is `nonReentrant`; `_create` calls its own freshly cloned account. |
| `incorrect-equality` (UTC day), `timestamp` | Intended: day buckets and deadlines. |
| `unused-return` on `registry.fee()` | Intended: only the recipient is used. |
| `missing-zero-check` | See L-2. |
| `low-level-calls`, `assembly` | Intended: router call and revert bubbling. |

---

## 3. Target architecture (what to change before v5)

Priority order. Each item names the finding it closes.

1. **Admin to a Safe multisig, plus a timelock, plus a guardian.** Closes C-2 and gives every other incident a kill switch. Contract change: a small `Guardian` role in the registry (revoke keeper, delist, pause) and a timelock on increases.
2. **Split keeper roles and move them to a policy signer (KMS).** Closes H-4 and shrinks C-1's blast radius. No contract change beyond role separation in the registry: `isFiller` vs a relayer that needs no role.
3. **Make cross-chain fills verifiable on-chain.** Closes C-1. This is the one real restructuring: replace "pay Relay with a keeper-chosen `depositId`" with a deposit whose recipient and minimum output come from the order (Across-style). Until then: cross-order caps and a fill monitor.
4. **Monitor and auto-revoke.** A separate process with its own key that holds only the guardian role. It watches every fill (local output vs a fresh quote; cross recipient vs Relay's record) and revokes the filler on anomalies. Interim cover for C-1 and H-1.
5. **Relayer economics.** Gas fee or minimum size on place/cancel, sponsored opening only with a deposit, per-owner gas budget. Closes H-2 and M-1.
6. **Web hardening.** Vendored and hashed third-party code, strict CSP, `frame-ancestors 'none'`. Closes H-3.
7. **Encrypt hidden limits at rest; delete them on close.** Closes M-2.
8. **Per-vault caps and a vault pause.** Closes M-3.
9. **v5 cSABLE only after 1–4,** with the M-5 caps designed in.

## 4. Before an external audit

- Property tests (Foundry invariants or Echidna/Medusa) for:
  - an order's funds are only ever in its vault, the account, or delivered at ≥ limit;
  - no path moves account funds to a non-owner address except the fee, gas and depository legs;
  - nonces and epochs are never reusable.
- Write the trust assumptions (this document, section 1) into the README, so the external auditors start from them.
- Freeze a commit, and keep the deployment addresses and the admin/keeper map current.

## 5. Current exposure

At the time of writing, the keeper reported **0 open orders** on Monad and Base, so C-1's present exposure is nil. Every finding above becomes live as soon as users place cross-chain orders, which the app allows today. **Until item 3 (or its interim caps and monitor) ships, cross-chain orders should be capped or disabled in the app.**

---

## 6. Status after the v5 hardening branch (`feat/v5-hardening`, 2026-10-05)

| Finding | Status | Where |
|---|---|---|
| **C-1** keeper-chosen Relay `depositId` | **Fixed in v5.** Cross fills deposit into Across' SpokePool with recipient, output token, chain and `outputAmount ≥ destMinOut` all taken from the revealed order; Across enforces them on-chain. Fork-tested against the real Monad SpokePool. v4 (live): cross fills off in the keeper and cross orders blocked in the app. | `SableAccount.fillCrossOrder`, `_depositAcross`; `test/fork/AcrossFork.t.sol` |
| **C-2** single admin EOA | **Partly fixed.** v5 registry adds a **guardian** that can only reduce risk, instantly (revoke keeper, delist, disallow vault, pause new orders or cross fills; never lift a pause or grant). Pending: the Safe 2-of-3 and the 24h timelock (Phase 1, needs Juan's signers). | `TokenRegistry` guardian section |
| **H-1** surplus capture on local fills | **Mitigated.** The monitor compares each fill with a fresh quote and revokes a keeper after 3 fills >2% short within an hour. A design fix (competitive fills) stays future work. | `monitor/src/rules.js` |
| **H-2** relayer gas drain | **Fixed.** Agent place/cancel sign a capped `gasFee`; sponsored opening needs a deposit at the account address first. | `placeOrderWithSig`, `cancelOrderWithSig`; `keeper/src/relay.js` `funded()` |
| **H-3** CDN and inline script risk | **Fixed (app, deploy pending).** viem, lightweight-charts and three.js are bundled same-origin; the build emits a CSP with hashed inline scripts, `frame-ancestors 'none'` and `nosniff`. Every page was checked under the policy with zero violations. | `vendor/`, `build.js headersFor` |
| **H-4** one raw keeper key | **Pending** (Phase 2: role keys through Turnkey). | — |
| **M-1** dust slows the filler | **Fixed.** Per-token `minAmount` on-chain; the keeper skips orders under `MIN_ORDER_USD` and serves big orders first. | `orderBounds`; `filler.tick` |
| **M-2** plaintext hidden limits | **Fixed.** AES-256-GCM at rest with `SECRETS_KEY`, deleted when the order closes. | `keeper/src/ledger.js` |
| **M-3** unbounded vault exposure | **Partly fixed.** The guardian can disallow a vault at once. Per-vault deposit caps would need cross-account accounting and are left for later. | `disallowVault` |
| **M-4** endpoint resource use | **Fixed.** Rate limits on `/secret` and `/receipt`, and at most 200 receipt waits at once. | `keeper/src/index.js` |
| **M-5** v5 `setWeight` pool drain | **Open by design.** cSABLE isn't built yet; its guards are in the D21 spec. | — |

**New in v5, reviewed:**
- A keeper can't push an Across deposit below the limit (`outputAmount ≥ destMinOut`).
- An absurdly high `outputAmount` only delays the order: no relayer fills it, and Across refunds the account after `CROSS_FILL_WINDOW` (1h).
- Guardian pauses never stop an owner from cancelling and withdrawing.
- Slither on v5 shows only the same intended patterns as v4, plus intended zero-address uses in `setGuardian` and `setAcrossSpokePool` (zero disables).

**Property tests:** `test/Orders.invariant.t.sol` runs 500 runs × 100 calls with an adversarial keeper. It picks the router mode (divert, underpay, overpull), outputs and gas, and sometimes tampers with the revealed secret or recipient. Invariants:
- account USDC only in allowed places;
- vault shares equal the open orders' shares;
- no fill below its limit or to another recipient;
- signatures work once.

A probe invariant confirms the campaign really fills orders.

**Size:** `SableAccount` is 23,236 bytes (limit 24,576), so cSABLE must live in its own contract.
