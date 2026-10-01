# Limit orders that earn yield while they wait

Status: design approved by Juan (2026-10-01): both Monad and cross-chain orders, vault chosen by the user.
Decision record: DECISIONS D17. Builds on SableAccount v3 (signed agent orders, D16).

## The moment we are building

> "Buy SOL with 300 USDC if it drops to $X. Until then, the 300 USDC earns yield."

The user sees the chart, and in a small card: their open orders, the live price and how far it is from
each order, the APR the waiting money earns and what it has earned so far, and the 1h / 24h / 7d change.

## Pieces

| Piece | Where | Job |
|---|---|---|
| Orders + vault custody | `SableAccount` (per user, on Monad) | Holds each order's funds as vault shares; fills or cancels it |
| Allowlists | `TokenRegistry` (admin) | Which vaults, which Relay receiver, which keepers |
| Keeper + relayer | worker on Railway (key only in Railway env) | Watches prices, fills orders; relays agent-signed orders |
| Order UI | `monad-spotdex` terminal | Limit ticket, vault choice, order card over the chart |

## Yield: user-chosen ERC-4626 vault

Each order names a vault. The registry admin allowlists vaults (`setVault`), and an order's vault must be
allowlisted and have `asset() == tokenIn`. Verified on Monad mainnet, 2026-10-01:

| Option | Vault (ERC-4626) | Asset | Base APY | Size |
|---|---|---|---|---|
| Aave v3 | `0xC554aFfE2f581F5E0811e0D42D484ECaC5c6B8e2` (Wrapped Aave Monad USDC, official address book) | USDC | 4.10% | Aave USDC market $13.8M |
| Euler Earn · Clearstar | `0xE1BcA19baA63894D374578320551633320436523` (from the Euler Earn factory `0xF463…94cF`) | USDC | 6.80% | $5.79M |

APR shown in the app = DefiLlama base APY for the pool (`0a1131e6-a59d-537c-b18f-826b9583f01f` Aave,
`d711af54-e736-470f-8a22-431a23de76df` Euler). Incentive rewards (1.7% / 1.25%) are claimed elsewhere and are
NOT earned by the vault, so they are never shown as part of the APR.

"Earned so far" is exact: `vault.convertToAssets(order.shares) - order.amountIn`.
Every order names a vault: its funds always sit in vault shares, isolated from the account balance the
agent trades with.

## Order lifecycle

```
place   owner tx, or agent-signed (fast key, caps apply) relayed by the keeper
        → funds move from the account into the vault; the order stores its shares
fill    redeem the order's shares → spend amountIn → the account keeps any yield above it (as tokenIn)
cancel  owner, or agent-signed → redeem shares back into the account (yield included)
expire  after `deadline` nobody can fill; owner/agent cancels to get funds back
```

### Two kinds of fill, two trust models

**Monad (local) — price-protected on-chain.** `fillOrder(id, router, data, gasFee)` is keeper-only (see below). The order stores
`minOut`: the least `tokenOut` the account must receive, which *is* the limit price
(`minOut = net amountIn / limitPrice`). The contract enforces `received >= minOut + gasFee`, so a keeper
can only fill at the user's price or better, or not at all. Same router allowlist, fee, approval-reset
and over-spend checks as `swap`.

Why keeper-only and not permissionless: anyone filling could route through a pool they control and hand
the user exactly the limit while the market is better, keeping the difference. Restricting fills to
registry keepers keeps that surplus with the user; liveness depends on the keeper, and the owner can always
cancel. Keepers may also cancel *expired* orders, which only returns funds to the account.

**Cross-chain (e.g. SOL on Solana) — keeper-trusted, bounded.** No SOL trades on Monad (checked
2026-10-01), so buying SOL means paying a Relay solver on Monad and receiving on Solana, which the account
cannot observe. `fillCrossOrder(id, depositId, gasFee)`:
- only a registry keeper may call it;
- pays exactly `amountIn - fee - gasFee` of `tokenIn` into the registry's allowlisted Relay depository with
  `depositErc20(account, tokenIn, amount, depositId)`, built by the contract; the approval is exact and reset.
  (Verified 2026-10-01: for a contract `user`, Relay's quote returns approve + `depositErc20` on
  `0x4cd00e387622c35bddb9b4c962c136462338bc31`; 300 USDC → 2.527 SOL, ~0.4% all-in, ~1 s.);
- emits `CrossFilled(id, depositId, destChainId, recipient, destToken, paid)` so any mismatch between the order and
  what Relay delivered is publicly provable.

Agent-signed cross-chain orders may only pay the recipient the owner approved for that chain
(`setCrossRecipient`), so a leaked agent key cannot create an order paying itself.

What the contract cannot check: that the `depositId` was quoted for this order's `recipient`, `destToken`
and `destMinOut`. The keeper checks it against the Relay quote before calling. A compromised keeper key
could route one order's funds to a wrong recipient; the blast radius is bounded by that order's amount
(and the agent caps when the agent placed it). The UI says this plainly next to cross-chain orders.

## Contract surface (additions)

```solidity
struct OrderParams {           // what the owner (or the agent) signs
    address tokenIn;      // what the order spends (USDC)
    address vault;        // allowlisted ERC-4626 of tokenIn it earns in while waiting
    address tokenOut;     // Monad token to receive; address(0) for cross-chain
    uint64  deadline;
    uint32  destChainId;  // 0 = Monad fill; otherwise the Relay destination chain
    uint128 amountIn;     // total spent on fill, protocol fee included
    uint128 minOut;       // local: least tokenOut received (the limit price)
    uint128 destMinOut;   // cross-chain: least destToken the keeper's quote must deliver
    bytes32 recipient;    // cross-chain recipient (EVM address or Solana pubkey)
    bytes32 destToken;    // cross-chain token to receive
}
struct LimitOrder { OrderParams p; uint256 shares; }   // shares set on placement
placeOrder(OrderParams) onlyOwner → id
placeOrderWithSig(OrderParams, nonce, sigDeadline, epoch, sig) → id     // agent: caps on amountIn, listed tokenOut
fillOrder(id, router, data, gasFee)                                  // registry keeper only; minOut enforced
fillCrossOrder(id, depositId, gasFee)                                // registry keeper only
cancelOrder(id) owner, or a keeper once expired / cancelOrderWithSig(id, nonce, deadline, epoch, sig)
orderValue(id) view → current assets incl. yield
```

Registry additions (admin, Ownable2Step): `setVault(vault, allowed)`, `setKeeper(keeper, allowed)`,
`setRelayDepository(depository)`. Account addition (owner): `setCrossRecipient(chainId, recipient)`.

Gas: `gasFee` is capped at `MAX_GAS_BPS` (5%) of what the fill moves and is paid to the treasury, never to
the caller (same rule as v3, D16). The keeper's MON is topped up from the treasury.

## Risks and how they are handled

- **Vault illiquidity** (lending market 100% utilised): redeem reverts, the fill waits; cancel also waits.
  Shown in the UI as "funds temporarily locked by the lending market". Users pick the vault knowing this.
- **Vault loss**: shares can be worth less than `amountIn`. A local fill then spends what the shares are
  worth; `minOut` is fixed, so the fill only happens if that still meets the limit price.
- **Keeper downtime**: orders simply don't fill; funds keep earning and can always be cancelled.
- **Price at fill**: local fills can never be worse than the limit. Cross-chain fills depend on the
  keeper's quote check (`destMinOut`).
- **Contract size**: SableAccount was 14.5 KB and is 22.0 KB with orders (EIP-170 limit 24.6 KB). Further
  features should move to a library or a second contract rather than squeeze the margin.

## Evidence (2026-10-01)

- `test/LimitOrders.t.sol`: 18 tests (placement, yield, limit enforcement, keeper-only fills, gas cap,
  expiry, illiquid and lossy vaults, agent signatures with an independent EIP-712 encoding, caps, Shield,
  rotated keys, approved cross-chain recipients, depository payment). Full non-fork suite: 108/108.
- `test/fork/OrderVaultsFork.t.sol` on Monad mainnet state: 300 USDC for 30 days → 301.01 (Aave) and
  301.62 (Euler Clearstar); cancel returns principal plus yield.
- SableAccount runtime size 22,012 B (EIP-170 limit 24,576).

## Build order

1. Contracts + tests (this change): orders, vault custody, registry allowlists; fork test against both
   real vaults.
2. Keeper/relayer worker: order discovery from `OrderPlaced` logs (Monad `eth_getLogs` is capped at
   100 blocks per call), price checks via Kyber (local) and Relay (cross-chain), fills, signed-order relay.
3. App: v3 migration, limit ticket with vault choice, order card over the chart (live price,
   distance, APR, earned, 1h/24h/7d).
4. Deploy: Juan deploys the factory from deploy.html, creates the keeper key in Railway, funds it,
   allowlists vaults, keeper and Relay receiver.
