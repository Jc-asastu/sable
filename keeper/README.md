# Sable keeper

Fills limit orders when the market reaches their price, returns expired orders to their account,
relays what the agent key signs (users need no gas) and keeps points. Design: `../docs/specs/2026-10-01-limit-orders-yield-design.md`,
decisions D16–D18 in `../docs/DECISIONS.md`.

| Job | How |
|---|---|
| Find orders | Reads `AccountCreated` from the factory and `OrderPlaced/Filled/Cancelled` from accounts, 100 blocks per call (Monad's limit), every 2 s |
| Fill on Monad | Kyber route for the order; fills when the worst case still meets the order's `minOut` plus gas. The contract enforces the limit anyway |
| Fill cross-chain | Relay quote to the order's recipient; fills only if it meets `destMinOut` and Relay asks for exactly the deposit the contract makes |
| Expired orders | `cancelOrder`: funds go back to the account, never anywhere else |
| Relay | `POST /relay {account, data}`: only `placeOrderWithSig`, `cancelOrderWithSig`, `swapWithSig`, `withdrawWithSig`, only for real Sable accounts, rate-limited, simulated before sending |
| Points | `GET /points/<owner>` → `{ points, multiplier }` (D18) |
| Health | `GET /health` → cursor, open orders, watch-only flag |

Every transaction is simulated first, so a fill that would revert costs nothing.

## Run

```
npm install
FACTORY=0x… START_BLOCK=<factory deploy block> KEEPER_PRIVATE_KEY=0x… npm start
npm test
```

Without `KEEPER_PRIVATE_KEY` it runs **watch-only**: it reads the chain, computes points and logs what it would
send. Then `KEEPER_ADDRESS` must be a registered keeper so simulations pass.

| Variable | Required | Default |
|---|---|---|
| `FACTORY` | yes | — |
| `START_BLOCK` | first run | — (later runs resume from `STATE_FILE`) |
| `KEEPER_PRIVATE_KEY` | to send | watch-only without it |
| `KEEPER_ADDRESS` | watch-only | — |
| `RPC_URL` | no | `https://rpc.monad.xyz` |
| `BASE_FACTORY`, `BASE_START_BLOCK` | to serve Base | off without them |
| `ROBINHOOD_FACTORY`, `ROBINHOOD_START_BLOCK` | to serve Robinhood Chain | off without them; orders there wait in USDG |
| `ARBITRUM_FACTORY`, `ARBITRUM_START_BLOCK` | to serve Arbitrum | off without them |
| `STATE_FILE` | no | `state.json` (put it on a Railway volume) |
| `PORT` | no | `8080` |
| `ALLOWED_ORIGIN` | no | `https://sabledex.vercel.app` |

## Deploy on Railway (Juan)

1. Create a new MetaMask account only for the keeper. Fund it with ~20 MON. It pays gas and is reimbursed
   from fills; keep it small, it is a hot key.
2. Railway → New project → Deploy from this repo, root `keeper/`, start command `npm start`.
3. Variables: `FACTORY`, `START_BLOCK`, `KEEPER_PRIVATE_KEY` (paste it only here, never in a file or chat),
   `STATE_FILE=/data/state.json`. Add a volume mounted at `/data`.
4. From the admin wallet: `registry.setKeeper(<keeper address>, true)`, `registry.setRelayDepository(0x4cd00e387622c35bddb9b4c962c136462338bc31)`,
   `registry.setVault(...)` for each vault users may choose.
5. Check `https://<railway-url>/health`.

## Limits

- One key, one nonce sequence: orders are filled one at a time. Add keys if fills queue up.
- Rate limits and the state file are per instance; run one instance.
- Cross-chain fills trust this keeper to quote the order's recipient (D17); the code refuses any Relay
  deposit that differs from what the contract pays, but the contract itself can't see the other chain.
