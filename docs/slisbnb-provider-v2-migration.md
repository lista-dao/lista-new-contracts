# SlisBNBProvider V2: moving Aster, Pendle and Sigma out of the CDP

> **Status: draft, not audited.**
>
> **Live state:** read at BSC block ~133.85M (Nov 2026). Re-read before each step.

## Why

The CDP has been wound down. Every slisBNB position except three has been returned.

The three that remain are integrations. They reach the CDP through the CDP `SlisBNBProvider` proxy `0xfD31e1C5e5571f8E7FE318f80888C1e6da97819b`:

| Integrator | Contract that holds the position | How the provider address is set | slisBNB in the CDP |
|---|---|---|---|
| Aster | YieldProxy `0xE861dd4b0AB6f3a42943e6EF441c3C611CD1bec2` | `setSlisBNBProvider` (Aster MANAGER) | 79,046.36 |
| Pendle | PendleClisBNBSY `0x27FaF900007B4cBa7803000251ec96Bc69ff1BEa` | `constant` | 3,449.24 |
| Sigma | SigmaClisBNBSY `0x8B98563d66B74e5a644BFf78fC72c86bbA847a29` | `immutable` | 96.01 |

Pendle and Sigma cannot point to a new address without redeploying. So the provider is upgraded in place.

After the upgrade:

- The provider holds the slisBNB itself and no longer uses the CDP `Interaction`.
- clisBNB (slisBNBx, `0x4b30fcAA7945fE9fDEFD2895aae539ba102Ed6F6`) is minted through `SlisBNBxMinter` `0x2959c423bfe5Cc6E41516599D982A29C0773F11a`, the same way as Moolah's slisBNB module.

Today every `release` calls `Interaction._withdraw`, which calls `poke()`. That means the CDP Vat, Interaction and the slisBNB oracle all have to stay alive for as long as these positions exist. V2 removes that dependency.

## Contract

`src/cdp/SlisBNBProviderV2.sol` inherits `SlisBNBProvider` from three pinned submodules:

| Submodule | Pinned at | Why |
|---|---|---|
| `lib/lista-dao-contracts` | `3e120da` (master; the repo is archived) | Its `SlisBNBProvider.sol` and `BaseTokenProvider.sol` are byte-identical to the verified source of the live implementation `0x9498e35f36058f80cf15d12cadfd4d6af8c6e890`. |
| `lib/openzeppelin-contracts-upgradeable-v4` | `v4.8.3` | V1 uses the OpenZeppelin 4.x storage layout. This repo's OpenZeppelin v5 uses a different layout and cannot be used. |
| `lib/openzeppelin-contracts-v4` | `v4.8.3` | Provides the non-upgradeable OpenZeppelin imports that V1 and V2 use. |

Context remappings in `remappings.txt` point `lib/lista-dao-contracts/` and `src/cdp/` at the 4.8.3 copies. The rest of the repo keeps OpenZeppelin v5.

**Storage.** The 23 V1 variables keep their slot, offset and type. V2 appends three variables, in this order:

1. `userBalance`
2. `totalBalance`
3. `depositWhitelist`

**Interface.** It is unchanged for integrators:

- `provide(uint256)` and `provide(uint256,address)`: pull slisBNB into the provider, credit `userBalance` and re-sync slisBNBx.
- The delegatee can only change while the account's balance here is zero, as in V1.
- `release(address,uint256)`: pays exactly `amount`. Aster's YieldProxy reverts on any shortfall.
- `delegateAllTo(address)`: moves the delegatee in `SlisBNBxMinter`.

**New functions.**

- `migrateFromCdp(accounts, whitelist)`, guarded by `reinitializer(2)` and `DEFAULT_ADMIN`. For each account it:
  1. Calls `Interaction.withdraw(account, slisBNB, locked)`. The provider is the registered helio provider, so the slisBNB is paid to the provider.
  2. Credits `userBalance`.
  3. Burns the legacy clisBNB: the user part, the delegatee part and the `lpReserveAddress` part.
  4. Writes the legacy delegatee into the minter.
  5. Calls `SlisBNBxMinter.rebalance`.

  It skips an account with nothing locked, so an integrator that fully exits during the TimeLock delay does not block execution. It reverts if the slisBNB received differs from `locked`.
- `getUserBalanceInBnb(account)`: the module callback for the minter. It returns `ListaStakeManager.convertSnBnbToBnb(userBalance)`.
- `setDepositWhitelist(accounts, allowed)`, restricted to `MANAGER`. It replaces the CDP Interaction whitelist.
- `syncSlisBNBx(account)`: a permissionless re-sync. It reverts for an account with no balance here, so it cannot burn the legacy clisBNB of a CDP dust account.

**Disabled.** These now revert:

- `liquidation` (both overloads)
- `daoBurn`
- the migrator path `releaseFor`, which goes through `_withdrawLp`

Without this, PROXY holders could move the slisBNB the provider now holds. Today those are the CDP Core Admin Safe `0xAca0ed4651ddA1F43f00363643CFa5EBF8774b37` and `Interaction` `0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4`.

**Unchanged.** `withdrawLeftover` still lets an account pull its own CDP `free` balance.

## Effect on clisBNB balances

V1 minted `locked × exchangeRate (1.021) × userLpRate (0.97)` to the user or delegatee, and the rest to `lpReserveAddress`.

V2 mints from the minter instead: the BNB value at the live StakeManager rate (1.0396), with a 3% fee to the MPC wallets.

Integrators' clisBNB rises by about 1.8%:

| | Legacy user part | New user part | Delegatee |
|---|---|---|---|
| Aster | 78,285.14 | 79,710.49 | `0xD57E5321e67607Fab38347D96394e0E58509C506` |
| Pendle | 3,416.02 | 3,478.22 | `0xb1E6d401a202335403A6d19b9C2aC185605DC64B` |
| Sigma | 95.08 | 96.81 | `0xa6a7a63f9ee0ac6e7f6bf8756c83e707ae4e43cc` |

The fee to the MPC wallets is 2,575.84. MPC0 is `0xd57e…c506`, with cap 600,000 and 20,798 used.

clisBNB total supply goes from 780,156.86 to 781,692.20.

`0xd57e…c506` is the V1 `lpReserveAddress`, Aster's delegatee and MPC0 at the same time. The test checks its balance end to end.

## Migration process

Roles were checked on chain:

- TimeLock `0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253` is `DEFAULT_ADMIN` on both the provider and the minter.
- The Manager Safe `0x8d388136d578dCD791D081c6042284CED6d9B0c6` is `MANAGER` on both.

### 0. Pre-checks (read on chain right before scheduling, and again before executing)

- For each of the three accounts:
  - `Interaction.locked(slisBNB, account) > 0`
  - CDP debt `art == 0`
  - `Vat.gem(ilk, account) == 0`. `free` balances are not migrated.
- `Interaction.collaterals(slisBNB).live == 1`. The slisBNB ilk must not have been removed, because `Interaction.withdraw` needs it.
- The slisBNB oracle must be fresh at execution time, because `migrateFromCdp` goes through `poke()` once.
- The minter must have MPC capacity for about 3% of the BNB value moved: `sum(cap - balance)` over `mpcWallets`. Otherwise it reverts with `EXCEED_MPC_CAP`.
- The provider proxy implementation must still be `0x9498e35f36058f80cf15d12cadfd4d6af8c6e890`.

### 1. Deploy the implementation

```
forge script script/cdp/DeploySlisBNBProviderV2.s.sol:DeploySlisBNBProviderV2 \
  --rpc-url <bsc> --etherscan-api-key <key> --broadcast --verify -vvv
```

`TIMELOCK_SALT` must be set to the next unused Changelog salt.

The script prints the calldata for steps 2–4.

Compare the storage layout before proposing:

```
forge inspect lib/lista-dao-contracts/contracts/ceros/provider/SlisBNBProvider.sol:SlisBNBProvider storageLayout
forge inspect src/cdp/SlisBNBProviderV2.sol:SlisBNBProviderV2 storageLayout
```

### 2. Register the provider as a minter module (Manager Safe)

Call `SlisBNBxMinter.addModule(provider, {discount: 0, feeRate: 30000, moduleAddress: provider})`. These are the same values as the Moolah slisBNB module `0x33f7a980a246f9b8fea2254e3065576e127d4d5f`.

This must be executed before step 4. It has no effect while V1 is live, because V1 never calls the minter.

### 3. Schedule the upgrade (Proposer Safe → TimeLock)

Schedule:

```
TimeLock.schedule(
  provider, 0,
  upgradeToAndCall(impl, migrateFromCdp([Aster, Pendle, Sigma], [Aster, Pendle])),
  0x0, salt, 86400
)
```

The upgrade and the migration run in one transaction, so the provider is never live on V2 with the slisBNB still in the CDP.

The whitelist argument carries over today's CDP whitelist. Sigma is not whitelisted today; see the open decisions below.

### 4. Execute (Proposer Safe → TimeLock, after 24 h)

The amounts are read at execution time from `Interaction.locked`. Deposits and withdrawals by the integrators in the 24 h window are therefore fine.

If any account is down to zero by then, it is skipped and the rest are migrated.

### 5. Post-checks

- The provider implementation is the new impl, and `migrateFromCdp` cannot be called again.
- For each account:
  - CDP `ink == 0`
  - `userBalance == locked before`
  - V1 `userLp`, `userReservedLp` and `delegation` are zero
  - `SlisBNBxMinter.delegation(account)` equals the legacy delegatee
  - `userModuleBalance(account, provider)` equals the BNB value, split 97 / 3
- `slisBNB.balanceOf(provider) == totalBalance`, and the GemJoin balance fell by the same amount.
- Smoke-test each integrator through its own entry point:
  - Aster: `AsBnbMinter.mintAsBnb` / `burnAsBnb`
  - Pendle and Sigma: SY `deposit` / `redeem`

### 6. After the cut-over

- **Tell Aster, Pendle and Sigma** that their clisBNB balances change by about +1.8% at execution.
- **Optional hygiene.** Revoke `PROXY` on the provider from the Core Admin Safe and from Interaction. Both paths already revert in V2.
- **CDP dust.** 371 slisBNB positions, 0.244 slisBNB in total, stay in the CDP and are out of scope:
  - They cannot use `release` on V2.
  - They can still use `withdrawLeftover` for their `free` balance.
  - The Core Admin Safe can return their `ink` with `Vat.grab` + `GemJoin.exit` straight to the user. This must happen before any `removeCollateralType(slisBNB)`.

## Open decisions

- **Sigma deposits.** Add Sigma to `depositWhitelist`, at cut-over or later via `setDepositWhitelist`, or keep it redeem-only as today.
- **Compiler.**
  - V1 was built with 0.8.10 / london. This repo builds with 0.8.24 (cancun is the default for that compiler, and BSC supports it). The storage layout does not depend on the compiler.
  - The fork test needs cancun anyway, because the live minter uses newer opcodes.
- **Licence.** V1 is GPL-3.0-only and V2 inherits it, so `SlisBNBProviderV2.sol` keeps the GPL-3.0-only header. The rest of this repo is MIT.
- **Audit** before scheduling.

## Tests

`test/cdp/SlisBNBProviderV2Migration.t.sol` forks BSC at the latest block (`BSC_RPC`). It runs steps 2 and 4 with `vm.prank`, without the TimeLock schedule, and checks:

- Balances move out of the CDP. The legacy clisBNB is replaced by minter slisBNBx. The delegatee and the reserve/MPC0 balances are exact.
- The Aster asBNB mint/burn and the Pendle / Sigma SY deposit/redeem round trips work.
- Sigma deposits are refused until whitelisted.
- `liquidation` and `releaseFor` from the PROXY holders and the migrator revert.
- Pendle and Sigma still work after 7 days with no oracle update.
- `migrateFromCdp` cannot run twice.

```
BSC_RPC=<rpc> forge test --mc ProviderV2Migration -vv
```
