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
`0xEAcE519ebB14fB8404fA6DdD23C3b34abaDE44aa`. It requires open-read access,
explicit decimal feed IDs, and a positive deployment price-age limit. It rejects
duplicate IDs and values exceeding `uint32`, avoiding silent truncation.

Example dry run (933 = TSLAB, 934 = NVDAB in the supplied partner list):

```sh
# Supply DEPLOYER_PRIVATE_KEY through your existing secure environment setup.
ATLAS_FEED_IDS=933,934 ATLAS_MAX_PRICE_AGE=300 \
  forge script script/oracle/deployAtlasMultiFeedAdaptors.sol:DeployAtlasMultiFeedAdaptors \
  --rpc-url bsc
```

`300` seconds is an example deployment preflight limit, not a prescribed risk
policy. Choose the approved limit for the assets and market hours. The script
checks reads from the created adaptor addresses during simulation and logs the
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
