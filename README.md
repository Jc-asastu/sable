# Sable

Trade on Monad from any chain, with an agent that works inside limits enforced on-chain.

Two pieces live here:
- **SableAccount**: each user's trading account. The owner trades and withdraws; an optional agent can only swap, inside per-token limits. Swaps go through an aggregator (KyberSwap on Monad) and the result is checked on-chain.
- **YieldBook** (spike): an order book whose idle balances and resting orders earn lending yield. Stays on testnet until audited.

Intent and kill criteria: [docs/INTENT.md](docs/INTENT.md). Design decisions and tradeoffs: [docs/DECISIONS.md](docs/DECISIONS.md).

## What the tests prove

### SableAccount

| Claim | Test |
|---|---|
| The agent can never withdraw | `test_onlyOwnerWithdraws` |
| Per-trade and daily caps hold; the day resets at UTC midnight | `test_agentPerTradeCap`, `test_agentDailyCapResetsAtUtcMidnight` |
| No sequence of agent trades exceeds the daily cap | `testFuzz_agentNeverExceedsDaily` |
| A bad route can't take funds: diverted or underpaid output reverts, the router can't pull more than approved, no allowance is left behind | `test_divertedOutputReverts`, `test_underpaidOutputReverts`, `test_routerCannotPullMoreThanApproved`, `test_noAllowanceLeftAfterSwap` |
| Only listed tokens and routers; revoked agents and strangers are rejected | `test_agentCannotTradeUnlistedToken`, `test_routerNotAllowed`, `test_revokedAgentCannotTrade`, `test_strangerCannotTradeOrConfigure` |
| One account per owner at a predictable address; the implementation can't be initialized | `test_factoryGivesPredictableAddress`, `test_oneAccountPerOwner`, `test_implementationCannotBeInitialized` |

### YieldBook

| Claim | Test |
|---|---|
| Idle balances earn vault yield, pro rata | `test_idleBalanceEarnsYield`, `test_yieldSplitsProRata` |
| A resting bid earns until it fills, maker keeps the yield | `test_restingBidEarnsYieldThenFills` |
| Cancel returns principal plus yield | `test_cancelReturnsPrincipalPlusYield` |
| Fills never touch the vault, so they work with a 100% utilized market | `test_fillsNeverTouchTheVault` |
| Withdrawals degrade cleanly when the vault is illiquid | `test_withdrawDegradesCleanlyWhenVaultIlliquid` |
| Price-time priority, maker-price fills, far ticks | `test_priceTimePriority`, `test_takerWalksAsks...`, `test_bitmapFindsFarTicks` |
| Accounting never breaks under random action sequences | `YieldBook.invariant.t.sol` (4 invariants) |
| Works against a real Morpho USDC vault on Monad mainnet | `test/fork/MonadFork.t.sol` |

## Layout

```
src/SableAccount.sol   user trading account with on-chain agent limits
src/SableAccountFactory.sol  one clone per owner, deterministic address
src/YieldBook.sol      single-pair CLOB on internal balances, quote pool in an ERC-4626 vault
src/TickBitmap.sol     two-level tick bitmap for best-price discovery
test/                  unit, fuzz, invariant, and Monad fork tests
docs/                  intent (phase 0) and decisions
```

## Pipeline

```bash
forge build
forge test                                                          # unit + fuzz + invariant
forge test --gas-report --nmc Invariant                             # gas per function
MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc MonadFork -vv   # real Monad state
forge fmt --check
```

CI (`.github/workflows/test.yml`) runs format, build, all tests and the gas report on every push.
Fork tests run in CI when the repository variable `MONAD_RPC_URL` is set.

## Status

Spike. Not audited. No fees, admin or upgrades yet. Open decision D8 (share-price read cost on real vaults) must be resolved before building further.
