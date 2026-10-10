// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TitheFixture,
    TitheHook,
    TitheRouter,
    PoolKey,
    Currency,
    IHooks,
    SwapParams,
    ModifyLiquidityParams,
    BalanceDelta,
    TickMath
} from "./helpers/TitheFixture.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {RawSwapHarness} from "./helpers/RawSwapHarness.sol";
import {ClaimDonationHarness} from "./helpers/ClaimDonationHarness.sol";

contract TitheBoundaryPropertiesTest is TitheFixture {
    using StateLibrary for IPoolManager;

    /// @dev Partial fills at a one-tick price limit, over the whole rate range. The AMM's own input is
    ///      measured from the manager's balance change (less any deferred claim the hook minted instead
    ///      of taking), independently of the hook's bookkeeping. Exact input: the tithe is the rate
    ///      applied to the specified budget and the swapper owes AMM input plus that tithe. Exact
    ///      output: the tithe is the rate applied to the gross input actually spent.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partialFillsTitheBudgetForExactInputAndSpentInputForExactOutput(
        uint24 rateSeed,
        bool buy,
        bool exactInput
    ) public {
        uint24 rate = uint24(bound(rateSeed, 1, 9999));
        PoolKey memory pool = key;
        pool.tickSpacing = 120;
        hook.initializePool(pool, Q96, abi.encode(uint256(2), rate));
        lp.modify(pool, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        uint256 specified = exactInput ? 200_000 ether : 100 ether;
        PartialFill memory fill = _partialFill(pool, buy, exactInput, specified);
        if (exactInput) assertLt(fill.spent, specified, "test must reach a partial input fill");
        else assertLt(fill.received, specified, "test must reach a partial output fill");

        assertGt(fill.ammInput, 0, "the hook replaced the swap instead of charging beside it");
        assertEq(fill.spent, fill.ammInput + fill.fee, "swapper's debt is not AMM input plus tithe");
        if (exactInput) {
            assertEq(fill.fee, specified * rate / 10_000, "exact input tithe is the rate on the specified budget");
            assertLe(fill.ammInput, specified - fill.fee, "AMM consumed more than the budget left after the tithe");
        } else {
            assertEq(fill.fee, fill.spent * rate / 10_000, "exact output tithe is the rate on gross input");
            assertEq(fill.fee, fill.ammInput * rate / (10_000 - rate));
        }
        Currency inputAsset = buy ? pool.currency0 : pool.currency1;
        Currency outputAsset = buy ? pool.currency1 : pool.currency0;
        assertEq(hook.titheOf(2, Currency.unwrap(outputAsset)), 0);
        assertEq(hook.titheOf(1, Currency.unwrap(inputAsset)), 0);
        (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(pool.toId());
        assertEq(lpFee, 12500, "hook altered the independent LP fee");
        _assertAccounting(2, inputAsset);
        _assertAccounting(2, outputAsset);
    }

    struct PartialFill {
        uint256 spent;
        uint256 received;
        uint256 fee;
        uint256 ammInput;
    }

    /// @dev One raw swap at a one-tick price limit through a prefunded integrator, with the swapper's
    ///      debit, its receipt, the seat's credit and the AMM's own input all measured from balances.
    function _partialFill(PoolKey memory pool, bool buy, bool exactInput, uint256 specified)
        internal
        returns (PartialFill memory fill)
    {
        RawSwapHarness raw = new RawSwapHarness(manager);
        vm.deal(address(raw), 1_000_000 ether);
        token.transfer(address(raw), 1_000_000 ether);
        Currency inputAsset = buy ? pool.currency0 : pool.currency1;
        Currency outputAsset = buy ? pool.currency1 : pool.currency0;
        uint256 beforeInput = inputAsset.balanceOf(address(raw));
        uint256 beforeOutput = outputAsset.balanceOf(address(raw));
        uint256 beforeManager = inputAsset.balanceOf(address(manager));
        (fill.spent, fill.received) = raw.swap(
            pool,
            SwapParams(
                buy,
                exactInput ? -int256(specified) : int256(specified),
                TickMath.getSqrtPriceAtTick(buy ? int24(-1) : int24(1))
            ),
            "",
            1
        );
        assertGt(fill.spent, 0);
        assertGt(fill.received, 0);
        assertEq(beforeInput - inputAsset.balanceOf(address(raw)), fill.spent);
        assertEq(outputAsset.balanceOf(address(raw)) - beforeOutput, fill.received);
        assertEq(manager.balanceOf(address(raw), inputAsset.toId()), 0, "the integrator was handed claims");
        fill.fee = hook.titheOf(2, Currency.unwrap(inputAsset));
        // What the AMM itself consumed: the manager keeps the swapper's whole payment except the part
        // the hook took out, and keeps all of it when the hook deferred its fee as a claim.
        fill.ammInput =
            inputAsset.balanceOf(address(manager)) - beforeManager - hook.pendingTithe(2, Currency.unwrap(inputAsset));
    }

    /// @dev A pool with no liquidity: an exact-input swap consumes nothing, so the hook must not keep
    ///      the budget-based tithe. It refuses the swap outright and the manager rolls everything back.
    ///      An exact-output swap that fills nothing has nothing to tithe and leaves no trace either.
    function test_emptyPoolRejectsExactInputAndChargesNothingOnEmptyExactOutput() public {
        RawSwapHarness raw = new RawSwapHarness(manager);
        vm.deal(address(raw), 10 ether);
        token.transfer(address(raw), 10 ether);
        bytes memory refusal = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(TitheHook.SwapNotFilled.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        for (uint256 i; i < 4; ++i) {
            bool buy = i % 2 == 0;
            bool exactInput = i < 2;
            uint256 beforeETH = address(raw).balance;
            uint256 beforeTokens = token.balanceOf(address(raw));
            (uint160 beforePrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            SwapParams memory params = SwapParams(
                buy,
                exactInput ? -int256(1 ether) : int256(1 ether),
                TickMath.getSqrtPriceAtTick(buy ? int24(-60) : int24(60))
            );
            if (exactInput) {
                vm.expectRevert(refusal);
                raw.swap(key, params, "", 1);
                (uint160 afterPrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
                assertEq(afterPrice, beforePrice, "a rejected swap moved the price");
            } else {
                (uint256 spent, uint256 received) = raw.swap(key, params, "", 1);
                assertEq(spent, 0);
                assertEq(received, 0);
                // v4 walks an empty range to the limit without exchanging anything; the hook adds nothing.
                (uint160 afterPrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
                assertEq(afterPrice, params.sqrtPriceLimitX96, "empty exact-output fill should stop at its limit");
            }
            assertEq(address(raw).balance, beforeETH);
            assertEq(token.balanceOf(address(raw)), beforeTokens);
            assertEq(hook.totalTithe(address(0)), 0);
            assertEq(hook.totalTithe(address(token)), 0);
            assertEq(hook.totalPending(address(0)), 0);
            assertEq(hook.totalPending(address(token)), 0);
            assertEq(manager.balanceOf(address(raw), 0), 0);
            assertEq(manager.balanceOf(address(raw), uint160(address(token))), 0);
            assertEq(manager.balanceOf(address(hook), 0), 0);
            assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        }
    }

    /// @dev Claims a third party minted to the router earlier are not spent by a later swap, and a
    ///      partial fill mints the router no new ones: the swapper simply pays AMM input plus tithe.
    function test_swapsNeitherSpendDonatedRouterClaimsNorMintNewOnes() public {
        _seed();
        ClaimDonationHarness donor = new ClaimDonationHarness(manager);
        token.transfer(address(donor), 12345);
        donor.donate(Currency.wrap(address(token)), address(router), 12345);
        donor.donate{value: 67890}(Currency.wrap(address(0)), address(router), 67890);
        for (uint256 i; i < 2; ++i) {
            bool buy = i == 0;
            TitheRouter.SwapRequest memory request = _request(buy, -int256(100 ether));
            request.params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(buy ? int24(-1) : int24(1));
            uint256 beforeInput = (buy ? key.currency0 : key.currency1).balanceOf(trader);
            vm.prank(trader);
            (uint256 spent,) = router.swap{value: buy ? request.maxInput : 0}(request);
            assertLt(spent, request.maxInput);
            assertEq(beforeInput - (buy ? key.currency0 : key.currency1).balanceOf(trader), spent);
            assertEq(manager.balanceOf(address(router), 0), 67890);
            assertEq(manager.balanceOf(address(router), uint160(address(token))), 12345);
            assertEq(address(router).balance, 0);
            assertEq(token.balanceOf(address(router)), 0);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_initializationRejectsNoncanonicalPayloadLengths(uint8 lengthSeed) public {
        uint256 length = bound(lengthSeed, 0, 192);
        if (length == 64) length = 65;
        PoolKey memory pool = key;
        pool.tickSpacing = 120;
        vm.expectRevert(TitheHook.InvalidHookData.selector);
        hook.initializePool(pool, Q96, new bytes(length));
        (,, bool configured) = hook.poolConfig(pool.toId());
        assertFalse(configured);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(pool.toId());
        assertEq(price, 0);
    }

    function test_noncanonicalRateWordDoesNotTruncateOrPoisonInitialization() public {
        PoolKey memory pool = key;
        pool.tickSpacing = 120;
        vm.expectRevert(); // ABI decoding must reject high bits above uint24, rather than truncate to 25.
        hook.initializePool(pool, Q96, abi.encode(uint256(2), (uint256(1) << 24) | 25));
        (,, bool configured) = hook.poolConfig(pool.toId());
        assertFalse(configured);
        hook.initializePool(pool, Q96, abi.encode(uint256(2), uint24(25)));
        (uint256 id, uint24 bps, bool initialized) = hook.poolConfig(pool.toId());
        assertTrue(initialized);
        assertEq(id, 2);
        assertEq(bps, 25);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fullWidthSeatIdsAccrueAndPayWithoutAliasing(uint256 seatId) public {
        _exerciseSeatId(seatId);
    }

    function test_zeroSeatIdIsNotAnUninitializedSentinel() public {
        _exerciseSeatId(0);
    }

    function test_maxSeatIdCanAccrueAndClaim() public {
        _exerciseSeatId(type(uint256).max);
    }

    function _exerciseSeatId(uint256 seatId) internal {
        if (seatId != 1 && seatId != 2) seat.mint(bob, seatId);
        address owner = seat.ownerOf(seatId);
        PoolKey memory pool = key;
        pool.tickSpacing = 120;
        hook.initializePool(pool, Q96, abi.encode(seatId, uint24(25)));
        lp.modify(pool, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        TitheRouter.SwapRequest memory request = _request(true, -1 ether);
        request.key = pool;
        vm.prank(trader);
        router.swap{value: 1 ether}(request);
        uint256 expected = 0.0025 ether;
        assertEq(hook.titheOf(seatId, address(0)), expected);
        assertEq(hook.totalTithe(address(0)), expected);
        (uint256 configuredId,,) = hook.poolConfig(pool.toId());
        assertEq(configuredId, seatId);
        uint256 beforeOwner = owner.balance;
        vm.prank(trader);
        assertEq(hook.claim(seatId, address(0)), expected);
        assertEq(owner.balance - beforeOwner, expected);
        assertEq(hook.totalTithe(address(0)), 0);
    }

    function test_afterSwapRejectsForgedInputSignsAndOverflowBeforeCrediting() public {
        SwapParams memory params = SwapParams(true, 1, Q96 / 2);
        vm.prank(address(manager));
        vm.expectRevert(TitheHook.InvalidInputDelta.selector);
        hook.afterSwap(address(router), key, params, toBalanceDelta(1, 1), "");
        vm.prank(address(manager));
        vm.expectRevert(TitheHook.InvalidSwapAmount.selector);
        hook.afterSwap(address(router), key, params, toBalanceDelta(type(int128).min, 1), "");
        vm.prank(address(manager));
        vm.expectRevert(TitheHook.InvalidSwapAmount.selector);
        hook.afterSwap(address(router), key, params, toBalanceDelta(-type(int128).max, 1), "");
        params.zeroForOne = false;
        vm.prank(address(manager));
        vm.expectRevert(TitheHook.InvalidInputDelta.selector);
        hook.afterSwap(address(router), key, params, toBalanceDelta(1, 1), "");
        assertEq(hook.totalTithe(address(0)), 0);
        assertEq(hook.totalTithe(address(token)), 0);
    }
}
