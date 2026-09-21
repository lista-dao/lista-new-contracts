# Atlas MultiFeed adaptor

`AtlasMultiFeedAdaptor` wraps one immutable `bytes4` feed ID from an Atlas
MultiFeed registry. Deploy a separate instance per asset. The existing
`AtlasOracleAdaptor`, deployment script, and ResilientOracle remain unchanged.

## Price contract

- Source must contain code, report contract type `2`, and use 18 decimals.
- Latest reads recheck decimals to fail closed if the source proxy changes scale.
- Output is the source price divided by `1e10`, rounded down to 8 decimals.
- Empty/zero/sub-precision prices and zero/future/reversed timestamps revert.
- `startedAt` and `updatedAt` use `aggregatedTs`. Republishing an old price does
  not refresh its age. The source's `onchainTs` must be at least `aggregatedTs`
  and no later than the current block.
- Maximum age remains the consuming ResilientOracle's responsibility. Configure
  a **nonzero `timeDeltaTolerance`**; `latestAnswer()` alone does not reject age.
- `roundId` and `answeredInRound` are zero placeholders. There is no round
  history; `getRoundData()` always reverts. This is a latest-price integration
  for ResilientOracle, not a complete historical Chainlink aggregator.
- Read permissions, pause behavior, and future source upgrades remain controlled
  by Atlas. In whitelist mode, the adaptor itself must be authorized.

## Deployment

The new script targets BSC chain ID 56 and registry
`0xEAcE519ebB14fB8404fA6DdD23C3b34abaDE44aa`. It requires open-read access and a
positive heartbeat per feed, and it rejects duplicate feed IDs.

The batch is hardcoded in the script's `run()` as `Feed(symbol, feedId, heartbeat)`
entries, following `deployAtlasOracleAdaptors.sol`: each deployment batch is
reviewed in the diff rather than supplied at the shell. `feedId` is a `uint32`,
so an out-of-range ID fails to compile instead of being silently truncated.
`DEPLOYER_PRIVATE_KEY` remains the only environment input.

The deployment preflight rejects a price older than the feed's heartbeat plus
`MAX_AGE_BUFFER` (300 seconds), so a 60-second feed allows 360 seconds. This is
a deployment sanity check, not a prescribed risk policy; the
consuming ResilientOracle's `timeDeltaTolerance` is what enforces price age in
production. Confirm the heartbeat against the partner feed list, and choose the
approved production limit for the assets and market hours.

Example dry run:

```sh
# Supply DEPLOYER_PRIVATE_KEY through your existing secure environment setup.
forge script script/oracle/deployAtlasMultiFeedAdaptors.sol:DeployAtlasMultiFeedAdaptors \
  --rpc-url bsc
```

The script checks reads from the created adaptor addresses during simulation and logs the
feed ID, adaptor address, price, and aggregation time. Add `--broadcast --slow`
only when deploying; retain Foundry simulation. A batch comprises separate
deployment transactions, so it is not atomic and source state may change after
simulation. Verify all receipts and re-read each adaptor after deployment.

The script does **not** register assets or change ResilientOracle. After review,
use the existing governance process to configure each asset's adaptor, nonzero
tolerance, and applicable pivot/fallback sources. Confirm the feed prices the
correct raw token unit, and retain existing market-hours controls.

## Validation

```sh
forge test --match-path 'test/oracle/*AtlasMultiFeed*.t.sol' -vv
ATLAS_RUN_FORK_TESTS=true \
  forge test --match-path test/oracle/AtlasMultiFeedAdaptorFork.t.sol -vv
```

Fork tests default to BSC block `120911148` (2026-09-09 16:35:09 UTC). Set `BSC_RPC`
to an archive-capable endpoint, or set `ATLAS_FORK_BLOCK` to a recent fixed block
for a fresh integration check and record that block with the results.
They exercise the deployed ResilientOracle's
read and configuration interfaces on a local fork, without replacing its code.

Validated on 2026-09-10 (Hong Kong): all 329 repository tests passed, including
26 new tests with the Atlas fork pinned to block `120912983`. The deployment
script also passed a two-feed dry run at block `120913190` using a public test
key; no transactions were broadcast.

References: [Atlas interface](https://github.com/oracle-atlas/push-oracle-interfaces/blob/main/src/IMultiFeed.sol),
[MultiFeed documentation](https://docs.atlasoracle.io/developers/api-reference/multi-feed-contract),
[partner feed list](https://docs.google.com/spreadsheets/d/1kVl81yh4QPc9ZYESuSk7KTEr4GdEArp9M8Izwo161Yc/edit?gid=0#gid=0).

## BSC deployment: QQQB, feed 947

- Source commit: `2b3736b`.
- Adaptor: [`0xcAeF7a33cb7f8804e7baDEB58A58A02c81108bd4`](https://bscscan.com/address/0xcAeF7a33cb7f8804e7baDEB58A58A02c81108bd4#code).
- Transaction: [`0xba280ec23e1bde6645e99a4b077badc10eb15997ee75947fb371aad28a28bb97`](https://bscscan.com/tx/0xba280ec23e1bde6645e99a4b077badc10eb15997ee75947fb371aad28a28bb97).
- Successful receipt at block `121011038`; fee `0.0000262437 BNB`.
- BscScan source verification: **Pass - Verified**.
- Post-deployment reads at block `121011072` (2026-09-10 05:04:43 UTC)
  confirmed the registry address, feed ID `0x000003b3` (947), and 8 decimals.
  The adaptor returned `71627255117`, matching source price
  `716272551172653221380 / 1e10`, rounded down. `updatedAt` matched the source
  aggregation timestamp `1789016629`.
- This deployment did not register the adaptor in ResilientOracle or change
  existing asset configurations.

## Batch 1 fork simulation: GPROB (1053), RDDTB (1054)

Both feeds publish on a 60-second heartbeat, so the deployment preflight limit is
60 + 300 = 360 seconds. Simulated on an Anvil fork of BSC at block `123106134`
(2026-09-21), broadcasting with a public Anvil development key:

```sh
anvil --fork-url https://bsc-dataseed.binance.org --port 8546
DEPLOYER_PRIVATE_KEY=<anvil key 0> \
  forge script script/oracle/deployAtlasMultiFeedAdaptors.sol:DeployAtlasMultiFeedAdaptors \
  --rpc-url http://127.0.0.1:8546 --broadcast --slow
```

Reads against the two adaptors deployed on that fork returned the registry
address `0xEAcE519ebB14fB8404fA6DdD23C3b34abaDE44aa`, 8 decimals, version 1, and:

| Symbol | Feed ID | `feedId()` | Source price | `latestAnswer()` | `updatedAt` |
| --- | --- | --- | --- | --- | --- |
| GPROB/USD | 1053 | `0x0000041d` | `1290675473883335005` | `129067547` | `1789959850` |
| RDDTB/USD | 1054 | `0x0000041e` | `152584468985491087160` | `15258446898` | `1789959870` |

Each answer matches the source price divided by `1e10`, rounded down, and each
`updatedAt` matches the source aggregation timestamp. No transaction was sent to
BSC mainnet.
