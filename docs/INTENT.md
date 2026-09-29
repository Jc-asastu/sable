# Sable · Phase 0 · Intent

**What:** an on-chain order book on Monad where idle balances and resting orders earn lending yield, reachable from any chain.

**For whom (first):** market makers and active limit-order traders. They make the book deep; retail follows through the cross-chain onboarding layer.

**Why now:** Monad holds ~$1.0B TVL and ~$700M in stablecoins, mostly parked in lending and curated vaults, against ~$56M of DEX liquidity (DefiLlama, 2026-09-28). The Monad Foundation's own post "Ideas for Next Generation CLOB DEXes" (June 2025) describes yield-bearing resting orders; no Monad venue we found ships it.

**Done for this cycle (spike):** a single-pair order book whose quote balances live in an ERC-4626 lending vault, with tests proving:
1. idle balances and resting bids accrue vault yield,
2. matching never touches the vault (fills cannot fail on vault liquidity),
3. withdrawals degrade cleanly when the vault is illiquid,
4. gas per fill measured.

**Kill criteria:**
- Fill gas with yield accounting is more than 2x a plain book fill.
- Makers we ask say yield would not change how much size they rest.
- Withdrawal liquidity cannot be kept above what users need without starving the yield (buffer above ~50%).
