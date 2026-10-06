# Why Sable

## The thing that bugged us

A limit order is the most honest way to trade. You decide your price and you wait for it.

But on every exchange we used, waiting cost money. The USDC behind an order just sat there for days,
sometimes weeks, earning nothing. The same USDC in Aave would have been making 4 to 6% a year.

So you end up choosing: park your money where it earns, or put it in orders where it doesn't. Most
people park. That's why there is so much money on-chain and so little of it is actually trading.

We didn't think anyone should have to choose.

## What the numbers say

Monad today (DefiLlama, October 6, 2026):

| | |
|---|---|
| Total value on the chain | about $1.03 billion |
| Sitting in lending markets | about $900 million |
| Liquidity on DEXs | about $57 million |
| Stablecoins | about $720 million |

The money is there. It's parked. For every dollar ready to trade, about fifteen are sitting in
lending waiting for something better to do.

The Monad team saw the same thing. In June 2025 they wrote
["Ideas for Next Generation CLOB DEXes"](https://monad.xyz/blog/next-gen-clob), and one of the ideas
was exactly this:

> traders can opt-in to have the capital backing their resting limit orders automatically deposited
> into its own lending markets, or even external lending markets or vaults.

We couldn't find anyone shipping it on Monad. So we built it, and it's live.

## What we believe

**Waiting should pay.** If your money is waiting for a price, it should be earning while it waits.
That's the whole product in one line.

**Your price is your business.** On a public order book everyone sees where you want to buy, and some
of them will use it against you. Sable orders are hidden until they fill. The chain holds a
fingerprint, not your price.

**Fast shouldn't mean giving up your keys.** Apps that feel instant usually hold your money. Sable
gives each user their own on-chain account. A trading key in the browser makes it fast, and the
contract limits what that key can do. Only you can withdraw.

**Tell people the truth about risk.** We don't decide what you can buy. We grade every token and
every vault, say why in plain words, and let you choose. We only block what is plainly a trap.

**If the contract can enforce it, it should.** The keeper that fills orders picks the moment. The
contract checks the price, the destination and every amount. Trust goes where it has to, and
nowhere else.

## Where the opportunity is

**For traders, a better default.** Any limit order on Sable beats doing nothing with that money. There
is no reason to park and wait somewhere else.

**For the chain, parked money starts working.** Every order is a deposit in a lending market and a
buyer at a price level. Lending protocols get deposits, the market gets real resting demand, the
chain gets volume. Nobody has to give anything up for that.

**Any chain with vaults.** Nothing in Sable is tied to one network. The account, the vaults and the
keeper work wherever there are ERC-4626 vaults and a DEX aggregator. We started on Monad and Base and
are adding as many networks as we can. Which one becomes home for settlement is still open.

**Stocks.** On October 6, 2026, xStocks launched natively on Monad: NVIDIA, Tesla, the S&P 500 and
more than a thousand others as tokens. Limit orders on stocks that earn while they wait don't exist
anywhere on Monad yet. Our contracts already support them.

**A business that pays its users.** Sable takes 0.3% on trades. With cSABLE, part of every fee goes
back to the orders that are still waiting, so the people providing patience share in the revenue.

## What we won't do

- Hold your money. It lives in your account, not ours.
- Hide costs. Fees, gas and slippage are on screen before you sign.
- Pretend we're done with security. We audited ourselves, published everything we found, fixed the
  critical issues in v5, and an external audit comes before real size.

## Where it goes

1. v5 on mainnet, with the admin on a Safe and a 24-hour delay on every change.
2. More networks, and orders that buy on one chain and deliver on another.
3. Tokenized stocks with limit orders that earn.
4. cSABLE, sharing fees with the orders that wait.
5. An agent that trades for you inside rules you set, with the same limits the contract enforces today.

Sable started as a question: why does waiting for a good price cost money? We think the answer
should be that it doesn't.
