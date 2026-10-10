# Additional adversarial tests

These tests extend the accepted suite without changing production contracts, dependencies, or configuration. They run offline against the vendored, real Uniswap v4 PoolManager and CREATE2-mined TitheHook deployments. Only the seat NFT, unusual token behavior, and transaction actors are mocks.

| File | Properties exercised |
| --- | --- |
| `TitheRouterSafety.t.sol` | Invalid requests and dependency mismatch; insufficient allowance; wrong ETH value; gross-input cap; rejected native output/refund; reentrancy during output/refund; transfer tax at settlement; slippage measured at the ultimate recipient after both output transfers. Failure snapshots cover trader/router/manager/hook balances, credits, manager claims, price, and liquidity. |
| `TitheClaimSafety.t.sol` | NFT ownership changes during redemption; checks-effects-interactions; cross-currency reentrancy; pending-redemption rollback on missing owner; false-return ERC-20 payouts; recovery after ownership change; taxed redemption, including 100% tax, and duplicate redemption/claim. |
| `TitheBoundaryProperties.t.sol` | Both swap modes and directions at a price limit, over the complete 1–9,999 bps range; zero fills; existing router ERC-6909 surplus; malformed initialization data; zero and maximum uint256 seat IDs; signed-delta and gross-debt overflow guards. |
| `TitheLifecycleInvariant.t.sol` | Random sequences across three pools, two seats, ETH and TDEMO, with 1/25/9,999 bps rates: swaps, price limits, redemptions, claims, seat transfers, rejected swaps, and donations. |

The new fuzz properties specify 1,000 runs inline. The new invariant campaign specifies 256 runs, depth 64, and failure on unexpected reverts inline. It starts with an actual deferred ETH fee on a fresh manager seeded with tokens only. Successful swaps, a partial fill, and a failed swap are exercised before fuzzing to avoid vacuous coverage. All six handler selectors are explicit; no general catch-and-ignore wrapper hides failed calls.

The accounting model records expected earnings from the trader's measured gross input debit and the pool's fixed rate, independently of hook accounting. It verifies each seat's outstanding earnings, actual payments to the current owner, unchanged pool bindings, fixed token supply, settled v4 deltas, and empty router liquid balances. At the end of every sequence, `afterInvariant` claims every outstanding balance and checks that all liabilities are discharged.

Liquid and pending balances are checked separately:

```text
sum(seat liquid credit) + tracked liquid donations = hook currency balance
sum(seat pending credit) + tracked claim donations = hook ERC-6909 balance
earned per seat - paid per seat = liquid credit + pending credit
router ERC-6909 balance = old donated claims, with no unconsumed swap refunds
```

Forced ETH and unsolicited ERC-20/ERC-6909 donations cannot belong to a seat merely because they arrived at the hook. The harness accounts for this surplus independently; it does not weaken conservation to a bare greater-than comparison. Native `selfdestruct` appears only in a test helper that models forced ETH, never in production code.

Run the delivered suite with `forge build` and `forge test`. During this assignment, build/cache outputs and logs are directed to `test/scratch/` to respect the write scope. No test requires that directory, an environment variable, RPC, FFI, a download, or additional filesystem permissions.

These checks do not constitute a mainnet fork rehearsal or verification of the live canonical NFT. The actual factory, mainnet dependencies, deployment, and live demo remain service/release checks. No reproducible production defect was found in these added tests.
