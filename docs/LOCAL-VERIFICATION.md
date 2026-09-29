# Verify the current local system without deploying

Evidence snapshot: **2026-09-29**, contract source baseline `a704462`, web/API
baseline `6e1de09`. Documentation changes do not alter either implementation.
This runbook separates observed local checks from configured CI and unverified
production behavior. It is not a deployment guide or security certification.

## Quick path

Use the two existing local repositories and already-installed tools. The commands
below were run in the foreground with Node **24.18.0** and Forge **1.7.1**.
These are observed tool versions, not newly introduced repository pins.

### Web/API: PowerShell

```powershell
Set-Location 'C:/Users/Juan/Desktop/active/monad-spotdex'
node --test tests/*.test.cjs
node --test tests/build.test.cjs
git diff --check
```

The complete suite passed **117/117**; the focused packaging suite passed **18/18**.
The latter is included in the full count, not an additional 18 unique tests.
Neither command skipped or failed a test. API transport and wallet behavior are
mocked; build tests create disposable fixtures, never rebuild the real `sabledex`.

### Contracts: PowerShell

```powershell
Set-Location 'C:/Users/Juan/Desktop/active/sable'
$forge = 'C:/Users/Juan/.foundry/bin/forge.exe'
& $forge test --offline --no-match-path 'test/fork/*' -vv
& $forge build --offline --skip test --skip script --sizes
& $forge fmt --check
git diff --check
```

The nonfork suite passed **63/63**, including 43 account tests, with no failures
or skips. Fuzzing uses 1,000 runs; each of four invariants uses 128 runs of depth
64, as configured in [foundry.toml](../foundry.toml). Source build/sizes and format
checks exited 0. The build reused the local compilation cache; it was not a fresh
dependency installation or clean-room build.

The build emitted existing warnings: unchecked ERC-20 transfer in
`test/mocks/MockRouter.sol`, timestamp comparisons and a narrowing spend cast in
`src/SableAccount.sol`. Successful exit does not resolve or waive those warnings.
No gas report, fork execution, hosted CI run or live transaction was performed.

On another workstation, select the equivalent local checkout/executable explicitly.
If dependencies or the compiler are absent, record the check as blocked. Do not
remove `--offline`, install tools, retrieve submodules or select an RPC silently.

## What is current, and what is historical?

| Surface | Current local evidence | Boundary |
|---|---|---|
| Account | [SableAccount.sol](../src/SableAccount.sol) uses EIP-712 domain version `3`, `swapWithSig` and `withdrawWithSig`; direct swap/withdraw methods require the owner | This does not establish a deployed v3 account |
| Signed withdrawals | Recipient must be owner or approved payout; fees go to the registry treasury | Agent withdrawal is allowed; the historical blanket prohibition is false for this source |
| Fees/admin | [TokenRegistry.sol](../src/TokenRegistry.sol) supports curator administration and capped protocol fees; [factory](../src/SableAccountFactory.sol) has owner/admin-controlled launch settings | The actual live fee recipient/rate was not queried |
| Factory integration | Existing four-argument `createAccount` still includes `agentGas` | Account signature tests do not complete the factory/frontend/relayer migration |
| Web/release | Historical handoff describes a v2 deployment while local account source is v3 | Addresses, deployed bytecode and current release configuration were not independently verified |
| YieldBook | Unit/fuzz/invariant evidence uses mocks | Real Morpho-vault and Kyber-router fork scenarios remain separate, unexecuted checks |

Read [README](../README.md) for test names. The historical
[handoff](HANDOFF.md) and [decisions](DECISIONS.md) retain their original context;
they must not be treated as fresh production evidence or new execution authority.

## Known gaps are not waived by green tests

- **Agent epochs:** `setAgent` increments `agentEpoch`, but the signed structures
  and `_useAgentSig` do not bind it. Reinstalling the same key can revive unused,
  unexpired old signatures. Immediate revocation tests do not cover that lifecycle.
- **Listing overrides:** `capOf` can return a local nonzero override without reading
  registry listing status. Default delisting tests do not prove override-safe delisting.
- **Release integration:** relayer/frontend v3 migration, real-router behavior,
  deployed-source parity and external security review remain unverified/incomplete.
- **Web evidence:** mocked wallet/transport tests are not browser accessibility,
  mobile, provider or real-fund tests. Known-token inventory is not an indexer of
  every unknown inbound asset or other device's history.
- **API capacity:** deadlines, three Shield workers and bounded local quota memory
  are not distributed quotas, trusted-proxy proof, client-disconnect cancellation,
  payload limits or measured production capacity. See the web repository's
  [API lifetime notes](../../monad-spotdex/docs/api-lifetimes.md).

## Packaging and provenance

The web repository's [build notes](../../monad-spotdex/docs/build.md) describe
deterministic packaging of existing inputs, not complete dependency reproducibility.
Privy remains a prebuilt input. Required images, the local Privy lockfile and
`factory-artifact.json` need explicit source/provenance handling. The factory
artifact carries ABI/bytecode, not proof of its source revision or deployed parity.
Do not regenerate or replace it as a side effect of verification.

Do not run the real web build or Privy prebuild for these checks. Publication can
replace generated output; existing `.vercel` and `.gitignore` metadata must survive.
Ordinary publication failures have rollback tests, but process/power failure is
not crash-atomic. Retain `.sable-build-*` recovery data for inspection rather than
deleting it blindly. No deployment metadata or credentials are needed here.

## CI configuration is not CI execution

[test.yml](../.github/workflows/test.yml) declares contract checks for pushes, pull
requests and manual dispatch. Its explicit RPC-gated step selects `MonadFork`;
Kyber additionally needs a route fixture and is not selected by that step.
The workflow installs Foundry without an explicit release pin. Solidity is pinned
to 0.8.28; [foundry.lock](../foundry.lock) records both dependency revisions, matching
the checked-in submodule gitlinks. No hosted result was inspected during this work.

Web/API checks above ran locally. No tracked frontend workflow was established by
this verification. Existing local Node/Forge versions and pinned direct Privy
dependencies do not prove a reproducible fresh checkout or dependency supply chain.

## Before any next action

- Record the exact revision, command, exit status, warnings and skipped checks.
- Re-run affected local checks after changes; this dated count is not a moving badge.
- Treat missing evidence as missing, not as a pass or an observed exploit.
- Remote execution, transfers, RPC/forks, installations, wallet use, deployment,
  push and PR operations need their own explicit authorization. Local access and
  historical commands do not provide destination or credential/session consent.
- Keep unresolved findings visible; neither tests nor documentation authorize a release.
