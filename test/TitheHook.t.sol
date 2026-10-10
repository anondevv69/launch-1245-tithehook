// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TitheFixture,
    TitheHook,
    TitheRouter,
    PoolKey,
    PoolId,
    IHooks,
    Currency,
    SwapParams,
    ModifyLiquidityParams,
    BalanceDelta,
    TickMath,
    HookFlags,
    MockERC20
} from "./helpers/TitheFixture.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract TitheHookTest is TitheFixture {
    function test_permissionsAndRuntime() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), 0x20cc);
        assertLe(address(hook).code.length, 24576);
    }

    function test_factoryInitializationUsesImmutableDefaults() public view {
        (uint256 seatId, uint24 bps, bool initialized) = hook.poolConfig(key.toId());
        assertEq(seatId, 1);
        assertEq(bps, 25);
        assertTrue(initialized);
    }

    function test_initializePoolBindsHookDataOnce() public {
        PoolKey memory second = key;
        second.tickSpacing = 120;
        hook.initializePool(second, Q96, abi.encode(uint256(2), uint24(150)));
        (uint256 seatId, uint24 bps, bool initialized) = hook.poolConfig(second.toId());
        assertEq(seatId, 2);
        assertEq(bps, 150);
        assertTrue(initialized);
        vm.expectRevert(TitheHook.AlreadyConfigured.selector);
        hook.initializePool(second, Q96, abi.encode(uint256(1), uint24(1)));
        vm.expectRevert();
        manager.initialize(second, Q96);
        (seatId, bps,) = hook.poolConfig(second.toId());
        assertEq(seatId, 2);
        assertEq(bps, 150);
    }

    function test_invalidInitializationRollsBackConfig() public {
        PoolKey memory second = key;
        second.tickSpacing = 0;
        vm.expectRevert();
        hook.initializePool(second, Q96, abi.encode(uint256(2), uint24(25)));
        (,, bool initialized) = hook.poolConfig(second.toId());
        assertFalse(initialized);
        second.tickSpacing = 120;
        vm.expectRevert(TitheHook.InvalidHookData.selector);
        hook.initializePool(second, Q96, hex"1234");
        vm.expectRevert(TitheHook.InvalidTitheBps.selector);
        hook.initializePool(second, Q96, abi.encode(uint256(2), uint24(10000)));
        vm.expectRevert(TitheHook.InvalidTitheBps.selector);
        hook.initializePool(second, Q96, abi.encode(uint256(2), uint24(0)));
        second.hooks = IHooks(address(0));
        vm.expectRevert(TitheHook.WrongHook.selector);
        hook.initializePool(second, Q96, abi.encode(uint256(2), uint24(25)));
    }

    function test_callbacksAndReceiveRejectOutsiders() public {
        SwapParams memory params = SwapParams(true, -1 ether, Q96 / 2);
        vm.expectRevert(TitheHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(TitheHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(TitheHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(TitheHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(1, address(0)));
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
        vm.prank(address(manager));
        vm.expectRevert(TitheHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(1, address(0)));
    }

    function testFuzz_bothDirectionsAndModes(uint96 amountSeed, bool buy, bool exactInput) public {
        _seed();
        uint256 amount = bound(amountSeed, 1e8, 10 ether);
        uint256 oldEth = trader.balance;
        uint256 oldTokens = token.balanceOf(trader);
        (uint256 input, uint256 output) = _swap(buy, exactInput ? -int256(amount) : int256(amount));
        assertGt(output, 0);
        if (exactInput) assertEq(input, amount);
        else assertEq(output, amount);
        address asset = buy ? address(0) : address(token);
        assertEq(hook.titheOf(1, asset), input * 25 / 10000);
        assertEq(hook.titheOf(1, buy ? address(token) : address(0)), 0);
        assertEq(trader.balance, buy ? oldEth - input : oldEth + output);
        assertEq(token.balanceOf(trader), buy ? oldTokens + output : oldTokens - input);
        _assertAccounting(1, key.currency0);
        _assertAccounting(1, key.currency1);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function testFuzz_partialFillChargesTitheOnSpecifiedBudget(uint96 amountSeed, bool buy) public {
        _seed();
        uint256 amount = bound(amountSeed, 100 ether, 1000 ether);
        TitheRouter.SwapRequest memory request = _request(buy, -int256(amount));
        request.params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(buy ? int24(-1) : int24(1));
        vm.prank(trader);
        (uint256 input, uint256 output) = router.swap{value: buy ? amount : 0}(request);
        assertLt(input, amount);
        assertGt(output, 0);
        // Exact input: the tithe is fixed on the specified budget, so nothing is left to refund as claims.
        uint256 fee = amount * 25 / 10000;
        assertEq(hook.titheOf(1, buy ? address(0) : address(token)), fee);
        assertGt(input, fee);
        _assertAccounting(1, key.currency0);
        _assertAccounting(1, key.currency1);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function test_freshManagerTokenOnlyLiquidityBothBuyModes() public {
        // Price sits at the range's upper boundary: only token1 is deposited.
        lp.modify(key, ModifyLiquidityParams(-600, 0, 100_000 ether, bytes32(0)));
        assertEq(address(manager).balance, 0);
        (uint256 input,) = _swap(true, -1 ether);
        uint256 fee = input * 25 / 10000;
        assertEq(address(hook).balance, 0);
        assertEq(hook.pendingTithe(1, address(0)), fee);
        _assertAccounting(1, key.currency0);
        uint256 ownerBefore = alice.balance;
        vm.prank(bob);
        hook.claim(1, address(0));
        assertEq(alice.balance, ownerBefore + fee);
        assertEq(hook.titheOf(1, address(0)), 0);
        _assertAccounting(1, key.currency0);
    }

    function test_freshManagerExactOutputBuyRedeemsPermissionlessly() public {
        lp.modify(key, ModifyLiquidityParams(-600, 0, 100_000 ether, bytes32(0)));
        (uint256 input,) = _swap(true, 1 ether);
        uint256 fee = input * 25 / 10000;
        assertEq(hook.pendingTithe(1, address(0)), fee);
        vm.prank(bob);
        assertEq(hook.redeemTithe(1, address(0)), fee);
        assertEq(hook.pendingTithe(1, address(0)), 0);
        assertEq(hook.tithe(1, address(0)), fee);
        _assertAccounting(1, key.currency0);
    }

    function test_claimFollowsSeatTransferAndPaysNoCallerBounty() public {
        _seed();
        _swap(true, -1 ether);
        _swap(false, -2 ether);
        uint256 ethFee = hook.titheOf(1, address(0));
        uint256 tokenFee = hook.titheOf(1, address(token));
        vm.prank(alice);
        seat.transferFrom(alice, bob, 1);
        uint256 callerEth = trader.balance;
        vm.prank(trader);
        hook.claim(1, address(0));
        vm.prank(trader);
        hook.claim(1, address(token));
        assertEq(bob.balance, ethFee);
        assertEq(token.balanceOf(bob), tokenFee);
        assertEq(alice.balance, 0);
        assertEq(trader.balance, callerEth);
        _assertAccounting(1, key.currency0);
        _assertAccounting(1, key.currency1);
        vm.expectRevert(TitheHook.NothingToClaim.selector);
        hook.claim(1, address(0));
    }

    function test_missingOrBurnedSeatDoesNotLoseAccrual() public {
        _seed();
        _swap(true, -1 ether);
        uint256 fee = hook.titheOf(1, address(0));
        seat.burn(1);
        vm.expectRevert();
        hook.claim(1, address(0));
        assertEq(hook.titheOf(1, address(0)), fee);
        _swap(true, -1 ether);
        assertGt(hook.titheOf(1, address(0)), fee);
    }

    function test_badSwapAndSlippageRollBackFees() public {
        _seed();
        TitheRouter.SwapRequest memory request = _request(true, -1 ether);
        request.minOutput = 2 ether;
        vm.prank(trader);
        vm.expectRevert(TitheRouter.Slippage.selector);
        router.swap{value: 1 ether}(request);
        assertEq(hook.totalTithe(address(0)), 0);
        request.minOutput = 1;
        request.params.sqrtPriceLimitX96 = Q96;
        vm.prank(trader);
        vm.expectRevert();
        router.swap{value: 1 ether}(request);
        assertEq(hook.totalTithe(address(0)), 0);
    }

    function test_exactOutputPriceBoundRevertsAtomically() public {
        _seed();
        TitheRouter.SwapRequest memory request = _request(false, 100 ether);
        request.params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(1);
        vm.prank(trader);
        vm.expectRevert(TitheRouter.Slippage.selector);
        router.swap(request);
        assertEq(hook.totalTithe(address(token)), 0);
    }

    function test_directDonationIsUnassignedSurplus() public {
        _seed();
        _swap(false, -1 ether);
        uint256 credit = hook.titheOf(1, address(token));
        token.transfer(address(hook), 77);
        hook.claim(1, address(token));
        assertEq(token.balanceOf(alice), credit);
        assertEq(token.balanceOf(address(hook)), 77);
        assertEq(hook.totalTithe(address(token)), 0);
    }

    function test_liquidityCanBeRemovedWithOutstandingTithe() public {
        _seed();
        _swap(true, -1 ether);
        uint256 fee = hook.titheOf(1, address(0));
        lp.modify(key, ModifyLiquidityParams(-600, 600, -int256(100_000 ether), bytes32(0)));
        hook.claim(1, address(0));
        assertEq(alice.balance, fee);
    }
}
