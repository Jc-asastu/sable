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
FACTORY=0x… START_BLOCK=<factory deploy block> FILLER_PRIVATE_KEY=0x… RELAYER_PRIVATE_KEY=0x… npm start
npm test
```

Without a filler key it runs **watch-only**: it reads the chain, computes points and logs what it would
send. Then `KEEPER_ADDRESS` must be a registered keeper so simulations pass.

| Variable | Required | Default |
|---|---|---|
| `FACTORY` | yes | — |
| `START_BLOCK` | first run | — (later runs resume from `STATE_FILE`) |
| `FILLER_PRIVATE_KEY`, `RELAYER_PRIVATE_KEY` | to send | the old shared `KEEPER_PRIVATE_KEY`; watch-only without any (see Keys) |
| `KEEPER_ADDRESS` | watch-only | — |
| `RPC_URL` | no | `https://rpc.monad.xyz` |
| `STATE_FILE` | no | `state.json` (put it on a Railway volume) |
| `PORT` | no | `8080` |
| `ALLOWED_ORIGIN` | no | `https://sabledex.vercel.app` |

## Keys: one per role (audit H-4)

| Role | Does | Holds | On-chain |
|---|---|---|---|
| **filler** | fills and returns orders | gas only | `registry.setKeeper(filler, true)` |
| **relayer** | pays gas for agent-signed calls and sponsored openings | gas only | nothing |

A leaked relayer key can't fill; a leaked filler key can't relay. Two roles on the old shared key share one
nonce sequence, so it keeps working until the keys are split.

**Turnkey** (preferred): the keys live in Turnkey and never reach Railway; only an API key does, and Turnkey's
policies limit what it may sign. Set `TURNKEY_ORGANIZATION_ID`, `TURNKEY_API_PUBLIC_KEY`,
`TURNKEY_API_PRIVATE_KEY`, `TURNKEY_FILLER_ADDRESS`, `TURNKEY_RELAYER_ADDRESS`; local keys are then ignored.

1. Create two Ethereum wallet accounts (filler, relayer) in the org.
2. Create a **non-root** API user for the keeper: root users bypass every policy.
3. Add one policy per role, consensus `approvers.any(user, user.id == '<keeper API user id>')`:
   - filler: `wallet_account.address == '<filler>' && eth.tx.value == 0 && eth.tx.data[0..10] in ['0x73495421', '0xd7f3ccb5', '0x514fcac7']`
     (`fillOrder`, `fillCrossOrder`, `cancelOrder`)
   - relayer: `wallet_account.address == '<relayer>' && eth.tx.value == 0 && eth.tx.data[0..10] in ['0x93a6bb3c', '0x70668201', '0x5ea857d9', '0x4336ab29', '0x914ffa5f']`
     (`placeOrderWithSig`, `cancelOrderWithSig`, `swapWithSig`, `withdrawWithSig`, `createAccountFor`)

   Then a stolen API key can only spend gas on calls the contracts already check; it can't send the gas away.
4. Point the monitor at both: `WATCH_BALANCES=filler:<filler>,relayer:<relayer>`.

## Deploy on Railway (Juan)

1. Create a new MetaMask account only for the keeper. Fund it with ~20 MON. It pays gas and is reimbursed
   from fills; keep it small, it is a hot key.
2. Railway → New project → Deploy from this repo, root `keeper/`, start command `npm start`.
3. Variables: `FACTORY`, `START_BLOCK`, the keys (see Keys; paste them only here, never in a file or chat),
   `STATE_FILE=/data/state.json`. Add a volume mounted at `/data`.
4. From the admin wallet: `registry.setKeeper(<keeper address>, true)`, `registry.setRelayDepository(0x4cd00e387622c35bddb9b4c962c136462338bc31)`,
   `registry.setVault(...)` for each vault users may choose.
5. Check `https://<railway-url>/health`.

## Limits

- One filler key, one nonce sequence: orders are filled one at a time. Add keys if fills queue up.
- Rate limits and the state file are per instance; run one instance.
- Cross-chain fills trust this keeper to quote the order's recipient (D17); the code refuses any Relay
  deposit that differs from what the contract pays, but the contract itself can't see the other chain.
