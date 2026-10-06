# Sable · Decisions

This is the log of how Sable got here, in order. Later decisions refine earlier ones: the
first spike was an on-chain order book (D1–D8), then trading accounts (D9–D15), then limit
orders that earn (D17 onwards). Newer designs live in [specs](specs/): D19 vaults on any chain,
D20 hidden orders, D21 sharing fees with the orders that wait.

Each decision: what, why, and the tradeoff we accept.

## D1 · Internal balances, fills never touch the lending vault
Users deposit into Sable. Quote balances (free or locked in bids) are shares of one pool worth `cash + vault assets`. A fill moves pool shares between accounts; no tokens leave the contract, so no vault withdrawal happens at match time.
- **Why:** the risk "a fill fails because the lending vault is fully utilized" disappears from matching. Fills are also cheap: no external calls.
- **Tradeoff:** vault liquidity risk moves to withdrawals. A user leaving Sable may have to wait if the vault is illiquid and the cash buffer is spent.

## D2 · Cash buffer (bufferBps) kept outside the vault
A share of pool assets stays as cash; only the excess is deposited.
- **Why:** most withdrawals are served from cash, and anyone can call `rebalance()`.
- **Tradeoff:** the buffer earns nothing, so yield is `(1 - buffer) * vault APY`.

## D3 · ERC-4626 as the only lending interface
- **Why:** Euler V2 and Morpho vaults are ERC-4626; Aave has 4626 wrappers. One adapter covers the three main lenders on Monad.
- **Tradeoff:** vault-specific features (e.g. Euler sub-accounts) are out of reach in v0.

## D4 · Yield on the quote asset only (v0)
- **Why:** stablecoins are where the parked capital is. One pool keeps accounting simple to audit.
- **Tradeoff:** asks (base locked) earn nothing until a base vault is added.

## D5 · Two-level tick bitmap, uint24 ticks
Price = `tick * tickSize` (quote units per 1 whole base token). Level-1 words mark non-empty ticks, a summary marks non-empty words.
- **Why:** finding the next best price costs at most ~512 storage reads, so a far-away order cannot grief the book.
- **Tradeoff:** price range is `tickSize * (2^24 - 1)`; markets pick tickSize to fit.

## D6 · Virtual shares against pool inflation
Share conversions add a virtual offset (1e6 shares, 1 asset), as in OpenZeppelin ERC-4626.
- **Why:** blocks the first-depositor donation attack on the share price.

## D7 · Lot and tick sizes chosen so trade values are exact integers
Constructor requires `(lotSize * tickSize) % baseScale == 0`.
- **Why:** no rounding in trade value; rounding only happens in share conversion, always in the pool's favour.

## Not in the spike (on purpose)
Fees, admin, upgrades, base-side yield, market orders routed to AMMs, agents, cross-chain deposit. Each lands after the core primitive is proven.

## D8 · OPEN · Share-price read cost on real vaults
Measured on a Monad mainnet fork (chain 143) against Morpho "Steakhouse High Yield USDC":
- one taker fill = **160,639 gas**, of which ~74k is reading the vault share price (`convertToAssets` on a MetaMorpho vault accrues interest across markets inside the view). With a cheap mock vault the same fill is ~87k.
- Tried: cache the pool value once per block → fill drops to **82,373 gas**, but the test `test_restingBidEarnsYieldThenFills` caught that any pool value change inside the block (yield, donation, bad-debt realization) shifts value from maker to taker. **Reverted.** Matching reads the price fresh on every call.
- Candidates to evaluate next, each with its own risk:
  1. Cache keyed on (block, timestamp, book cash, book vault shares) plus a vault-specific cheap price source.
  2. Settle fills in pool shares at the maker's lock-time price and true-up yield on close.
  3. Read the underlying Morpho markets directly with the vault's cheaper internal accessors.
- Kill-criterion status: 160k vs a plain book fill (~60-100k, to be measured on the same fork) is on the edge of "more than 2x". Must be resolved before building further on top.

## D9 · SableAccount: agent trading bounded on-chain (SAW v1.5 semantics on EVM)
One clone per user (`SableAccountFactory`, deterministic address from the owner, so the app can show a deposit address before the account exists). The owner trades and withdraws freely. The agent can only `swap`.
- **Agent can never move funds out.** Only the owner can withdraw. A leaked agent key is bounded by the limits below.
- **Limits per token, in the token's own units** (SAW M-1): no oracle, so a cap can't be bypassed by valuing one token in another. A token is agent-tradable iff its daily cap > 0; both sides of a swap must be listed.
- **Hard caps always revert** (SAW v1.5): per-trade, daily, cooldown. Nothing over the cap is queued; the owner signs it directly in the app.
- **UTC-day window** (SAW L-1): the agent can't choose when its day starts.
- **Aggregator calldata is untrusted; the result is checked**: only allowlisted routers, exact approval reset to 0 after the call (PayClaw H-1), `minOut > 0` (PayClaw H-2), output must land in the account and reach `minOut`, input spent never exceeds `amountIn`.
- **Tradeoff:** without an oracle the contract can't judge price; a malicious agent could accept a bad `minOut`. Loss is bounded by the per-trade and daily caps. Next: a TWAP sanity check against a Monad pool.
- **v1 limits:** ERC-20 only (native MON as WMON), no on-chain approval queue.

## D10 · Guarded mainnet battle-test
The factory ships closed: only wallets the admin lists can open an account (`setAllowed`), and `openToEveryone()` is a one-way switch for the public launch. The app shows a permanent, non-dismissible banner: mainnet battle-test, unaudited, access restricted, use amounts you can afford to lose.
- **Why mainnet before audit:** an aggregator-routed account can only be battle-tested against real liquidity; testnet has no real routes. The exposure is limited to listed wallets and the amounts they choose.
- **Why gate on-chain, not only in the UI:** a UI gate is bypassed by calling the contract directly.
- **Tradeoff:** the admin key can list wallets and open the factory. It can't touch any account's funds.

## D11 · Fast trading with a browser session key (no custody, no pooled funds)
The app can generate a key in the user's browser and register it as the account's `agent` (one owner signature, plus a small MON transfer for its gas). Trades inside the agent limits are then signed by that key: no wallet pop-up, about a second end to end on Monad. Over the limits, the contract rejects and the app falls back to an owner signature.
- **Why not pool funds like a custodial app:** custody concentrates risk and brings legal exposure. The session key gets the same speed while funds stay in the user's own account.
- **Bound:** the key lives in browser storage. If stolen it can only swap inside the per-trade and daily caps and can never withdraw (D9). Turning fast trading off calls `setAgent(0)`.
- Also: receipts are polled every 250 ms instead of viem's 4 s default; Monad finalizes in under a second.

## D12 · Open battle-test with informed consent (supersedes the UI side of D10)
Decided by Juan: no allowlist for testers. The factory is opened with the one-way `openToEveryone()`, signed by the admin. The app asks for an explicit acknowledgment before the first connection: live on mainnet, contracts not audited, funds stay in the user's own account but could be lost to a bug, use small amounts. The banner stays permanent.
- **Why:** blocking people slows the battle-test; clear, explicit consent is enough at this stage.
- **Accepted risk:** anyone can deposit real funds into unaudited contracts. Limits: no custody, owner-only withdrawals, agent caps, and the audit stays on the roadmap before any promotion.

## D13 · Sable Shield: agents trade only vetted tokens (v2 contracts)
A `TokenRegistry`, deployed by the factory and curated by the admin, lists the tokens an agent may trade, each with default caps in its own units (about $25 per trade and $100 per day at listing price). `SableAccount` v2 reads those caps unless the owner set stricter ones; both sides of an agent swap must be listed. Delisting stops agents at once; the owner can always trade and exit.
- **Off-chain checks before listing (`/api/shield`):** liquidity ≥ $50k, 24h volume ≥ $10k, pool age ≥ 3 days, a $20 buy-and-sell round trip losing < 5% (honeypots and hidden taxes), contract permissions and top-10 holder share from GoPlus when it covers the token. A check that couldn't run marks the token "review": the curator decides, it's never listed blindly.
- **Why:** with no wallet prompts after login, protection has to be native. Listing is a screen, not an endorsement (see Terms).
- **Also in v2:** native MON sent to an account is wrapped on arrival (deposit = one plain send) and `withdrawNative` returns MON.
- **Tradeoff:** caps drift with price until the curator refreshes them; a keeper role can automate this later.

## D14 · Frictionless: one signature to start, none to trade, protocol fee on-chain
- **Onboarding in one transaction.** `createAccount` is payable: the first deposit creates the account, funds the fast-trading key (`agentGas`) and deposits the rest (wrapped to WMON on arrival). USDC can be sent to the predicted address first and the account created in the same batch. Gas for a missing agent is rejected, so no MON is ever sent to address(0).
- **No prompts after that.** The fast key can also withdraw, but only to the owner's wallet, and refuel its own gas from the account (`refuelAgent`, max 2 MON per UTC day). A leaked key can send funds only back to their owner, and burn at most 2 MON a day of gas.
- **Protocol fee enforced in `SableAccount.swap`,** taken from the input before routing, so it applies to every trade through Sable regardless of the front-end. Set in the Shield registry (`setFee`), **hard-capped at 1% on-chain**. Launch value: 0.30% to the admin wallet.
- **Tradeoff:** routes must be built for `amountIn - fee`; the app does this, and a route built for the full amount simply fails (the router can't pull more than it was approved).

## D15 · Instant withdrawals to approved wallets
The owner can approve one extra wallet (`setPayout`, one signature, e.g. an exchange deposit address). The fast key may withdraw to the owner or to that wallet, so withdrawals are one tap and settle in about a second, like a custodial app. The key can't approve a destination itself; removing the payout (`setPayout(0)`) revokes it at once. Same model as exchange withdrawal allowlists.

## D17 · Limit orders that earn yield while they wait
An order's funds leave the account balance into an ERC-4626 vault the user picks from an admin allowlist (Aave v3 static aUSDC or Euler Earn Clearstar USDC at launch) and earn there until a keeper fills it or the owner cancels. Yield above the order amount stays in the account. Design and evidence: `docs/specs/2026-10-01-limit-orders-yield-design.md`.
- **Monad fills are price-protected on-chain:** `minOut` is the limit price and the contract enforces it, so a keeper only chooses when. Fills are keeper-only so nobody can route through their own pool, hand over exactly the limit and keep the surplus.
- **Cross-chain fills (SOL on Solana) trust the keeper, bounded:** the contract pays Relay's depository itself (exact approval, reset), but can't see delivery on the other chain, so the keeper must quote the order's recipient and minimum. Agent-signed cross-chain orders can only pay a recipient the owner approved per chain.
- **Why the user picks the vault:** APR and risk differ (Aave ~4.1%, battle-tested; Euler Earn ~6.8%, curated strategy). Only base APY is shown; incentive rewards aren't earned by the vault.
- **Tradeoffs:** a fully utilised lending market can delay fills and cancels; keeper downtime delays fills (funds keep earning and can be cancelled); SableAccount is now 22.0 KB of the 24.6 KB limit.

## D18 · Points reward filled orders, boosted by money kept waiting in orders
Decided by Juan (2026-10-01).
- **Base:** every filled order earns `filled USD × 10` points. Orders that never fill earn no points (only their vault yield): points reward using Sable.
- **Multiplier:** `1 + 0.73 × log10(1 + D / 1000)`, capped at 3x, where D is the USD × days the user kept in open orders over the trailing 7 days (the filled order's own waiting time included). Example: $1,000 open for 2 days → D = 2,000 → 1.35x, so filling a $1,000 order then earns 13,500 points. $1,000 for 7 days → 1.66x; $5,000 for 7 days → 2.14x; $50,000 for 7 days → 2.86x. Log scale: more always helps, with diminishing returns, so size alone can't run away.
- **Order price doesn't matter** for the multiplier: any open order counts, however far from the market. An order stops counting when it fills, is cancelled or its funds leave the vault.
- **Wash trading is not blocked:** each round trip pays the 0.30% fee plus slippage (about $0.003 per point), which goes to the protocol.
- **How, first:** computed off-chain by the keeper from the account events it already reads (`OrderPlaced`, `OrderFilled`, `OrderCancelled`). No contract change. Token, on-chain staking and an order NFT come later; a transferable NFT needs a custody redesign because each user's orders live in their own account.
- **Considered and rejected:** distance-to-market weighting (unneeded for the goal); points for deposits alone (option B: a small base per USD-day).
