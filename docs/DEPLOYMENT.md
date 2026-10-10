# Contract-stage deployment handoff

This assignment implements contracts and ABIs. It does not write `launch.json`, broadcast transactions or run the subsequent frontend stage. The separate manifest contributor and services own those steps. Mainnet deployment/fork rehearsal and canonical seat code/ownership verification have not been performed in this implementation run.

## Constructor parameters

| Contract | Parameters, in ABI order |
| --- | --- |
| `TitheToken` | None. The deploying launch factory receives all `1000000000000000000000000000` minor units. |
| `TitheHook` | `IPoolManager manager`, `IERC721 seat`, `uint256 seatId`, `uint24 titheBps_` |
| `TitheRouter` | `IPoolManager manager`, `TitheHook hook_` |

For this launch:

- Chain: **Ethereum mainnet, chain ID 1**.
- `manager`: supplied by the chain's launch service. The hook manifest argument is **`$poolManager`**. The source and documentation intentionally do not fix a PoolManager address.
- `seat`: **`0x0000ec93127baa929e58e97dd0095a2bfb38ec1d`**, the canonical identity.md ERC-721 address provided by the approved workflow. It is an immutable constructor value. Services must check its code and the selected seat on mainnet before deploying; no upstream address table substitutes for this value.
- `seatId`: payer-confirmed seat if supplied before deployment; otherwise **1**, the approved fallback. Before deploying, confirm on mainnet that `ownerOf(seatId)` on the seat contract succeeds and returns an address that accepts plain ETH transfers. The hook cannot check this, swaps accrue regardless, and there is no path to redirect a credit whose seat is burned, unminted or owned by a contract that rejects ETH.
- `titheBps_`: **25**, adopting the workflow's suggested 0.25%.
- Router `hook_`: the actual deployed TitheHook address. Deploy the adjunct router after the hook; record its deployment separately if the hook launch service's atomic factory operation deploys only the token and hook.

There is no `$owner` or `$factory` argument: these contracts have no administration and do not restrict initialization by sender. Constructor defaults cannot change. Constructors neither call dependencies nor require dependency code to exist; normal operations require working contracts. No service-owned setting is filled with a stand-in address.

## Address mining and bytecode

Hook permission mask: **`0x20cc` (8396)**, under the v4 mask `0x3fff` (16383).

Enabled bits are beforeInitialize (13), beforeSwap (7), afterSwap (6), beforeSwapReturnDelta (3), afterSwapReturnDelta (2). All others are false. The constructor validates the deployed address against all declared bits; no test-only validation override exists in production source.

Mine CREATE2 using the **actual factory/deployer** and the full creation code plus ABI-encoded constructor parameters. The condition is:

```text
predicted = low160(keccak256(0xff || factory || salt || keccak256(initCode)))
(uint160(predicted) & 0x3fff) == 0x20cc
```

Changing a constructor value, compiler setting, source or deploying factory changes the address search. Use the same bytecode attested by the services. `test/helpers/TitheFixture.sol` contains a working CREATE2 mining and deployment example against a local PoolManager. Do not deploy its mocks or liquidity harness.

All called libraries are internal/inlined; no external library link step is required. Compile with the committed Foundry settings. All production contract names are below 32 characters, constructor arities below 16, and runtime sizes below EIP-170's 24,576-byte limit.

## Demo pool and service sequence

The demo pool is native ETH / TDEMO, fee **12500**, tick spacing **60**, with `hooks` equal to the mined TitheHook address. Native ETH's zero address sorts before the ERC-20 address. The manifest guidance's `initialPrice` is `79228162514264337593543950336`; services derive the actual opening price from the policy's **10 ETH opening market cap** and final token address/supply. Tithe places no additional price restriction on the manager's initialization.

The factory must atomically deploy and initialize the hook's pool. The required beforeInitialize permission prevents a successful manager initialization at a predicted address with no hook code. The callback sets the constructor default seat/rate on ordinary factory initialization, so no additional configuration transaction or initialization payload is needed.

The factory, not these contracts, handles the policy allocation: 10% swarm distribution through its MerkleDistributor, 80% pool allocation, and 10% payer/treasury allocation. The hook/router receive none at launch. The factory and launch policy also govern the LP fee allocation. No alternate supply or allocation is implemented here.

After accepted source, the independent manifest and security review, the services must:

1. Rehearse deployment, pool initialization and liquidity provisioning against mainnet state, with the canonical seat dependency and actual factory.
2. Deploy/initialize and seed according to the launch policy, preserving the reviewed constructor values.
3. Deploy the optional TitheRouter if needed for the live swap/integration, and verify all deployed contracts on an explorer.
4. Execute a modest quoted swap with nonzero output bound and input cap; confirm `TitheAccrued`, `PoolConfigured` and the seat's `titheOf`. Any router that settles its reported delta (Universal Router, V4Router, TitheRouter) works. Quote exact-input swaps against the pool's liquidity: an exact-input tithe is charged on the specified budget even if the AMM fills only part of it. A token-only seed can leave the first ETH fee as a pending claim; `redeemTithe` makes it liquid after input settlement.
5. Publish actual addresses, pool ID, opening parameters, receipts and source/ABI links. Then build the one-page `tithe` site using those deployed values.

Independent review, signed artifacts, admission policy records, source publication and IPFS hosting are service/workflow outcomes, not constructor parameters or prerequisites of the source assignment. This document is a handoff, not evidence those outcomes have occurred.
