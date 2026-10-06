# Sable

Limit orders that earn yield while they wait, on Monad and Base.

You place a limit order ("buy ETH if it drops to 1,900", "sell MON at 0.05"). Until it fills, the money
behind it sits in an ERC-4626 lending vault and earns interest. When the market reaches your price, a
keeper fills it at your limit or better, and the yield stays yours. Trades can be signed by a browser
session key with on-chain caps, so a market buy confirms in about 2 seconds without wallet pop-ups.

App: [sabledex.vercel.app](https://sabledex.vercel.app) · Web repo: `Jc-asastu/sable-app`

## Live on mainnet (v4)

| | Monad (143) | Base (8453) |
|---|---|---|
| `SableAccountFactory` | `0xe3771074342fa61E0391276EFf639214930983B9` | `0x4bA7C6731Cba147F1b7ab950c1d54d9C9CDB99Da` |
| `TokenRegistry` (Shield) | `0xAAecB6180B27839da137Da04894Df3C544083678` | `0x732a60b051E64dD362512a200aD2586FCF1a2664` |

v4 source is branch `feat/v3-limit-orders`. Measured on mainnet with the live keeper: open account,
hidden limit order placed and filled in 6 to 10 s, market buy in about 2 s.

**This branch (`feat/v5-hardening`) is v5: everything in v4 plus the security hardening below. It is not
deployed yet.** It deploys once, through the deploy page in `sable-app`, and is handed to a Safe 2-of-3
behind a 24 h timelock.

## How it works

```
owner / session key ──place──▶ SableAccount (one clone per user)
                                   │  deposit amountIn
                                   ▼
                              ERC-4626 vault  (Aave, Euler, Morpho, Fluid…: earns while it waits)
                                   │  redeem at fill
keeper ──fillOrder(secret)──▶ SableAccount ──swap via allowed router──▶ output ≥ limit, to the account
                                   └──or Across deposit (v5) ──▶ owner's recipient on another chain
```

- **Accounts** (`SableAccount`, `SableAccountFactory`): one minimal-proxy account per owner at a
  predictable address. Only the owner withdraws freely; the session key ("agent") signs EIP-712 swaps,
  orders and withdrawals inside per-trade and daily caps, to the owner or an approved payout wallet.
- **Shield** (`TokenRegistry`): which tokens the agent may trade and with what caps, which vaults and
  keepers are allowed, the protocol fee (capped at 1%), order bounds and pauses.
- **Hidden limits** (D20): on-chain an order holds only custody fields and `commit = keccak256(secret)`.
  The limit, output token and recipient stay off-chain until the fill reveals them, so nobody can see
  or front-run the book. The keeper stores secrets encrypted (AES-256-GCM) and deletes them on close.
- **Keeper** (`keeper/`): follows accounts and orders, fills at the limit, returns expired orders,
  relays session-key calls so users need no gas, and keeps points.
- **Monitor** (`monitor/`): an independent process with its own guardian key. It compares fills with
  fresh quotes, alerts on every registry change, and can revoke a keeper or pause cross fills instantly.

## Trust model

The keeper decides **when** an order fills, never **where** the money goes. The contract checks the
revealed secret against the commitment, the output against the limit, the recipient against the order,
and that a router can't pull more than approved. A malicious keeper can delay a fill; it can't take
funds or fill below the limit. Admin keys never touch account funds: they curate the Shield.

## Security

Full threat model, findings and status: [docs/security/2026-10-05-threat-model-and-audit.md](docs/security/2026-10-05-threat-model-and-audit.md).
Internal audit only; no external audit yet.

| Finding | v5 status |
|---|---|
| C-1 a keeper could redirect cross-chain orders | Fixed: Across deposit built on-chain from the revealed order; fork-tested on the real Monad SpokePool |
| C-2 single admin EOA | Fixed: Safe 2-of-3 + 24 h `SableTimelock`; an instant guardian that can only reduce risk |
| H-2 relayer gas drain | Fixed: relayed place/cancel repay their gas; sponsored opening needs a deposit first |
| H-3 web supply chain | Fixed: libraries bundled same-origin, CSP with hashed inline scripts |
| H-4 one raw keeper key | Code ready: one key per role, signed through Turnkey with per-role policies |
| M-1..M-4 dust, plaintext secrets, vault exposure, endpoint limits | Fixed or bounded |
| N-1, N-2 (owner-chosen vaults) | Fixed: redeem measures what really came back; only allowed vaults earn points |

Testing:
- 129 Foundry tests, including invariants against an adversarial keeper (500 runs × 100 calls:
  funds only in allowed places, shares back open orders, no fill below its limit or to another
  recipient, signatures work once).
- Fork tests against real Across SpokePools and real vaults (`test/fork`).
- 21 keeper tests and 4 monitor tests.

## Next

- **v5 deploy** on Monad and Base, then a live end-to-end run including cross-chain via Across.
- **cSABLE** (D21): order fees shared with the orders that wait, weighted by their USD value.
- **Tokenized stocks**: xStocks is now native on Monad (NVDAx, TSLAx, SPYx…). Buy limits already work
  through the USDC vaults; sell limits use each stock's official ERC-4626 wrapper. Waiting on liquidity.

## Layout

```
src/SableAccount.sol          account: swaps, limit orders in vaults, hidden fills, Across fills, signed calls
src/SableAccountFactory.sol   one clone per owner, deterministic address, sponsored opening
src/TokenRegistry.sol         the Shield: listings and caps, vaults, keepers, fee, guardian, bounds, pauses
src/admin/SableTimelock.sol   24 h timelock, the Safe as only proposer and executor
src/YieldBook.sol             earlier spike: on-chain order book with the quote pool in a vault
keeper/                       Node keeper (viem): ledger, filler, relay, Turnkey signers
monitor/                      independent watcher with the guardian key
test/                         unit, fuzz, invariant and fork tests
docs/                         decisions (DECISIONS.md), specs (D17–D21), security
```

## Run

```bash
forge test                                   # unit, fuzz and invariant tests
MONAD_RPC_URL=https://rpc.monad.xyz BASE_RPC_URL=https://mainnet.base.org forge test --mp 'test/fork/*'
cd keeper && npm install && npm test
cd monitor && npm install && npm test
```

Design history: [docs/DECISIONS.md](docs/DECISIONS.md). Earlier verification notes: [docs/LOCAL-VERIFICATION.md](docs/LOCAL-VERIFICATION.md).
