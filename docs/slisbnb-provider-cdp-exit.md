# SlisBNBProvider: moving Aster, Pendle and Sigma out of the CDP

> **Status: draft, not audited.**
>
> **Live state:** read at BSC block 133,969,283 (Nov 2026). Re-read before each step.

## Why

The CDP has been wound down. The slisBNB ilk has no debt, but about 81,880 slisBNB still sit in the GemJoin, almost all of it from three integrations. That slisBNB is exposed to the wards, upgrade rights and liquidation paths of the Vat, GemJoin and Interaction. The three reach the CDP through the CDP `SlisBNBProvider` proxy `0xfD31e1C5e5571f8E7FE318f80888C1e6da97819b`:

| Integrator | Contract that holds the position | How the provider address is set | slisBNB in the CDP |
|---|---|---|---|
| Aster | YieldProxy `0xE861dd4b0AB6f3a42943e6EF441c3C611CD1bec2` | `setSlisBNBProvider` (Aster MANAGER) | 78,346.27 |
| Pendle | PendleClisBNBSY `0x27FaF900007B4cBa7803000251ec96Bc69ff1BEa` | `constant` | 3,437.43 |
| Sigma | SigmaClisBNBSY `0x8B98563d66B74e5a644BFf78fC72c86bbA847a29` | `immutable` | 96.01 |

Pendle and Sigma cannot point to a new address without redeploying, so the provider is upgraded in place. After the upgrade the provider holds these three accounts' slisBNB itself. The provider address and every method signature stay the same, so the integrators change nothing.

Today every `release` calls `Interaction._withdraw`, which calls `poke()`. That means the CDP Vat, Interaction and the slisBNB oracle all have to stay alive for as long as these positions exist. After the upgrade the three accounts no longer touch the CDP.

clisBNB (slisBNBx, `0x4b30fcAA7945fE9fDEFD2895aae539ba102Ed6F6`) is not touched: same amounts, same rates, same delegation. Moving its minting to `SlisBNBxMinter` is left to a later phase.

This follows the phase-1 design in Notion ("CDP slisBNB 退出设计（一期）"), narrowed to the three accounts: they are migrated once at upgrade, and the CDP dust is left where it is.

## Contract

`src/cdp/ceros/provider/SlisBNBProvider.sol` is edited in place. The version on master is the live implementation `0x9498e35f36058f80cf15d12cadfd4d6af8c6e890` byte for byte, so the diff of this file is exactly the change against mainnet. Each change is marked `v2` in the source. `BaseTokenProvider.sol` is not changed.

Files under `src/cdp/` compile against OpenZeppelin 4.8.3 (`lib/openzeppelin-contracts-v4`, `lib/openzeppelin-contracts-upgradeable-v4`) through context remappings in `remappings.txt`. V1 uses the 4.x storage layout; the rest of the repo keeps OpenZeppelin 5.x.

**Storage.** The 23 V1 variables keep their slot, offset and type. Two variables are appended after `totalReservedLp`:

1. `_userDeposit` (slot 405): slisBNB held for each served account, read through `userDeposit(address)`.
2. `totalDeposit` (slot 406): the sum. Invariant: `slisBNB.balanceOf(provider) >= totalDeposit`.

**Served accounts.** Exactly three, hardcoded as `constant`: `ASTER`, `PENDLE` and `SIGMA`. They are in the bytecode, not in storage. Changing the set needs a new implementation through the TimeLock.

**Selectors.** All 42 V1 selectors are kept. Six are added: `ASTER`, `PENDLE`, `SIGMA`, `migrateFromCdp`, `userDeposit`, `totalDeposit`.

| Function | V1 | Now |
|---|---|---|
| `_provideCollateral` | `dao.deposit` | Requires a served account; records `_userDeposit` / `totalDeposit`; the slisBNB stays in the provider. clisBNB minting is unchanged. |
| `_withdrawLp` (used by `release`) | `dao.withdraw` | Deducts `_userDeposit` / `totalDeposit`; reverts `insufficient deposit` if short. clisBNB burning is unchanged. |
| `_syncLp`, `isUserLpSynced` | Reconcile against `dao.locked` | Reconcile against `userDeposit(account)` |
| `userDeposit(address)` | none | `_userDeposit` for a served account, `dao.locked` for anyone else |
| `withdrawLeftover` | Pays the amount `dao.withdraw` returns | Pays the provider's actual balance increase |
| `liquidation` (both overloads), `daoBurn`, `releaseFor` | Callable by PROXY / the CDP migrator | Revert |
| `migrateFromCdp()` | none | One-time cut-over, see below |

`provide`, `release`, `delegateAllTo` and `syncUserLp` are inherited unchanged and go through the functions above.

**`migrateFromCdp()`.** Guarded by `reinitializer(2)`, `DEFAULT_ADMIN` and `nonReentrant`; it takes no arguments. For each served account it reads `amount = dao.locked(slisBNB, account)` and calls `dao.withdraw(account, slisBNB, amount)`. The provider is the registered helio provider, so the slisBNB is paid to the provider. It then checks that the balance increase equals `amount`, records `_userDeposit` and emits `Migrated(account, amount)`. An account with nothing locked is skipped, so an integrator that fully exits during the TimeLock delay does not block execution. Finally it sets the provider's slisBNB allowance to Interaction to 0. V1 approved `type(uint256).max` at initialize, which would otherwise let Interaction pull the slisBNB now held here.

### Why these choices

- **`liquidation`, `daoBurn` and `releaseFor` must revert.** `liquidation` is an unconditional transfer for `PROXY` (`BaseTokenProvider.sol:245`), and `releaseFor` lets the CDP migrator withdraw for any account. Once the provider holds the slisBNB, either could move all of it. Today `PROXY` is held by the CDP Core Admin Safe `0xAca0ed4651ddA1F43f00363643CFa5EBF8774b37` and Interaction `0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4`. The ilk has no debt and no auctions, so nothing legitimate needs these paths.
- **Zero trust in the CDP.** After the cut-over the provider never calls `dao.deposit`, and calls `dao.withdraw` only from `migrateFromCdp` and `withdrawLeftover`. Both count the provider's actual balance increase, not Interaction's return value. Both are `nonReentrant`, so a re-entrant call from Interaction cannot count the same transfer twice.
- **`withdrawLeftover` stays.** It is how accounts with a CDP `free` (`Vat.gem`) balance from old liquidations get it back.

## Effect on users

- **Aster, Pendle, Sigma:** `Interaction.locked` and `Vat.urns` read 0 for them after the cut-over, including in emission snapshots. Their clisBNB balances, delegation and rates do not change. Sigma can deposit again; today the CDP whitelist keeps it redeem-only.
- **CDP dust** (every other account with slisBNB in the CDP) is out of scope and keeps its CDP position:
  - `userDeposit`, `isUserLpSynced` and `syncUserLp` still read `dao.locked`, as in V1.
  - `release` reverts with `insufficient deposit`, and `provide` reverts with `not a served account`.
  - `withdrawLeftover` still pays out a `free` balance.
  - The Core Admin Safe can return their `ink` with `Vat.grab` + `GemJoin.exit` straight to the user. This must happen before any `removeCollateralType(slisBNB)`.

## Migration process

Roles were checked on chain: TimeLock `0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253` holds `DEFAULT_ADMIN` on the provider.

### 0. Pre-checks (read on chain right before scheduling, and again before executing)

- For each of the three accounts:
  - `Interaction.locked(slisBNB, account) > 0`
  - CDP debt `art == 0`
  - `Vat.gem(ilk, account) == 0`. `Interaction.withdraw` spends `gem` before `ink`, so an account holding both would leave `ink` behind.
- `Interaction.collaterals(slisBNB).live == 1`. The slisBNB ilk must not have been removed, because `Interaction.withdraw` needs it.
- The slisBNB oracle must be fresh at execution time, because `migrateFromCdp` goes through `poke()` once.
- The provider proxy implementation must still be `0x9498e35f36058f80cf15d12cadfd4d6af8c6e890`.
- No `DEFAULT_ADMIN` holder on the provider other than the TimeLock (scan `RoleGranted` / `RoleRevoked`).

### 1. Deploy the implementation

```
forge script script/cdp/DeploySlisBNBProvider.s.sol:DeploySlisBNBProvider \
  --rpc-url <bsc> --etherscan-api-key <key> --broadcast --verify -vvv
```

`TIMELOCK_SALT` must be set to the next unused Changelog salt. The script prints the `schedule` and `execute` calldata.

Compare the storage layout before proposing:

```
# on master (live V1 source) and on this branch
forge inspect src/cdp/ceros/provider/SlisBNBProvider.sol:SlisBNBProvider storageLayout
```

### 2. Schedule the upgrade (Proposer Safe → TimeLock)

```
TimeLock.schedule(
  provider, 0,
  upgradeToAndCall(impl, migrateFromCdp()),
  0x0, salt, 86400
)
```

The upgrade and the migration run in one transaction, so the provider is never live on the new code with these three accounts' slisBNB still in the CDP. The calldata carries no account list.

### 3. Execute (Proposer Safe → TimeLock, after 24 h)

The amounts are read at execution time from `Interaction.locked`, so deposits and withdrawals by the integrators in the 24 h window are fine. If an account is down to zero by then, it is skipped and the rest are migrated.

### 4. Post-checks

- The provider implementation is the new impl, and `migrateFromCdp` cannot be called again.
- For each account:
  - CDP `ink == 0` and `Interaction.locked == 0`
  - `userDeposit(account) == locked before`
  - `userLp`, `userReservedLp`, `delegation` and `isUserLpSynced` are the same as before
- clisBNB balances of the three accounts, their delegatees and `lpReserveAddress`, and the clisBNB total supply, are unchanged to the wei.
- `slisBNB.balanceOf(provider) >= totalDeposit`, and the GemJoin balance fell by the amount migrated.
- `slisBNB.allowance(provider, Interaction) == 0`.
- Smoke-test each integrator through its own entry point:
  - Aster: `AsBnbMinter.mintAsBnb` / `burnAsBnb`
  - Pendle and Sigma: SY `deposit` / `redeem`

### 5. After the cut-over

- **Optional hygiene.** Revoke `PROXY` on the provider from the Core Admin Safe and from Interaction. Both paths already revert.

## Backend changes

From the Notion design, the items that apply to the three-account scope:

| Item | Where | Change | When |
|---|---|---|---|
| CDP TVL | lista-cron `analytics.service.ts`, `tvlMonitor.service.ts` | slisBNB amount = `slisBNB.balanceOf(provider) + slisBNB.balanceOf(GemJoin)` | before the upgrade |
| CDP TVL (DefiLlama) | lista-api `defiLlama.controller.ts` | Add a (slisBNB, provider) row. DefiLlama's `helio-money` adapter sums by (token, owner), so without it the TVL drops by the migrated amount. | before the upgrade |
| clisBNB re-sync bot | lista-bot `miscBot.service.ts` (`syncLpSlisBNBProvider`) | It discovers users through Interaction `Deposit` events, which the three accounts no longer produce. After any `exchangeRate` / `userLpRate` change, also check `isUserLpSynced` for the three accounts and call `syncUserLp` where needed. | after the upgrade |

The clisBNB launchpool snapshot only reads provider events and delegation, so it needs a regression check, not a change.

## Before launch

- Confirm with Aster, Pendle and Sigma that their off-chain systems (back office, reconciliation, dashboards) do not read `Interaction.locked` or `Vat.urns` for these accounts. The Notion design checked their implementation bytecode: none of them calls the CDP directly.

## Open decisions

- **Sigma deposits.** The new code lets Sigma deposit again. Business to confirm.
- **Compiler.** V1 was built with 0.8.10 / london. This repo builds with 0.8.24 (cancun is the default for that compiler, and BSC supports it). The storage layout does not depend on the compiler.
- **Licence.** `src/cdp/ceros/provider/SlisBNBProvider.sol` is derived from GPL-3.0-only V1 and keeps that header. The rest of this repo is MIT.
- **Audit** before scheduling.

## Tests

`test/cdp/SlisBNBProviderMigration.t.sol` forks BSC at the latest block (`BSC_RPC`). It runs steps 2–3 with `vm.prank`, without the TimeLock schedule, and checks:

- The three accounts' slisBNB moves out of the CDP into the provider. clisBNB balances, `userLp`, `userReservedLp`, delegation, sync status and total supply are unchanged to the wei. The allowance to Interaction is revoked.
- With every Interaction call mocked to revert: Aster asBNB mint/burn, Pendle and Sigma SY deposit/redeem and `delegateAllTo` all work.
- Any other account cannot `provide`. `release` above `userDeposit` reverts.
- `liquidation` (both overloads) and `daoBurn` from the PROXY holders, and `releaseFor`, revert.
- A CDP dust account still reads `dao.locked`, keeps its sync status and cannot `release`.
- `withdrawLeftover` pays only what actually arrived when Interaction over-reports.
- Pendle and Sigma still work after 7 days with no oracle update.
- A served account with nothing in the CDP is skipped. A short delivery by Interaction reverts the whole upgrade.
- `migrateFromCdp` cannot run twice.
- `slisBNB.balanceOf(provider) >= totalDeposit` at the end of every flow.

```
BSC_RPC=<rpc> forge test --mc ProviderV2Migration -vv
```
