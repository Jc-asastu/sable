# Sable: handoff (2026-09-29)

> **Verification update, 2026-09-29:** The snapshot below is preserved as history.
> Its statements that local v3 was not compiled/tested and that the account tests
> still need migration are superseded by [Local verification](LOCAL-VERIFICATION.md).
> Deployment addresses, balances and live-version claims below were not reverified.
> Historical deployment commands are not authorization to run them; remaining v3
> integration work and current safety boundaries are listed in the new runbook.

## Qué es
DEX tipo fomo.family en Monad: login fácil, un saldo, trades en ~1s sin popups, cross-chain, filtro anti-scam (Sable Shield), fee 0.3%.

## Dónde está todo
- Contratos (Foundry): `C:\Users\Juan\Desktop\active\sable`
  - `src/SableAccount.sol`: cuenta por usuario. **Hay un v3 A MEDIO HACER** (ver abajo)
  - `src/SableAccountFactory.sol`, `src/TokenRegistry.sol` (Shield + fee)
  - `docs/DECISIONS.md` (D1-D15), `docs/INTENT.md`
  - Backups del v2 (el que está en producción): `docs/v2-backup/`
- Web/app: `C:\Users\Juan\Desktop\active\monad-spotdex`
  - `app.js` (app principal), `wallets.js` (EIP-6963 + opción Privy), `market.js`, `api/*.js` (Vercel functions: quote Kyber, tokens, candles, shield, agent Groq)
  - `privy/` (island React de Privy; `npm run build` → `pv/`), App ID `cmum0u1ku01rs0cjlm7gqxr1e`
  - Build: `node build.js` → `sabledex/`. Deploy: `cd sabledex && vercel deploy --prod --yes`
  - Live: https://sabledex.vercel.app/app.html (admin: /admin.html, deploy de contratos: /deploy.html)
- Tests headless: `C:\Users\Juan\AppData\Local\Temp\e2e` (playwright-core + Chrome; `fast-run.js`, `cross-test.js` con provider solo-lectura)

## En producción hoy (v2)
- Factory v2 `0x8DA4328F18EEf268Bcdb80c64771ad7f43F81Efd`, registry `0x231521ae8f94943ecdf3d16b5ad5c55012563300`, fee 30 bps a Juan.
- Cuenta v2 de Juan `0x12e053db3c550b591ac1bd12e610dc842ca58a73` (~3 USDC). Wallet Juan `0x64C5a9630C709F7454Feeb9302AC7a857F4774cF`.
- Fast trading por default (si el navegador pierde la key, el primer trade la reactiva con 1 firma).
- Login email/Google con Privy (wallets embebidas EVM + Solana).
- "Buy on other chains" vía Relay API (BNB, Base, Robinhood, Solana), una tx desde Monad, cronometra etapas.
- Multicall en lecturas (57 → 10 pedidos RPC).
- Solo USDC y WMON listados: Juan tiene que listar en /admin.html los que pasan el Shield (WBTC, cbBTC, WETH, XAUt0, CHOG, emo).

## En curso: contrato v3 (D16, aprobado por Juan)
Objetivo: la fast key no paga gas. Firma órdenes EIP-712; un relayer de Sable las envía; el gas se descuenta del monto recibido y se muestra desglosado (app fee 0.3%, gas, slippage, mínimo recibido).
- HECHO: `src/SableAccount.sol` v3 escrito (swapWithSig, withdrawWithSig, nonces, deadline, agentEpoch para rotar key, gasFee en tokenOut pagado a la TESORERÍA (registry feeTo), tope MAX_GAS_BPS=5%, swap/withdraw directos solo owner, sin refuelAgent). **No compilado ni testeado todavía.**
- FALTA:
  1. Factory: `createAccount(agent, routers, cooldown)` sin `agentGas` (todo msg.value a la cuenta), borrar `GasExceedsValue`. El patch falló por escape de bash; editar a mano.
  2. Tests: adaptar `test/SableAccount.t.sol` (agente firma con `vm.sign`, relayer envía), agregar tests: firma inválida, nonce reusado, expirado, gasFee > 5%, gas va a tesorería, withdraw solo a owner/payout, rotación de epoch. Ajustar `test/fork/KyberFork.t.sol` y `script/Deploy.s.sol` (createAccount con 3 args). `forge test`.
  3. `api/relay.js` (Vercel): recibe orden+firma, valida cuenta genuina (`owner()` → `factory.accountOf(owner) == account`), valida gasFee con ticket HMAC emitido por `/api/quote` (clave derivada de la del relayer), simula (eth_estimateGas), envía con la hot key `SABLE_RELAYER_KEY` (env de Vercel, la crea Juan, NUNCA en disco), rate limit por cuenta/IP.
  4. `api/quote.js`: devolver `gasFee` en tokenOut (de Kyber routeSummary: gas, gasPrice, gasUsd, amountOutUsd; Monad cobra gas LIMIT) + ticket.
  5. `app.js`: key derivada de firma de wallet (`keccak256(signMessage("Sable fast key #epoch, account X"))`), firmar órdenes con viem `signTypedData`, POST a /api/relay; desglose de costos en la cotización; borrar fondeo de gas de la key, refuel, top-up; migración v2→v3 (batch withdraw v2 → cuenta v3 + createAccount, como `migrateLegacy`).
  6. Regenerar `factory-artifact.json` (bytecode+ABI v3) y el setup de `deploy.html`; Juan deploya desde el navegador y lista tokens.
  7. `docs/DECISIONS.md`: agregar D16.

## Después
Yield en saldo ocioso (vault ERC-4626), órdenes límite que rinden, Shield por cadena (Solana/BSC), capa social, e2e con Synpress, auditoría, revisión legal de terms.

## Reglas de Juan
Español; ponytail (código mínimo y prolijo); nada de secretos en disco; no commit/push sin pedido; sin Co-Authored-By; el sistema bloquea crear keys y `forge script` a mainnet (deploy vía deploy.html con MetaMask).
