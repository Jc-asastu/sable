# Sable

**Limit orders that earn while they wait.**

Most of the money on-chain is parked. It sits in lending markets earning 4 to 6% a year, because
there's nothing better to do with it. Limit orders do the opposite: they lock your money and pay
you nothing until the price shows up, which can take days or weeks.

Sable puts the two together. You pick the price you want to buy at. Until the market gets there,
your USDC sits in a lending vault (Aave, Euler, Morpho, Fluid) and earns. When the price hits, the
order fills at your price or better and the interest stays with you. Cancel any time and you get
everything back, interest included.

- App: [sabledex.vercel.app](https://sabledex.vercel.app)
- Why we built it and where we think this goes: [docs/VISION.md](docs/VISION.md)
- How it works under the hood: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## What already works

None of this is a mockup. It runs on mainnet today, with real money, in small amounts.

- **Limit orders that earn**, on Monad and Base. You see what your waiting orders make per day.
- **Hidden orders.** The chain only sees how much is waiting and a fingerprint of the rest. The
  price, the token and where it goes are revealed at the moment of the fill, so nobody can trade
  against your order or fake orders to push the price around.
- **Trading without pop-ups.** Sign in with email, Google or your wallet. A trading key in your
  browser signs for you, inside limits the contract enforces. No gas coin needed.
- **Speed.** A market buy lands in about 2 seconds. A hidden limit order goes from placed to filled
  in 6 to 10 seconds once the price is there.
- **Sable Score.** Every token and every vault gets a grade from A to F with the reasons in plain
  words: taxes, owner powers, holders, liquidity, how much is deposited, whether the code can change.
  Only a token you can't sell back is blocked. The rest is your call.
- **Only vaults that pay back on the spot.** We tested each one on a copy of mainnet: 1,000 USDC in
  and out in the same transaction. An order never waits on a withdrawal queue.

### Live on mainnet (v4)

| | Monad | Base |
|---|---|---|
| Accounts (factory) | [`0xe377…83B9`](https://monadscan.com/address/0xe3771074342fa61E0391276EFf639214930983B9) | [`0x4bA7…99Da`](https://basescan.org/address/0x4bA7C6731Cba147F1b7ab950c1d54d9C9CDB99Da) |
| Shield (registry) | [`0xAAec…3678`](https://monadscan.com/address/0xAAecB6180B27839da137Da04894Df3C544083678) | [`0x732a…2664`](https://basescan.org/address/0x732a60b051E64dD362512a200aD2586FCF1a2664) |

Monad and Base are the first two. We're expanding to as many networks as we can: the accounts, the
vaults and the keeper work on any chain with lending vaults and a DEX aggregator. Which network
becomes the home where orders settle is still being decided.

The code running there today is the `feat/v3-limit-orders` branch. This branch is v5: the same
product plus everything the audit asked for. It isn't deployed yet.

## Built fast, checked hard

| Date | |
|---|---|
| Oct 1, 2026 | Limit orders that earn go live on Monad |
| Oct 2–3 | Base joins. Accounts open without the user paying gas. One keeper serves both chains |
| Oct 4 | Hidden orders: commit on-chain, reveal at the fill |
| Oct 5 | We stop and audit ourselves. Full threat model: 2 critical and 4 high findings, caught before anyone lost a cent |
| Oct 6 | v5: the critical findings fixed, the keeper tested as an attacker, the handover to a Safe tested end to end |

It moved this fast because it didn't start from zero. I had the pieces scattered across earlier
projects: an agent wallet whose spending limits live on-chain (Secret Agent Wallet), keepers and a
full self-audit of a perp exchange on Solana (SUR), and a lot of time spent on how trading should
feel. Sable is where all of that comes together in one product.

The rule we work by: the keeper that fills orders decides **when**, never **where** the money goes.
The contract checks the price, the recipient and every amount. A misbehaving keeper can delay an
order. It can't take it or fill it at a worse price.

## Security, honestly

- Internal audit done and published: [docs/security](docs/security/2026-10-05-threat-model-and-audit.md).
  Every finding and its status is there.
- 129 contract tests. In the hardest ones the keeper itself tries to cheat, 50,000 random calls per
  run, and the money always ends up where it should.
- v5 hands admin control to a 2-of-3 Safe behind a 24-hour delay. A guardian can pause in an
  instant but can never move funds or raise a limit.
- No external audit yet. Until there is one, Sable runs as a battle-test with small amounts.

## What's next

- **v5 on mainnet**, with the admin on a Safe.
- **More networks, and orders that cross them**: buy on one chain, receive on another, through Across.
- **Tokenized stocks.** xStocks went live natively on Monad on October 6 (NVDAx, TSLAx, SPYx and
  more). "Buy NVIDIA if it drops to 220 and earn 6% while you wait" already works with these
  contracts. We're waiting on liquidity.
- **cSABLE**: part of every fee goes to the orders that are still waiting. The longer you wait,
  the more you earn.
- **An external audit** before we invite real size.

## In this repo

| | |
|---|---|
| `src/` | The contracts: accounts, the Shield registry, the admin timelock |
| `keeper/` | Fills orders, relays trades so users need no gas, keeps points |
| `monitor/` | Watches every fill on its own key and can pause things in an instant |
| `test/` | Unit, fuzz, invariant and mainnet-fork tests |
| `docs/` | [Vision](docs/VISION.md), [architecture](docs/ARCHITECTURE.md), [decisions](docs/DECISIONS.md), [specs](docs/specs), [security](docs/security) |

Licensed under [BUSL-1.1](LICENSE): read it, audit it, learn from it. Commercial use needs
permission until October 6, 2028, when it becomes GPL.

Built by Juan Cruz Maisú.
