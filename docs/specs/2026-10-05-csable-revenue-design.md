# D21 — cSABLE: limit orders share the protocol's trading revenue

Date: 2026-10-05 · Status: design, for Juan's review · Ships in: contracts v5 (one deploy)

## Idea

Money waiting in a limit order earns from two sources at once:

1. **Vault APR:** the ERC-4626 vault the order sits in. This already works (D17); it compounds by itself through the share price.
2. **cSABLE reward:** a share of the fees every Sable trade pays, paid in USDC.

The display reads: `6.1% vault + 22.0% cSABLE = 28.1%`. Both numbers are real.

- The cSABLE % comes from fees actually collected, not from a token price.
- With no token there is nothing to invent, so it can launch before SABLE exists.

## Fees

| Event | Fee | Goes to |
|---|---|---|
| Market trade (swap, fast or owner) | 0.50% | 0.30% cSABLE pool · 0.20% creator |
| Limit order **fills** | 0.45% | 0.30% cSABLE pool · 0.15% creator |
| Limit order **cancelled** (owner or agent) | 0.225% | all to the cSABLE pool |
| Limit order **expires** (keeper returns it) | 0.225% | all to the cSABLE pool |

- Fees are taken **when the order closes**, out of what the vault returns. Placing costs nothing up front, so an order needs no extra balance for its fee.
- **Limit fills are cheaper than market trades** on purpose: patience and resting liquidity are the product.
- **Cancel and expiry fees go entirely to the pool.** People who leave pay the people who stay. Expiry counts as a cancel; otherwise short expiries would be a free way to farm.
- **Why cancelling has a cost:** without it, an order far from the market is free yield on the pool. At 0.225%, farming has to keep the money waiting about 4 days at 22% APR just to break even. That is real committed liquidity, which is the point.
- All rates are registry settings in basis points, with an on-chain cap (1%). Changing them is an admin transaction, not a redeploy.

## cSABLE accounting

cSABLE is **not a transferable token**. It is the order's weight in the pool, minted when the order opens and burned when it closes. The weight is the order's `amountIn` in USD, at 6-decimal USDC units. USDC and USDT orders are 1:1.

The standard reward-per-share accumulator (as in PancakeSwap's MasterChef) makes claims O(1) however many orders exist:

```
pool.accPerWeight += feesInUSDC * 1e18 / pool.totalWeight        on every fee deposit
order.pending     = order.weight * pool.accPerWeight / 1e18 - order.debt
```

- **open:** `totalWeight += w`; `debt = w * acc / 1e18`.
- **close (fill or cancel):** the pending reward is paid to the account; `totalWeight -= w`.
- **claim:** pending is paid; `debt` resets.
- **claim + compound:** pending is added to the same order. The pending USDC is deposited into the order's vault (new shares added to `order.shares`). `amountIn` and the weight grow by the same amount, and `minOut` scales so the limit **price** is unchanged.

### Fees arrive in many tokens

A trade pays its fee in whatever it sells: USDC, MON, a memecoin.

- Fees in USDC go straight into the pool.
- Any other fee token collects in a `FeeBox`. The keeper swaps it to USDC through an allowed router (Kyber) at most once an hour and deposits the result.
- The swap has to deliver at least an oracle-free floor: the quote minus 1%, checked on-chain like any agent swap.
- Accrual is therefore a little "lumpy" for non-USDC fees. The UI interpolates between deposits using the last 24h rate.

### Every order earns, weighted by what it was worth when placed

Every order earns cSABLE: USDC, ETH, MON or a memecoin. Its weight is **its USD value at placement, fixed for the order's life**.

- A bag worth $2k when placed keeps farming as $2k even if it drops to $1k.
- The holder is already at a loss and has money locked in a vault. Sable does not punish them twice (Juan, 2026-10-05).

**Who sets the value:** the keeper, never the page, because the owner controls the page and the agent key.

1. A new order opens with **weight 0**. USDC and USDT are the exception: their weight is set on-chain at 1:1 immediately.
2. The keeper values the order and calls `setWeight(account, id, usd)`. Only a registered keeper can, and only once per order.
   - It quotes on Kyber the USDC that **selling the whole `amountIn`** would return, so price impact is included.
   - It does this twice, about 5 minutes apart, and takes **the lower** quote.
3. Accrual starts from `setWeight`. There is no backdating, so the minutes before it earn nothing.

**Why this resists manipulation:**
- **Pumping a thin pool before placing doesn't pay.** The valuation is the *sale* quote of the full bag, which collapses on a thin pool.
- **A pump has to last** across two quotes about 5 minutes apart.
- **Only registry-allowed vaults earn weight.** An owner may park an order in any vault (v5), and a vault they control can hand the money straight back, so the same dollars could back many orders (audit N-2). Orders in other vaults keep weight 0.
- **One token can't dominate:** weight per token is capped at a share of its pool liquidity (`maxWeightBps`, registry setting, 10% by default).

**Trust:** the keeper already decides when to fill, inside the limit the contract enforces. Valuing is the same trust level, and its worst case is mis-weighting the reward pool. It can never touch an order's funds.

The weight is recorded and the pool tracks it, so the UI shows each order's cSABLE as `weight` (USD at placement). It never needs a live price.

## What the user sees

- **Ticket, Limit:** `While it waits: 6.1% vault + 22.0% cSABLE`. The cSABLE % is the last 7 days of pool deposits × 365 ÷ current total weight. **Fees:** `0.45% if it fills · 0.225% if you cancel`.
- **Earning card:** `$X / day` split into vault and cSABLE, with `Claimable: $Y` and two buttons, **Claim** and **Claim & compound**.
- **Chart lines:** each order's label adds its claimable cSABLE.

## Staking tiers (stage 2, needs the SABLE token)

Staking SABLE gives fee discounts and a cSABLE multiplier:

| Tier | SABLE staked | Fee discount | cSABLE weight |
|---|---|---|---|
| — | 0 | 0% | 1.0× |
| Bronze | set later | 10% | 1.1× |
| Silver | set later | 25% | 1.25× |
| Gold | set later | 40% | 1.5× |

- Thresholds and percentages are registry settings.
- The account reads the owner's tier from a `Staking` contract when it charges a fee or opens weight.
- This is designed in v5 (a `tierOf(owner)` hook, returning tier 0 until SABLE exists) so stage 2 needs no account migration.

## Security notes

- **Pool solvency:** the pool only ever pays out USDC it holds. `accPerWeight` only grows on actual deposits, so a claim can never exceed the deposits.
- **The agent key can claim and compound** (same caps as its other actions). It **cannot** move pool funds anywhere but the owner's account or the order's vault.
- **Rounding:** each claim rounds down. The dust stays in the pool.
- **Re-entrancy:** claim/compound sit under the account's existing `nonReentrant`. The pool is a separate contract that pays only the calling, factory-verified account.
- **Legal (to review before the public launch, not a blocker for building):** sharing protocol revenue with depositors reads closer to a security than points do. Keep "rewards for providing order liquidity" framing, and get counsel before marketing it.

## Rollout

Contracts v5 (one deploy per chain):
- the fee split and close-time fees in `SableAccount`;
- `RevenuePool` (accumulator + claims) and `FeeBox`;
- `addToOrder` for compounding;
- the tier hook.

Keeper: FeeBox swaps every hour, plus the pool APR for the UI. App: ticket, earning card, and the Claim / Claim & compound buttons.

Until v5 is live, v4 keeps its single 0.30% fee to the treasury.

## Example numbers

| Volume / day | Waiting in USDC orders | cSABLE APR |
|---|---|---|
| $200k | $2M | 11.0% |
| $1M | $5M | 21.9% |
| $5M | $10M | 54.8% |

Formula: `0.003 × volume × 365 ÷ waiting`, before cancel and expiry fees (which only add to it).
