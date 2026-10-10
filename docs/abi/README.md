# ABI exports

These JSON files are standard ABI arrays generated from the pinned Foundry build:

- [TitheHook.json](TitheHook.json)
- [TitheToken.json](TitheToken.json)
- [TitheRouter.json](TitheRouter.json)

Regenerate with `python3 tools/export_abis.py`; verify agreement with the build using `python3 tools/export_abis.py --check`. The exporter needs Python 3 and Forge, with no Python packages or network access. Addresses are supplied by the deployment service, not embedded in these files.

## Frontend-facing hook methods

| Method | Meaning |
| --- | --- |
| `IMD_SEAT()` | Immutable ERC-721 contract whose `ownerOf(uint256)` supplies each beneficiary. |
| `poolManager()` | Immutable v4 dependency. |
| `defaultSeatId()`, `defaultTitheBps()` | Defaults used by a normal factory initialization. |
| `poolConfig(bytes32)` | `(seatId, titheBps, initialized)` for a v4 pool ID. |
| `titheOf(uint256,address)` | Nominal full entitlement, including pending manager claims. |
| `tithe(uint256,address)` | Liquid credit. |
| `pendingTithe(uint256,address)` | Face amount awaiting redemption from manager claims. |
| `totalTithe(address)`, `totalPending(address)` | Aggregates across seats. |
| `claim(uint256,address)` | Permissionless full payout to the live seat owner; returns amount debited. No approval needed. |
| `redeemTithe(uint256,address)` | Permissionless backing redemption into the hook; returns actual received amount. Does not change beneficiary. |
| `initializePool(PoolKey,uint160,bytes)` | Atomic custom configuration/initialization. Payload is `abi.encode(uint256,uint24)`. |
| `getHookPermissions()` | Declared callbacks, matching address bits `0x20cc`. |

Use `address(0)` only to identify native ETH in balance/claim methods. Raw amounts are minor units. `claim`'s amount is the hook's transfer amount; a transfer-tax token may deliver less to its owner.

`PoolConfigured` provides seat/rate discovery. `TitheAccrued` distinguishes `charged` from `credited` and marks deferred backing. `TitheRedeemed` reports nominal claims burned and actual currency received. `TitheClaimed` reports the resolved beneficiary and amount debited.

For `TitheRouter.swap`, use the tuple shape in the generated ABI. A request comprises `key`, `params`, `maxInput`, `minOutput`, and `deadline`; v4 `params` contains `zeroForOne`, signed `amountSpecified`, and `sqrtPriceLimitX96`. The return is `(input, output)`: the input the manager charged (AMM input plus tithe) and the observed output receipt. Both assets are sent/refunded to the transaction caller. See the root README for supported asset and slippage semantics.

Hook callbacks and `unlockCallback` are manager-only protocol methods, not UI actions. Decode revert errors for user feedback; do not bypass failed simulation by changing the beneficiary, suppressing slippage or swapping the seat dependency.
