# Vaults on any chain, orders executed anywhere (D19 draft)

Goal ("maximum plasticity"): the user's money waits in the vault they pick, on any chain, and the
order buys on whatever chain they want. The user always chooses; Sable shows every vault per chain with its APR.

## What already exists (live on Monad, tested 2026-10-02)
- SableAccount v3: an order's USDC waits in an allowlisted ERC-4626 vault. The keeper fills at the limit.
  The fill is either a local swap (Kyber) or a cross-chain swap through Relay (`depositErc20`).
- Live E2E: the order lands on Base or BSC ~7–8s after it is placed. The yield stays in the account.

## Key fact
SableAccount is not Monad-specific:
- the wrapped native token comes in as a constructor argument;
- vaults are any ERC-4626;
- the Relay depository has the **same address on Base and Arbitrum** (`0x4cd0…bc31`, same `depositErc20`).

So "vault on chain X, buy on chain Y" = **the same contracts deployed on X**. Placing the order on X
works as it does today, and the fill on X is local or cross through Relay to Y. No new contract logic is needed.

## Design
1. **One account per chain, same owner.** The factory and registry are deployed on Base, then Arbitrum, with each chain's own vault allowlist (Aave, Morpho, Fluid, Euler…).
2. **Moving money between vaults** = withdraw on X, Relay to Y, deposit on Y. This is a normal user action; the app shows it as one step.
3. **Keeper multi-chain:** one ledger and one filler per chain from a config list. Same key (one keeper role), gas funded on each chain.
4. **Points:** the existing formula, with the ledger summed across chains.
5. **App:** vault list per chain (`api/vaults` adds Base/Arbitrum from DefiLlama). The order ticket's vault picker shows the chain, and placing the order switches the wallet to that chain.

## Decisions for Juan
- **First chain after Monad:** Base is recommended (deepest USDC lending, cheap gas, Relay at ~$0.02).
- **Who pays to open the account on a new chain:**
  (a) the user, with a wallet prompt and gas on that chain; or
  (b) the keeper sponsors it with the owner's signature (needs `createAccountFor` in the factory, a small contract change).
  (b) is recommended for the "sin txs" experience.
- **Solana vaults:** they need a program, not these contracts. Later (SAW for Solana).

## Phases
1. Deploy on Base (same artifact) and allow 2–3 vaults; the keeper gets a chain list.
2. Vault list across chains in the app, and placing orders on Base.
3. `createAccountFor` (sponsored opening), if decided.
4. Moving between vaults in one step.
