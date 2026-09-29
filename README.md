# Sable

Local contracts for account-based trading and a yield-bearing order-book prototype on Monad.
This repository is not evidence of what is currently deployed.

Two pieces live here:
- **SableAccount**: the owner calls trading/withdrawal methods directly. The local v3 agent signs EIP-712 swaps and withdrawals for a submitter; signed withdrawals are restricted to the owner or approved payout wallet. Swaps use allowed routers and account-level checks.
- **YieldBook** (spike): an order book whose quote balances and resting bids can earn ERC-4626 vault yield. Local tests use mocks; real-vault integration is a separate check.

Intent and kill criteria: [docs/INTENT.md](docs/INTENT.md). Design decisions and tradeoffs: [docs/DECISIONS.md](docs/DECISIONS.md).

Start with [Local verification](docs/LOCAL-VERIFICATION.md) for current commands,
observed results, version boundaries and unresolved risks. Historical decisions are
not a substitute for current source or deployment verification.

## What the local tests cover

These are bounded regression scenarios, not an exhaustive security proof.

### SableAccount

| Claim | Test |
|---|---|
| Direct withdrawals require the owner; signed agent withdrawals require an allowed recipient | `test_onlyOwnerWithdraws`, `test_agentWithdrawsOnlyToOwner`, `test_agentWithdrawsToApprovedPayoutOnly` |
| Per-trade and daily caps hold; the day resets at UTC midnight | `test_agentPerTradeCap`, `test_agentDailyCapResetsAtUtcMidnight` |
| No sequence of agent trades exceeds the daily cap | `testFuzz_agentNeverExceedsDaily` |
| Mock routes with diverted/underpaid output or excessive input revert; successful swaps clear allowance | `test_divertedOutputReverts`, `test_underpaidOutputReverts`, `test_routerCannotPullMoreThanApproved`, `test_noAllowanceLeftAfterSwap` |
| Current registry listings and caps bound local agent overrides on both sides; owner exits and router restrictions remain | `test_registryCapsOverrideCannotListOrReviveEitherSide`, `testFuzz_registryCapsComponentWiseMinimum`, `test_registryCapsReductionUsesExistingDailySpend`, `test_registryCapsDelistingKeepsOwnerExitAndRouterChecks` |
| Both signed paths bind the current epoch; same-key reinstatement cannot revive an earlier order, and nonces remain global | `test_epochSwapReinstatement`, `test_epochWithdrawalReinstatement`, `testFuzz_epochRotationInvalidatesPendingOrders`, `testFuzz_epochNonceIsGlobalAcrossOperationsAndRotations` |
| Epoch, every order field, domain and deadline are checked; reverted execution preserves the nonce | `testFuzz_epochEveryOrderFieldIsSigned`, `testFuzz_epochDomainSeparation`, `testFuzz_epochDeadlineBoundary`, `testFuzz_epochFailedExecutionDoesNotConsumeNonce`, `testFuzz_epochRejectsLegacySchemaEvenAtEpochZero` |
| One account per owner at a predictable address; the implementation can't be initialized | `test_factoryGivesPredictableAddress`, `test_oneAccountPerOwner`, `test_implementationCannotBeInitialized` |
| Basic signature, nonce, deadline and gas-fee rules execute on the local v3 account | `test_signedSwapRejectsWrongSignerAndChangedCalldata`, `test_signedWithdrawalNonceIsOneUse`, `test_signedWithdrawalExpiresAfterDeadline`, `test_signedSwapPaysGasFromOutputAndKeepsNetMinimum` |

### YieldBook

| Claim | Test |
|---|---|
| Idle balances earn vault yield, pro rata | `test_idleBalanceEarnsYield`, `test_yieldSplitsProRata` |
| A resting bid earns until it fills, maker keeps the yield | `test_restingBidEarnsYieldThenFills` |
| Cancel returns principal plus yield | `test_cancelReturnsPrincipalPlusYield` |
| Fills never touch the vault, so they work with a 100% utilized market | `test_fillsNeverTouchTheVault` |
| Withdrawals degrade cleanly when the vault is illiquid | `test_withdrawDegradesCleanlyWhenVaultIlliquid` |
| Price-time priority, maker-price fills, far ticks | `test_priceTimePriority`, `test_takerWalksAsksBestPriceFirstAtMakerPrices`, `test_bitmapFindsFarTicks` |
| At most 64 heads are inspected per match call, including cancelled/underfunded entries; partial progress never rests a crossing remainder | `YieldBookInspectionTest` (9 regressions: both directions, exact boundaries, refunds, FIFO and repeated progress) |
| Four conservation/book invariants hold for the configured sampled sequences | `YieldBook.invariant.t.sol` (4 invariants) |
| Optional real-vault fork scenarios exist; execution is not established by the offline suite | `test/fork/MonadFork.t.sol` |

## Layout

```
src/SableAccount.sol   user trading account with on-chain agent limits
src/SableAccountFactory.sol  one clone per owner, deterministic address
src/YieldBook.sol      single-pair CLOB on internal balances, quote pool in an ERC-4626 vault
src/TickBitmap.sol     two-level tick bitmap for best-price discovery
test/                  unit, fuzz, invariant, and Monad fork tests
docs/                  intent (phase 0) and decisions
```

## Offline checks

```bash
forge test --offline --no-match-path 'test/fork/*' -vv
forge build --offline --skip test --skip script --sizes
forge fmt --check
```

Dependencies and Solidity must already be available locally; stop rather than
installing or connecting to RPC implicitly. See the runbook for the verified
Windows executable path and the separate web/API commands.

[CI configuration](.github/workflows/test.yml) declares format, build, tests and
gas reporting. Its explicit RPC-gated step selects `MonadFork`, not `KyberFork`.
No hosted CI result or fork execution is claimed by this document.

## Status

Unaudited work in progress. Account protocol fees and factory/registry administration
exist; the historical "no fees/admin" description applied to the earlier order-book
spike, not the current account system. Local v3 test compatibility is restored,
but frontend/relayer migration and release parity are not complete. Signed tuples
now include `uint64 epoch`; this breaks earlier local v3 ABI/signatures while the
EIP-712 domain version remains `3`. No deployed account is changed by this repair.
The listing-override issue in the runbook remains open. D8 retains its historical
measurement/decision status; it is not a measurement reproduced in this verification.
