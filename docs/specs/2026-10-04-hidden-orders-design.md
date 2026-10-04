# D20 — Hidden limit orders (commit and reveal)

Date: 2026-10-04 · Status: implemented, waiting for the v4 factory deploy

## Problem

In v3, the whole order was public: the calldata of `placeOrder`, the `order(id)` getter, and the
`destChainId` in `OrderPlaced`. A bot could read "this account buys X when it costs Y" and push the
price to the trigger, or get in front of the fill.

Spoofing does not apply. Sable orders are trigger orders filled against Kyber or Relay. They are
not liquidity in a book that others see, so placing and cancelling them cannot move anybody's price.
The risk is front-running.

## Design

An order is split in two:

| Half | Fields | Where |
|---|---|---|
| Public (`OrderParams`) | tokenIn, vault, deadline, amountIn, commit | on-chain |
| Hidden (`Secret`) | tokenOut, destChainId, minOut, destMinOut, recipient, destToken, salt | browser + keeper |

- `commit = keccak256(abi.encode(Secret))`. The random 32-byte `salt` makes guessing the price by
  hashing candidate limits impossible.
- `fillOrder(id, s, …)` and `fillCrossOrder(id, s, …)` reveal `s` in the same transaction that fills
  the order. A wrong or malformed reveal reverts with `BadOrder`.
- Agent-signed orders: the caps on `amountIn` are checked when the order is placed. The Shield
  listing of `tokenOut` and the owner-approved `crossRecipient` are checked at the fill, because only
  then are they known. `LimitOrder.byAgent` records which rule applies.
- Cancelling and the keeper's expiry return need no secret. Funds are never stuck behind the secret.

## Off-chain flow

1. The page builds the full order. `hideOrder` adds the salt, computes the commit, and saves the
   secret in `localStorage` (`sable-order-secrets`).
2. The page places `p` (fast key or owner), finds the id in the receipt's `OrderPlaced`, and sends
   `POST /secret {chainId, account, id, secret}` to the keeper. It retries 3 times.
3. The keeper keeps the secret only if it hashes to `order(id).p.commit` on-chain, so nobody can fill
   its store with junk. Secrets live in the ledger state file on the Railway volume (`/data`).
4. The filler skips orders whose secret it lacks. Each time the page lists orders it re-sends any
   secret the keeper never confirmed.

## Limits and trade-offs

- **Still visible:** that some account has $X waiting in vault V, and the full order once it fills.
  A private mempool on Base can be added later if fills get front-run.
- **Keeper trust:** the keeper learns the limits. It already fills them, so its power over the order
  does not change.
- **Lost secret:** if the keeper loses its state and the browser lost its copy, the order cannot
  fill. The owner cancels it and gets everything back, yield included.
- **Other devices:** an order placed from another browser shows as money waiting, without its limit.
  Adding an authenticated `GET /secret` would fix this once people use several devices.

## Changes

- `src/SableAccount.sol`: the split structs, the new `PLACE_TYPEHASH`, reveal checks in `_takeOrder`,
  `OrderPlaced(…, bytes32 commit)`.
- `keeper`: `commitOf` in `chain.js`, `remember`/`secretOf` in `ledger.js`, `POST /secret` in
  `index.js`, and the reveal in `filler.js`.
- App: `hideOrder`, `postSecret` and `shareSecret` in `app.js`, plus the merge into `terminalOrders`.

Rollout: deploy the v4 factory on Monad and Base, point `CONFIG.factory`, `BASE.factory` and the
keeper's `FACTORY`/`BASE_FACTORY`/`START_BLOCK` at it, then `railway up` and deploy the app. At the
time of writing, the keeper showed 0 open orders on both chains.
