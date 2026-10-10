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

The specified currency is input, which cannot be modified by the `afterSwap` return value. For requested gross budget `A`:

```text
R = floor(A * r / B)        // maximum reservation
AMM input budget = A - R
F = min(R, floor(x * r / (B - r)))
U = R - F                  // unused reservation
gross input actually spent G = x + F
F = floor(G * r / B)
```

`beforeSwap` returns `(specifiedDelta = +R, unspecifiedDelta = 0)` and the real AMM swaps `A - R`. The reservation is strictly less than `A`, so this is not a NoOp replacement of the swap. The hook never supplies its own exchange rate or fabricates an output delta.

In `afterSwap`, the hook:

1. Takes/mints its actual fee `F`.
2. Mints `U` ERC-6909 input-currency refund claims **to `sender`**, the calling router.
3. Returns zero unspecified delta, leaving the output untouched.

The hook's deltas net to `+R - F - U = 0`. The manager returns a router input debit of `x + R`. The router burns its newly received claims `U`, which gives it a manager credit of `U`, and pays `x + R - U = x + F`. TitheRouter returns the rest of its prefunded input to the caller.

At a full fill, `x = A - R`, `F = R`, and `U = 0`. At a zero-input fill, `F = 0` and the entire reservation is refunded. Price-bound refunds use the manager's actual swap deltas, not the requested input. Rate/rounding fuzz tests cover the entire supported bps range.

For integrations, record the router's ERC-6909 balance for the input currency immediately before `manager.swap`; burn only the increase afterwards. Do not spend old donated claims or other users' balances. Approvals/claim operators on the router are unnecessary because it burns its own claims. Do not assume the raw `swap` return delta is the final debt when refund claims exist.

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
