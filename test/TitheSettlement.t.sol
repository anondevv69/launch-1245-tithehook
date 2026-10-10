// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TitheFixture,
    TitheHook,
    TitheRouter,
    PoolKey,
    Currency,
    SwapParams,
    ModifyLiquidityParams,
    BalanceDelta,
    MockERC20,
    IHooks,
    TickMath
} from "./helpers/TitheFixture.sol";
import {RawSwapHarness} from "./helpers/RawSwapHarness.sol";
import {TaxToken, NoReturnToken} from "./mocks/AdversarialMocks.sol";

contract TitheSettlementTest is TitheFixture {
    function test_pendingTokenClaimUsesActualRedemptionReceipt() public {
        TaxToken tax = new TaxToken();
        PoolKey memory taxKey = key;
        taxKey.currency1 = Currency.wrap(address(tax));
        manager.initialize(taxKey, Q96);
        // Only currency0 (ETH) is deposited. The input token has no manager balance yet.
        lp.modify(taxKey, ModifyLiquidityParams(0, 600, 100_000 ether, bytes32(0)));
        assertEq(tax.balanceOf(address(manager)), 0);
        tax.transfer(trader, 10 ether);
        tax.configure(address(hook), address(0), 1000);
        TitheRouter.SwapRequest memory request = _request(false, -1 ether);
        request.key = taxKey;
        vm.startPrank(trader);
        tax.approve(address(router), 1 ether);
        (uint256 paid,) = router.swap(request);
        vm.stopPrank();
        uint256 fee = paid * 25 / 10000;
        assertEq(hook.pendingTithe(1, address(tax)), fee);
        assertEq(tax.balanceOf(address(hook)), 0);
        RawSwapHarness raw = new RawSwapHarness(manager);
        raw.redeem(hook, 1, address(tax)); // redeem during another contract's unlock
        assertEq(hook.titheOf(1, address(tax)), fee - fee / 10);
        assertEq(hook.totalTithe(address(tax)), tax.balanceOf(address(hook)));
        hook.claim(1, address(tax));
        assertEq(tax.balanceOf(alice), fee - fee / 10);
        assertEq(hook.totalTithe(address(tax)), 0);
    }

    function test_optionalReturnTokenCanAccrueAndClaim() public {
        NoReturnToken noReturn = new NoReturnToken();
        PoolKey memory noReturnKey = key;
        noReturnKey.currency1 = Currency.wrap(address(noReturn));
        manager.initialize(noReturnKey, Q96);
        noReturn.mint(address(lp), 10_000 ether);
        lp.modify(noReturnKey, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        RawSwapHarness raw = new RawSwapHarness(manager);
        noReturn.mint(address(raw), 10 ether);
        (uint256 paid,) = raw.swap(noReturnKey, SwapParams(false, -1 ether, TickMath.MAX_SQRT_PRICE - 1), "", 1);
        uint256 fee = paid * 25 / 10000;
        assertEq(noReturn.balanceOf(address(hook)), fee);
        hook.claim(1, address(noReturn));
        assertEq(noReturn.balanceOf(alice), fee);
        assertEq(hook.totalTithe(address(noReturn)), 0);
    }

    function test_rawPartialExactOutputChargesOnlyActualInput() public {
        _seed();
        RawSwapHarness raw = new RawSwapHarness(manager);
        token.transfer(address(raw), 1000 ether);
        (uint256 input, uint256 output) =
            raw.swap(key, SwapParams(false, 100 ether, TickMath.getSqrtPriceAtTick(1)), "", 1);
        assertLt(output, 100 ether);
        assertGt(output, 0);
        assertEq(hook.titheOf(1, address(token)), input * 25 / 10000);
        _assertAccounting(1, key.currency1);
    }

    function test_swapHookDataCannotReconfigureAndMultipleSwapsSettle() public {
        _seed();
        RawSwapHarness raw = new RawSwapHarness(manager);
        vm.deal(address(raw), 100 ether);
        (uint256 input,) = raw.swap(
            key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), abi.encode(uint256(2), uint24(9999)), 3
        );
        assertEq(input, 3 ether);
        assertEq(hook.titheOf(1, address(0)), input * 25 / 10000);
        assertEq(hook.titheOf(2, address(0)), 0);
        (uint256 seatId, uint24 bps,) = hook.poolConfig(key.toId());
        assertEq(seatId, 1);
        assertEq(bps, 25);
        _assertAccounting(1, key.currency0);
    }

    function testFuzz_rateAndRounding(uint24 bpsSeed, uint96 amountSeed, bool exactInput) public {
        uint24 bps = uint24(bound(bpsSeed, 1, 9999));
        uint256 amount = bound(amountSeed, 1e6, 1e15);
        PoolKey memory configured = key;
        configured.tickSpacing = 120;
        hook.initializePool(configured, Q96, abi.encode(uint256(2), bps));
        lp.modify(configured, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        RawSwapHarness raw = new RawSwapHarness(manager);
        vm.deal(address(raw), 100 ether);
        (uint256 paid, uint256 output) = raw.swap(
            configured,
            SwapParams(true, exactInput ? -int256(amount) : int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            "",
            1
        );
        assertGt(output, 0);
        assertEq(hook.titheOf(2, address(0)), paid * bps / 10000);
        if (exactInput) assertEq(paid, amount);
        else assertEq(output, amount);
        _assertAccounting(2, configured.currency0);
    }

    function test_tinyInputRoundsFeeToZero() public {
        _seed();
        _swap(true, -int256(399));
        assertEq(hook.titheOf(1, address(0)), 0);
        _swap(true, -int256(400));
        assertEq(hook.titheOf(1, address(0)), 1);
    }
}
