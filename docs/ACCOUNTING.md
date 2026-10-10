# Input-currency accounting

The authoritative integration is the pinned [v4 Hooks library](../lib/v4-core/src/libraries/Hooks.sol) and [PoolManager](../lib/v4-core/src/PoolManager.sol). The upstream [IHooks interface](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/interfaces/IHooks.sol) specifies that `afterSwap` returns only the **unspecified** currency's delta.

Let `B = 10000`, `r = titheBps`, `x` be the core AMM's actual input debit (including the LP fee), and `F` be tithe charged. Each pool's `r` is fixed at initialization, with `0 < r < B`. Both token orderings use `params.zeroForOne` to select input, never token-address assumptions.

## Exact output

Input is the unspecified currency. `beforeSwap` returns zero deltas and no LP override. `afterSwap` calculates:

```text
F = floor(x * r / (B - r))
gross input G = x + F
F = floor(G * r / B)
```

The hook takes or mints `F` and returns positive `F` from `afterSwap`. That positive hook delta offsets its `-F` withdrawal/mint delta and increases the router's input debt to `x + F`. Output is unchanged. The real manager can partially fill an exact-output swap at a price bound; the calculation still uses its actual input. TitheRouter requires a complete exact-output fill to meet its API promise, while the raw integration tests exercise partial fills directly.

## Exact input

The specified currency is input, which cannot be modified by the `afterSwap` return value. For the specified input budget `A`:

```text
F = floor(A * r / B)        // the tithe, fixed before the AMM runs
AMM input budget = A - F
x <= A - F                  // what the AMM actually consumed
swapper's debt = x + F
```

`beforeSwap` returns `(specifiedDelta = +F, unspecifiedDelta = 0)` and the real AMM swaps `A - F`. `F` is strictly less than `A`, so this is not a NoOp replacement of the swap. The hook never supplies its own exchange rate or fabricates an output delta.

In `afterSwap`, the hook recomputes the same `F` from `params.amountSpecified`, reverts with `SwapNotFilled` if `x == 0`, takes or mints `F` for the seat, and returns a zero unspecified delta. Its deltas net to `+F - F = 0`. The manager reports a swapper debt of `x + F`, which is exactly what a `SETTLE_ALL` router pays; the hook mints no claims to the caller, so a router that never touches ERC-6909 ends the swap with none.

On a full fill, `x = A - F` and the tithe is `r / B` of the gross input `A`. On a partial fill (the price limit or the end of the liquidity is reached first), the swapper pays `x + F` with `F` still computed on `A`: the tithe is a percentage of the budget the swapper specified, not of the portion the AMM used. This is the documented trade-off: the specified-currency delta has no refund channel that generic routers honor, so the only way to keep every router's accounting exact is to never over-reserve and refund. Rate/rounding fuzz tests cover the entire supported bps range; `test/TitheGenericRouter.t.sol` checks full and partial fills through a `SETTLE_ALL`/`TAKE_ALL` router.

For integrations, nothing beyond the ordinary v4 sequence is required: swap, settle the input currency's reported delta, take the output currency's reported delta. A multi-hop route through a Tithe pool is tithed on the input amount of its own hop.

## Fee backing

Fees are held in the original input currency as requested by the workflow. During a swap, the router may not have paid input yet. A `take` from a fresh manager can therefore fail despite a valid trade. Tithe checks the manager's current liquid balance:

- Sufficient balance: `take(currency, hook, F)`; measure `balanceAfter - balanceBefore`; credit only that received amount.
- Insufficient balance: `mint(hook, currency.toId(), F)`; record pending credit at face value. This does not need a liquid manager balance during the callback.

The manager's unlock cannot finish with an unpaid swapper debt, so credits from an unsettled swap are reverted along with the trade. The hook never pays the manager from unrelated seat balances.

Native transfers are always sent to the hook during collection. The hook accepts ETH only from the configured manager and does not forward it to the seat owner until a claim, so a rejecting owner cannot break trading.

`redeemTithe` may start a new manager unlock or use one that is already open. The private redemption routine reduces pending credits, burns the hook's own claims, takes currency into the hook, and records the actual liquid receipt. A tax on that transfer reduces the credited amount accordingly. The manager-only `unlockCallback` accepts only a redemption the hook requested; no payer or payment recipient is decoded from arbitrary user data.

Aggregate pending amounts are `uint256`, whereas each v4 take/burn is bounded by `int128.max`. Each redemption is capped at that bound. Permissionless preparatory redemption lets an arbitrarily large aggregate become liquid without an unbounded loop. A claim pays only when it can clear the entire seat/currency entitlement.

## Claim ordering and invariants

Claims are guarded with a shared reentrancy guard, including all callback paths that could create credit. Pending redemption happens first. Next, a live `ownerOf` lookup identifies the recipient; then liquid credit and total liabilities are decreased; finally the transfer is made. Any failure reverts every state change and the manager redemption. Reentry via the NFT's static owner lookup cannot mutate state, and token/native transfer reentry cannot enter credit-changing functions.

For non-rebasing, standard-debit currencies, liabilities equal all internally acquired backing at completed call boundaries. Unsolicited currency or manager-claim transfers are surplus and do not change liabilities. Mid-call view observations during external token code may see intermediate accounting and must not be used as an oracle by another protocol.
