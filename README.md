# Tithe

Tithe pays an identity.md seat, not a fixed wallet. Every completed swap accrues a fixed share of its **input currency** to the pool's seat. Anyone can trigger a claim; the beneficiary is always `IMD_SEAT.ownerOf(seatId)` at claim time.

This repository delivers the contract implementation, local tests, ABI exports and deployment handoff for the contract stage. Source publication, an independent review, `launch.json`, admission, funded mainnet deployment, explorer verification and the one-page `tithe` site are subsequent workflow/service responsibilities. No deployment or live demonstration is claimed here.

## Contracts

| Contract | Purpose |
| --- | --- |
| `TitheToken` | `Tithe Demo` / `TDEMO`, 18 decimals, exactly 1,000,000,000 tokens minted once to its deployer. No constructor arguments. |
| `TitheHook` | Immutable seat binding and rate per pool; input-currency accrual; permissionless redemption and live-owner claims. |
| `TitheRouter` | Single-hop swaps with maximum input, minimum output, deadline, and automatic partial-fill fee refunds. |

There is no owner, administrator, pause, upgrade, mint-after-deployment or asset rescue function in these contracts. Seat NFT ownership controls only who receives that seat's accumulated tithe. None of the launch supply is allocated to the hook or router.

The [hook configuration record](docs/hook-configuration.json) describes a BaseHook-style implementation written directly against v4-core interfaces, with no specialized curve or share token. It uses core currency helpers, explicit checked amount bounds and OpenZeppelin's reentrancy guard; it does not use a separate CurrencySettler/SafeCast utility or its own transient storage. `access: "none"` deliberately replaces the generator's administrative access options to honor the approved no-admin requirement.

## Build and check

Run at the repository root:

```sh
forge build
forge test
forge fmt --check
python3 tools/export_abis.py --check
```

The project pins Solidity **0.8.26**, Cancun, optimizer with 200 runs, `via_ir = true`, and `bytecode_hash = "none"`. Foundry and that compiler must be installed by the worker/verifier; all Solidity dependencies are ordinary files under `lib/`. No package download, submodule, fork RPC, environment variable, FFI or filesystem cheatcode permission is required by the tests. Dependency revisions and licenses are recorded in [docs/dependencies.json](docs/dependencies.json) and `lib/`.

Tests use the real v4 PoolManager, mined CREATE2 hook addresses, mock seat NFTs, success/failure cases, fuzzed directions/rates/amounts, and a stateful three-pool/two-seat accounting campaign. The special aggregate-claim boundary test labels its accounting-only manager harness explicitly.

## Seat selection and immutable configuration

The demo defaults are **seat #1** and **25 bps (0.25%)**. The launch service may put the payer-confirmed seat ID into the hook constructor before deployment. No confirmation is needed to use the workflow's seat #1 fallback. The constructor defaults can never change.

Uniswap v4's `initialize(PoolKey,uint160)` and initialization callbacks have **no `hookData` argument**. Tithe provides two compatible paths:

1. **Launch factory:** its normal `PoolManager.initialize` invokes `beforeInitialize`, which binds the constructor's default seat ID and rate to that pool. It needs no factory identity or administrator key.
2. **Custom pool:** call `hook.initializePool(key, sqrtPriceX96, abi.encode(uint256(seatId), uint24(titheBps)))`. This records both values and initializes the pool in the same transaction. v4 skips callbacks for operations initiated by the hook itself, so the wrapper records the configuration directly. A failed initialization rolls it back.

`poolConfig(poolId)` returns `(seatId, titheBps, initialized)`. Pool IDs use v4's `keccak256(abi.encode(PoolKey))`. Rates must be 1–9,999 bps; seat ID zero is a valid ERC-721 ID if the chosen NFT supports it. No pool can be configured twice, and swap `hookData` cannot alter a binding. Different pools can pay the same seat.

Pool creation is permissionless and first initialization wins. The launch service must deploy the hook and initialize the demo pool atomically, as the launch factory is designed to do. For additional pools, check the resulting configuration before adding liquidity. Minting/existence of the seat is checked by the NFT on claim, not at initialization: a nonexistent or burned seat accrues but cannot be paid until a valid owner exists.

## Fee and claim behavior

For the demo ETH/TDEMO pool, an ETH-input buy accrues **ETH**, and a TDEMO-input sell accrues **TDEMO**. This follows the approved workflow's explicit input-token accounting; there is no fee conversion or ETH-only sell tax. The launch's separate **12,500-unit (1.25%) LP fee** remains enabled and is never overridden by the hook.

The tithe is rounded down from the **gross input actually spent, including tithe**. For example, a fully filled exact-input buy spending 1 ETH at 25 bps accrues 0.0025 ETH, leaving 0.9975 ETH for the AMM including its LP fee. A price-limited fill pays tithe only on its spent portion. Exact-output swaps add enough input tithe to preserve the same gross-input percentage. Detailed formulas and the v4 deltas are in [docs/ACCOUNTING.md](docs/ACCOUNTING.md).

Fees are taken into the hook during `afterSwap` when the manager has enough of the input asset. ERC-20 credits use the actual increase in the hook's balance. If the manager has insufficient cash, the hook instead holds an ERC-6909 claim for that currency. This allows a first buy on a fresh token-only pool to succeed before the router settles its ETH input.

`titheOf(seatId, token)` includes liquid credit and pending manager claims; `totalTithe(token)` is the aggregate of both. `tithe(seatId, token)` shows just liquid credit and `pendingTithe` shows the pending portion. Native ETH is represented by `address(0)` **as a currency identifier**, not a deployment address.

`claim(seatId, token)` first redeems pending backing, then resolves the seat's current owner and transfers the entire credit. Any caller may submit it and receives no fee. Failed NFT lookups, reverting token transfers and owners that reject ETH leave credits intact; a rejecting owner does not block swaps. Reentrancy is guarded. A seat transferred to the hook itself cannot claim to itself. There is no alternate beneficiary, WETH fallback or rescue authority.

`redeemTithe(seatId, token)` is also permissionless and moves backing into the hook without paying anyone. A pending aggregate above v4's per-call `int128.max` limit can be redeemed in chunks. `claim` reverts with `RedeemPendingFirst` if one chunk cannot redeem all pending backing, rather than silently paying a partial claim.

## Router integration

Use `TitheRouter` or an integration that implements the refund protocol in [docs/ACCOUNTING.md](docs/ACCOUNTING.md). `afterSwap` may only return a delta in the unspecified currency. Input-currency fees on exact-input swaps therefore need `beforeSwapReturnDelta` as well. Unused fee reservations on partial fills become ERC-6909 claims owned by the calling router.

**A generic router that ignores those claims can strand its users' refunds.** TitheRouter burns the claims inside the same unlock and reduces its input payment accordingly. Full exact-input fills and exact-output swaps do not create reservation refunds. Routers are not allowlisted; integration correctness is the caller's responsibility.

`swap(SwapRequest)` takes the pool key, v4 swap parameters, `maxInput`, `minOutput` (nonzero) and deadline. Negative `amountSpecified` is an input budget including tithe; positive means exact output. ETH input requires `msg.value == maxInput`; ERC-20 input is pulled only from `msg.sender` before the unlock. Output and unused input go to that same caller. The router rejects partially filled exact-output requests; the hook itself supports raw v4 partial exact-output settlement. Bounds must be set from a current quote, with the input tithe included. No quotation or market-price oracle is provided.

## Asset assumptions and conservation

The launch TDEMO token is a standard ERC-20. Hook collection and redemption measure actual received amounts for transfer-tax safety, and payouts tolerate tokens that return no value. This does **not** make arbitrary fee-on-transfer tokens compatible with the AMM: TitheRouter rejects taxed transfers into itself or the manager; a taxed payout may deliver less than the nominal credit. Rebasing assets, sender-extra-debit tokens, malicious balances and arbitrary transfer callbacks are not supported economic assets.

At completed call boundaries, without unsolicited donations, the tests enforce:

```text
sum of seat liquid credits = hook's liquid currency balance
sum of seat pending credits = hook's PoolManager ERC-6909 balance for the currency
totalTithe = liquid + pending credits
all accrued tithe = all claimed tithe + totalTithe
```

Unsolicited ERC-20 transfers, donated manager claims and forced ETH cannot be prevented. They create **unassigned surplus**, so the universally valid backing relationship is `assets >= credits`, not unconditional raw-balance equality. No caller can appropriate that surplus through a claim. The equality invariant is fuzzed for protocol-managed flows, and surplus isolation is tested separately. Credits do not include the router's refund claims.

## After launch

There are **no owner-settable settings**. The service must verify the canonical NFT and selected seat on mainnet, deploy using the parameters in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md), seed the demo pool, perform a bounded demo swap, and verify deployed source. It must publish the actual contract addresses, pool ID, receipt and ABI links for the frontend. Policy identifiers, publication proofs and signed artifact linkage are service-owned.

The frontend should use the ABI exports in [docs/abi](docs/abi), enumerate pools/seats using `PoolConfigured` events, and read `titheOf`, `tithe`, `pendingTithe`, and `IMD_SEAT.ownerOf`. Show pending backing separately for clarity. The claim button calls `claim(seatId, token)` and should explain that payment always goes to the seat's current owner. Do not request ERC-20 approvals to claim. Re-read ownership and balances after confirmation and NFT transfers. Display each token with its own decimals.

An independent adversarial review and service fork rehearsal are still needed before release. [docs/SECURITY.md](docs/SECURITY.md) records the implementation review, tested boundaries and review handoff; it is not an independent audit.
