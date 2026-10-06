# How Sable works

## The flow of an order

```
owner / session key ──place──▶ SableAccount (one clone per user)
                                   │  deposit amountIn
                                   ▼
                              ERC-4626 vault  (Aave, Euler, Morpho, Fluid: earns while it waits)
                                   │  redeem at fill
keeper ──fillOrder(secret)──▶ SableAccount ──swap via allowed router──▶ output ≥ limit, to the account
                                   └──or Across deposit (v5) ──▶ owner's recipient on another chain
```

1. The owner, or the browser session key within its caps, places an order. The account deposits
   `amountIn` into the vault the user picked and keeps the shares.
2. On-chain the order holds only custody fields and `commit = keccak256(secret)`. The secret (output
   token, minimum out, destination, salt) goes to the keeper, encrypted at rest.
3. When the market reaches the limit, the keeper calls `fillOrder` with the secret. The account checks
   it against the commitment, redeems the shares, swaps through an allowed router and requires the
   output to be at least the limit. Any yield above `amountIn` stays in the account.
4. Cancel any time: the shares are redeemed back to the account, yield included. After the deadline
   a keeper may return the order, and only to the account.

## Pieces

- **`SableAccount`**: one minimal-proxy account per owner at a predictable address. Only the owner
  withdraws freely. The session key ("agent") signs EIP-712 swaps, orders and withdrawals inside
  per-trade and daily caps, and can only send funds to the owner or an approved payout wallet.
  Signatures carry a nonce and an epoch, so rotating the key kills every pending signature.
- **`SableAccountFactory`**: creates accounts, including from the owner's signature so the keeper can
  pay the gas (the keeper only does it once the address already holds a deposit).
- **`TokenRegistry` (the Shield)**: which tokens the agent may trade and with what caps, which vaults
  and keepers are allowed, the protocol fee (capped at 1% on-chain), order bounds and pauses. In v5
  a guardian can pause, revoke a keeper or drop a vault instantly, and can never do the reverse.
- **`SableTimelock`** (v5): OpenZeppelin `TimelockController` with a Safe as the only proposer and
  executor and a 24-hour delay.
- **Keeper** (`keeper/`): follows accounts and orders, fills at the limit, returns expired orders,
  relays session-key calls so users need no gas, and keeps points. One key per role (filler,
  relayer), signed through Turnkey with a policy per key.
- **Monitor** (`monitor/`): an independent process with its own guardian key. It compares fills with
  fresh quotes, alerts on every registry change, and revokes a keeper or pauses cross fills when
  something looks wrong.

## Trust model

The keeper decides when an order fills, never where the money goes. The contract checks the revealed
secret against the commitment, the output against the limit, the recipient against the order, and
that a router can't pull more than it was approved for. A malicious keeper can delay a fill. It can't
take funds or fill below the limit. Admin keys curate the Shield and never touch account funds.

Cross-chain fills (v5) go through Across: the contract builds the deposit from the revealed order, so
the recipient, output token, destination chain and minimum output are enforced by the contract and
by Across, not chosen by the keeper.

## Security status

Full threat model and findings: [security/2026-10-05-threat-model-and-audit.md](security/2026-10-05-threat-model-and-audit.md).

| Finding | v5 |
|---|---|
| C-1 a keeper could redirect cross-chain orders | Fixed: Across deposit built on-chain from the order, fork-tested on the real Monad SpokePool |
| C-2 a single admin key | Fixed: Safe 2-of-3 and a 24 h timelock, plus a guardian that can only reduce risk |
| H-2 the relayer's gas could be drained | Fixed: relayed calls repay their gas, free accounts need a deposit first |
| H-3 web supply chain | Fixed: libraries served from our own origin, strict CSP |
| H-4 one keeper key for everything | Code ready: one key per role through Turnkey |
| M-1 to M-4 | Fixed or bounded |
| N-1, N-2 (vaults the owner picks) | Fixed: redeem measures what really came back; only allowed vaults earn points |

## Tests

- 129 Foundry tests, among them invariants against an adversarial keeper: 500 runs of 100 calls where
  the keeper diverts, underpays, overpulls and tampers with secrets. Funds stay in allowed places,
  shares always back the open orders, no fill goes below its limit or to someone else, and every
  signature works once.
- Fork tests against the real Across SpokePools and real vaults on Monad and Base.
- Keeper and monitor tests in Node.

```bash
forge test
MONAD_RPC_URL=https://rpc.monad.xyz BASE_RPC_URL=https://mainnet.base.org forge test --mp 'test/fork/*'
cd keeper && npm install && npm test
cd monitor && npm install && npm test
```

## Layout

```
src/SableAccount.sol          account: swaps, limit orders in vaults, hidden fills, Across fills, signed calls
src/SableAccountFactory.sol   one clone per owner, deterministic address, sponsored opening
src/TokenRegistry.sol         the Shield: listings and caps, vaults, keepers, fee, guardian, bounds, pauses
src/admin/SableTimelock.sol   24 h timelock, the Safe as only proposer and executor
src/YieldBook.sol             the first spike: an on-chain order book with its quote pool in a vault
keeper/                       Node keeper (viem): ledger, filler, relay, Turnkey signers
monitor/                      watcher with the guardian key
test/                         unit, fuzz, invariant and fork tests
docs/                         vision, decisions (DECISIONS.md), specs, security
```
