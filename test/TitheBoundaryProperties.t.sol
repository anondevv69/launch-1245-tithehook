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
import {RawSwapHarness} from "./helpers/RawSwapHarness.sol";
import {ClaimDonationHarness} from "./helpers/ClaimDonationHarness.sol";

contract TitheBoundaryPropertiesTest is TitheFixture {
    using StateLibrary for IPoolManager;

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partialBothModesAndDirectionsUseSpentInput(uint24 rateSeed, bool buy, bool exactInput) public {
        uint24 rate = uint24(bound(rateSeed, 1, 9999));
        PoolKey memory pool = key;
        pool.tickSpacing = 120;
        hook.initializePool(pool, Q96, abi.encode(uint256(2), rate));
        lp.modify(pool, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        RawSwapHarness raw = new RawSwapHarness(manager);
        vm.deal(address(raw), 1_000_000 ether);
        token.transfer(address(raw), 1_000_000 ether);
        uint256 specified = exactInput ? 200_000 ether : 100 ether;
        Currency inputAsset = buy ? pool.currency0 : pool.currency1;
        Currency outputAsset = buy ? pool.currency1 : pool.currency0;
        uint256 beforeInput = inputAsset.balanceOf(address(raw));
        uint256 beforeOutput = outputAsset.balanceOf(address(raw));
        (uint256 spent, uint256 received) = raw.swap(
            pool,
            SwapParams(
                buy,
                exactInput ? -int256(specified) : int256(specified),
                TickMath.getSqrtPriceAtTick(buy ? int24(-1) : int24(1))
            ),
            "",
            1
        );
        assertGt(spent, 0);
        assertGt(received, 0);
        if (exactInput) assertLt(spent, specified, "test must reach a partial input fill");
        else assertLt(received, specified, "test must reach a partial output fill");
        assertEq(beforeInput - inputAsset.balanceOf(address(raw)), spent);
        assertEq(outputAsset.balanceOf(address(raw)) - beforeOutput, received);
        assertEq(hook.titheOf(2, Currency.unwrap(inputAsset)), spent * rate / 10_000);
        assertEq(hook.titheOf(2, Currency.unwrap(outputAsset)), 0);
        assertEq(hook.titheOf(1, Currency.unwrap(inputAsset)), 0);
        assertEq(manager.balanceOf(address(raw), inputAsset.toId()), 0);
        (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(pool.toId());
        assertEq(lpFee, 12500, "hook altered the independent LP fee");
        _assertAccounting(2, inputAsset);
        _assertAccounting(2, outputAsset);
    }

    function test_emptyPoolRefundsEntireReservationWithoutCreatingTithe() public {
        RawSwapHarness raw = new RawSwapHarness(manager);
        vm.deal(address(raw), 10 ether);
        token.transfer(address(raw), 10 ether);
        for (uint256 i; i < 4; ++i) {
            bool buy = i % 2 == 0;
            bool exactInput = i < 2;
            uint256 beforeETH = address(raw).balance;
            uint256 beforeTokens = token.balanceOf(address(raw));
            (uint256 spent, uint256 received) = raw.swap(
                key,
                SwapParams(
                    buy,
                    exactInput ? -int256(1 ether) : int256(1 ether),
                    TickMath.getSqrtPriceAtTick(buy ? int24(-60) : int24(60))
                ),
                "",
                1
            );
            assertEq(spent, 0);
            assertEq(received, 0);
            assertEq(address(raw).balance, beforeETH);
            assertEq(token.balanceOf(address(raw)), beforeTokens);
            assertEq(hook.totalTithe(address(0)), 0);
            assertEq(hook.totalTithe(address(token)), 0);
            assertEq(manager.balanceOf(address(raw), 0), 0);
            assertEq(manager.balanceOf(address(raw), uint160(address(token))), 0);
        }
    }

    function test_routerBurnsOnlyNewRefundClaimsInBothCurrencies() public {
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
