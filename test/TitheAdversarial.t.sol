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
import {TaxToken, ClaimReceiver, NoReturnToken} from "./mocks/AdversarialMocks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract TitheAdversarialTest is TitheFixture {
    function test_nativeClaimCannotReenterAndFailedPayoutPreservesCredit() public {
        _seed();
        ClaimReceiver recipient = new ClaimReceiver(hook, seat);
        vm.prank(alice);
        seat.transferFrom(alice, address(recipient), 1);
        _swap(true, -1 ether);
        uint256 fee = hook.titheOf(1, address(0));
        recipient.setReject(true);
        vm.expectRevert();
        hook.claim(1, address(0));
        assertEq(hook.titheOf(1, address(0)), fee);
        // The rejecting owner cannot halt accrual.
        _swap(true, -1 ether);
        fee = hook.titheOf(1, address(0));
        recipient.setReject(false);
        hook.claim(1, address(0));
        assertEq(address(recipient).balance, fee);
        assertTrue(recipient.attempted());
        assertFalse(recipient.reentered());
        assertFalse(recipient.redeemed());
        assertEq(hook.totalTithe(address(0)), 0);
    }

    function test_pendingClaimAndFailedPayoutAreAtomic() public {
        lp.modify(key, ModifyLiquidityParams(-600, 0, 100_000 ether, bytes32(0)));
        ClaimReceiver recipient = new ClaimReceiver(hook, seat);
        vm.prank(alice);
        seat.transferFrom(alice, address(recipient), 1);
        _swap(true, -1 ether);
        uint256 fee = hook.pendingTithe(1, address(0));
        recipient.setReject(true);
        vm.expectRevert();
        hook.claim(1, address(0));
        assertEq(hook.pendingTithe(1, address(0)), fee);
        assertEq(manager.balanceOf(address(hook), 0), fee);
        assertEq(address(hook).balance, 0);
        recipient.transferSeat(bob);
        hook.claim(1, address(0));
        assertEq(bob.balance, fee);
        _assertAccounting(1, key.currency0);
    }

    function test_zeroOrSelfSeatOwnerCannotBurnCredit() public {
        _seed();
        _swap(true, -1 ether);
        uint256 fee = hook.titheOf(1, address(0));
        vm.mockCall(address(seat), abi.encodeCall(IERC721.ownerOf, (1)), abi.encode(address(0)));
        vm.expectRevert(TitheHook.InvalidSeatOwner.selector);
        hook.claim(1, address(0));
        vm.clearMockedCalls();
        vm.prank(alice);
        seat.transferFrom(alice, address(hook), 1);
        vm.expectRevert(TitheHook.InvalidSeatOwner.selector);
        hook.claim(1, address(0));
        assertEq(hook.titheOf(1, address(0)), fee);
    }

    function test_feeOnTransferCreditsOnlyReceivedAndReentryFails() public {
        TaxToken tax = new TaxToken();
        PoolKey memory taxKey = key;
        taxKey.currency1 = Currency.wrap(address(tax));
        manager.initialize(taxKey, Q96);
        tax.transfer(address(lp), 10_000 ether);
        lp.modify(taxKey, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        tax.transfer(trader, 10 ether);
        tax.configure(address(hook), address(hook), 1000);
        tax.setReentry(hook);
        TitheRouter.SwapRequest memory request = _request(false, -1 ether);
        request.key = taxKey;
        vm.startPrank(trader);
        tax.approve(address(router), 1 ether);
        (uint256 input,) = router.swap(request);
        vm.stopPrank();
        uint256 charged = input * 25 / 10000;
        uint256 credited = charged - charged / 10;
        assertEq(hook.titheOf(1, address(tax)), credited);
        assertEq(tax.balanceOf(address(hook)), credited);
        assertTrue(tax.attemptedReentry());
        assertFalse(tax.reentrySucceeded());
        tax.setBlocked(true);
        vm.expectRevert();
        hook.claim(1, address(tax));
        assertEq(hook.titheOf(1, address(tax)), credited);
        tax.setBlocked(false);
        hook.claim(1, address(tax));
        assertEq(tax.balanceOf(alice), credited - credited / 10);
        assertEq(tax.balanceOf(address(hook)), 0);
        assertEq(hook.totalTithe(address(tax)), 0);
    }

    function test_inboundTransferTaxCannotSpendOtherRouterBalances() public {
        _seed();
        TaxToken tax = new TaxToken();
        PoolKey memory taxKey = key;
        taxKey.currency1 = Currency.wrap(address(tax));
        manager.initialize(taxKey, Q96);
        tax.transfer(address(router), 5 ether); // unrelated donation cannot subsidize an input tax
        tax.transfer(trader, 10 ether);
        tax.configure(address(router), address(0), 1000);
        TitheRouter.SwapRequest memory request = _request(false, -1 ether);
        request.key = taxKey;
        vm.startPrank(trader);
        tax.approve(address(router), 1 ether);
        vm.expectRevert(TitheRouter.TransferTaxNotSupported.selector);
        router.swap(request);
        vm.stopPrank();
        assertEq(tax.balanceOf(address(router)), 5 ether);
        assertEq(tax.balanceOf(trader), 10 ether);
    }

    function test_tokenPairBothDirectionsAndPartialInputFill() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 1_000_000 ether);
        (Currency a, Currency b) = address(other) < address(token)
            ? (Currency.wrap(address(other)), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(address(other)));
        PoolKey memory pairKey = PoolKey(a, b, 12500, 60, IHooks(address(hook)));
        hook.initializePool(pairKey, Q96, abi.encode(uint256(2), uint24(75)));
        other.transfer(address(lp), 10_000 ether);
        other.transfer(trader, 1000 ether);
        vm.prank(trader);
        other.approve(address(router), type(uint256).max);
        lp.modify(pairKey, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i % 2 == 0;
            TitheRouter.SwapRequest memory request = _request(zeroForOne, i < 2 ? -int256(1 ether) : int256(1 ether));
            request.key = pairKey;
            address asset = Currency.unwrap(zeroForOne ? a : b);
            uint256 oldCredit = hook.titheOf(2, asset);
            vm.prank(trader);
            (uint256 input,) = router.swap(request);
            assertEq(hook.titheOf(2, asset) - oldCredit, input * 75 / 10000);
        }
        TitheRouter.SwapRequest memory boundedSale = _request(true, -int256(100 ether));
        boundedSale.key = pairKey;
        boundedSale.params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(-2);
        uint256 beforeCredit = hook.titheOf(2, Currency.unwrap(a));
        vm.prank(trader);
        (uint256 paid,) = router.swap(boundedSale);
        assertLt(paid, 100 ether);
        assertEq(hook.titheOf(2, Currency.unwrap(a)) - beforeCredit, paid * 75 / 10000);
        _assertAccounting(2, a);
        _assertAccounting(2, b);
    }

    function test_routerRejectsForgedCallbacksExpiredAndWrongValue() public {
        TitheRouter.SwapRequest memory request = _request(true, -1 ether);
        vm.expectRevert(TitheRouter.OnlyPoolManager.selector);
        router.unlockCallback(abi.encode(request));
        vm.prank(address(manager));
        vm.expectRevert(TitheRouter.UnexpectedUnlock.selector);
        router.unlockCallback(abi.encode(request));
        vm.warp(5);
        request.deadline = 4;
        vm.expectRevert(TitheRouter.Expired.selector);
        router.swap{value: 1 ether}(request);
        request.deadline = 5;
        vm.expectRevert(TitheRouter.InvalidValue.selector);
        router.swap(request);
        request.minOutput = 0;
        vm.expectRevert(TitheRouter.InvalidRequest.selector);
        router.swap{value: 1 ether}(request);
        request.minOutput = 1;
        request.key.hooks = IHooks(address(token));
        vm.expectRevert(TitheRouter.InvalidRequest.selector);
        router.swap{value: 1 ether}(request);
    }

    function test_routerRefundsOnlyItsCallersInput() public {
        _seed();
        token.transfer(address(router), 123);
        vm.deal(address(router), 456);
        _swap(true, 1 ether);
        _swap(false, 1 ether);
        assertEq(token.balanceOf(address(router)), 123);
        assertEq(address(router).balance, 456);
    }
}
