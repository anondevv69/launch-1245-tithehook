# Implementation review and independent-review handoff

This is a self-review by the implementing contributor, not the separately required independent adversarial review or an audit certificate. The reviewer should inspect the final source, generated ABI and subsequent service manifest together. The services' publication/attestation/admission steps are not substitutes for checking constructor, policy or authorization conflicts.

**Update (2026-10-16):** The independent adversarial review called for below has been completed — see [REVIEW-2026-10-16.md](REVIEW-2026-10-16.md). It was directed by fren (the submission team's agent) and executed by reviewers who did not implement these contracts; it is an independent adversarial review by the agent team, not a paid third-party audit by an external security firm and not an audit certificate. It ran Slither and Mythril, added targeted Foundry tests, rehearsed the live demo path on a mainnet fork, and verified the deployed bytecode against this source. Formal verification remains not done.

## Reviewed boundaries

| Boundary | Implementation and evidence |
| --- | --- |
| Hook address / permissions | Constructor calls v4 `Hooks.validateHookPermissions`; CREATE2-mined deployment and wrong-address rejection tests. Enabled mask `0x20cc`. |
| Callback authentication | Every enabled callback and unlock callback checks `msg.sender == poolManager`. Direct unauthorized calls are tested. Unused selectors revert. |
| Initialization | Write-once config, strict 64-byte wrapper payload, atomic rollback, factory defaults, and swap-data immutability tests. No NFT call in a constructor or pool initialization. |
| Input amounts / casts | Nonzero swap specification is bounded to ±`int128.max`. Intermediate products fit uint256. Final input plus fee is checked before returning a narrowed delta. |
| beforeSwapReturnDelta | Exact-input tithe strictly below input, fixed before the AMM runs and never refunded; no custom output, no LP override. Fuzz test proves the bound across supported rates. |
| Settlement | Real PoolManager enforces zero deltas at unlock end. Buy/sell, both modes, partial fills, token pairs, multi-swap unlocks and intentionally unpaid swaps are tested, through the reference router, a raw harness and a SETTLE_ALL/TAKE_ALL generic router that must end every swap with zero ERC-6909 claims. |
| Fresh pool cash | Insufficient manager balance uses ERC-6909 claims. Fresh native-input and token-input cases, later redemption and atomic failed payout are tested. |
| Ownership changes | NFT owner resolved on every claim after backing redemption. Transfer/burn/missing owner, zero/self recipient, permissionless triggering and duplicate claim tests. |
| Reentrancy | Shared OpenZeppelin guard covers initialization, swaps, redemption and claims. Unlock callback additionally requires an active hook-initiated redemption. Malicious native recipient and token transfer callbacks are tested. |
| Token transfer behavior | Actual receipt measurement, no-return token success, blocked-transfer rollback and transfer-tax collection/redemption tests. Unsupported rebasing and extra-debit semantics are documented. |
| Router funds | Pulls only caller funds at entry. Callback pays from prefunded balance. No arbitrary payer address, allowance operator, administrator or sweeper. Donations cannot subsidize or be refunded by other calls. |
| Slippage | Deadline, gross input cap, nonzero minimum output and exact-output fulfillment checked. Price-bound exact-input partial fills (tithe on the specified budget, nothing stranded) and exact-output failure are tested. |
| Conservation | Stateful campaign across three pools, two seats, ownership transfers, swaps and claims; aggregate credit/backing, claimed-plus-outstanding and entire TDEMO supply invariants. |
| Oversized pending aggregates | Bounded redemption and full-claim requirement; explicit accounting-manager unit test above int128.max. |
| Immutability | No proxy, admin, pause, upgrade, destruction or post-constructor mint path. Production runtime opcode scans and token supply/transfer tests. |

## Trust and integration limits

- The supplied PoolManager and immutable seat NFT must be authentic. A malicious manager can forge callbacks; a malicious NFT controls `ownerOf`. The hook cannot repair a wrong constructor dependency.
- A seat sale transfers rights to previously accrued, unclaimed revenue as well as future revenue. The former owner may claim before the sale completes; purchasers should consider transaction ordering. No snapshot of the owner is taken at swap time.
- Future pools are permissionless and can be initialized first by another caller, who picks the seat (not necessarily their own) and any rate from 1 to 9,999 bps, as the approved workflow's hookData binding allows. Initial seat/rate and price must be verified before liquidity is deposited or a route is built. The demo factory's atomic deployment/initialization prevents an inter-transaction configuration race for the launch pool; no other pool key is protected.
- On an exact-input partial fill the tithe is `titheBps` of the specified budget, not of the AMM's consumption. A swapper who sizes a budget far beyond the pool's liquidity pays the tithe on that budget. This replaced an ERC-6909 refund to the calling router, which canonical routers never redeemed (independent review, 2026-10). A swap that consumes nothing reverts.
- Raw-balance equality cannot survive unsolicited donations or forced ETH. Donations are unassigned, not an excuse to reduce credited liabilities. One exception, found by the independent review (REVIEW-2026-10-16.md, L-3): value a token itself adds to the hook during the manager→hook take window is measured as collection proceeds and credited to the collecting seat, rather than remaining unassigned — solvency is preserved, but the surplus absolute does not hold inside that measurement window. Rebase and sender-extra-debit assets can break backing and are unsupported.
- Transfer-tax assets can lose value on both manager-to-hook redemption and hook-to-owner payout. Pending claim values are nominal until redeemed. TDEMO itself has no such taxes.
- A nonexistent/burned seat, a seat owned by the hook itself, a rejecting ETH recipient, or a blocked asset can make a claim fail indefinitely. Credits remain assigned to the seat. There is deliberately no authority to redirect or rescue them.
- The code adds no oracle, MEV/sandwich protection, price quotation, rate adjustment, timelock or emergency pause. Routers/users must set trade limits; callbacks are not an oracle for other protocols during token interactions.

## Checks and remaining release work

Local validation uses Solidity 0.8.26 with the committed build settings. `forge test` includes unit/fuzz/invariant checks without an RPC or environment reads. `forge build` also runs Foundry lint; heuristic guarded-reentrancy, safe bounded casts, deadline timestamp and native-currency zero-address warnings require contextual review rather than being treated as proof of an exploit. No suppressions weaken compiler checks.

Slither, Mythril and a mainnet fork rehearsal were not run in this implementation assignment; all three were run by the independent review on 2026-10-16, which also reviewed the source and the generated manifest (see [REVIEW-2026-10-16.md](REVIEW-2026-10-16.md) for triage and dispositions). Formal verification has still not been run. Services must verify the mainnet dependencies, factory behavior, actual bytecode, constructor data, seed transaction and demo swap before release. Explorer verification and production monitoring likewise belong to those later stages.

Suggested independent focus: input-fee inverse rounding; exact-input fixed-budget tithe against canonical routers; claim ownership at payout; reentry while redeeming inside an already unlocked manager; compatibility of the service's demo router; and the immutable default seat ID in the manifest. The canonical NFT address is supplied by the workflow and is not asserted here to have been verified on-chain.
