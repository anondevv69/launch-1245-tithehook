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
    MockERC20,
    MockSeat
} from "./helpers/TitheFixture.sol";
import {TaxToken} from "./mocks/AdversarialMocks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev An approved NFT operator that moves the seat during manager -> hook redemption.
contract SeatMovingToken is MockERC20 {
    MockSeat public immutable seat;
    TitheHook public hook;
    address public nextOwner;
    bool public moved;
    bool public reentered;
    bytes4 public reentryError;

    constructor(MockSeat seat_) MockERC20("Seat-moving token", "MOVE", 1_000_000 ether) {
        seat = seat_;
    }

    function arm(TitheHook hook_, address nextOwner_) external {
        hook = hook_;
        nextOwner = nextOwner_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (address(hook) != address(0) && to == address(hook) && !moved) {
            moved = true;
            seat.transferFrom(seat.ownerOf(1), nextOwner, 1);
            bytes memory reason;
            (reentered, reason) = address(hook).call(abi.encodeCall(hook.claim, (2, address(0))));
            reentryError = bytes4(reason);
        }
    }
}

contract FalseReturnTitheToken is MockERC20 {
    address public blockedRecipient;

    constructor() MockERC20("False-return token", "FALSE", 1_000_000 ether) {}

    function blockRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blockedRecipient) return false;
        return super.transfer(to, amount);
    }
}

contract ClaimEffectsObserver {
    TitheHook public immutable hook;
    address public immutable token;
    bool public sawClearedCredit;
    bool public reentered;
    bytes4 public errorSelector;

    constructor(TitheHook hook_, address token_) {
        hook = hook_;
        token = token_;
    }

    receive() external payable {
        sawClearedCredit = hook.titheOf(1, address(0)) == 0 && hook.totalTithe(address(0)) == 0;
        bytes memory reason;
        (reentered, reason) = address(hook).call(abi.encodeCall(hook.claim, (1, token)));
        errorSelector = bytes4(reason);
    }
}

contract TitheClaimSafetyTest is TitheFixture {
    function test_ownerIsResolvedAfterRedemptionCallbackTransfersSeat() public {
        SeatMovingToken asset = new SeatMovingToken(seat);
        PoolKey memory pool = key;
        pool.currency1 = Currency.wrap(address(asset));
        manager.initialize(pool, Q96);
        // ETH-only liquidity leaves no input token available for an immediate fee take.
        lp.modify(pool, ModifyLiquidityParams(0, 600, 100_000 ether, bytes32(0)));
        asset.transfer(trader, 10 ether);
        vm.startPrank(trader);
        asset.approve(address(router), 1 ether);
        TitheRouter.SwapRequest memory request = _request(false, -1 ether);
        request.key = pool;
        router.swap(request);
        vm.stopPrank();
        uint256 fee = 0.0025 ether;
        assertEq(hook.pendingTithe(1, address(asset)), fee);
        vm.prank(alice);
        seat.approve(address(asset), 1);
        asset.arm(hook, bob);
        vm.prank(trader);
        assertEq(hook.claim(1, address(asset)), fee);
        assertTrue(asset.moved());
        assertEq(seat.ownerOf(1), bob);
        assertEq(asset.balanceOf(alice), 0, "previous NFT owner was paid");
        assertEq(asset.balanceOf(bob), fee, "live NFT owner did not receive redemption");
        assertFalse(asset.reentered());
        assertEq(asset.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hook.totalTithe(address(asset)), 0);
        assertEq(hook.totalPending(address(asset)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(asset))), 0);
    }

    function test_claimClearsEffectsBeforeNativeInteractionAndBlocksCrossCurrencyReentry() public {
        _seed();
        _swap(true, -1 ether);
        _swap(false, -1 ether);
        uint256 tokenCredit = hook.titheOf(1, address(token));
        ClaimEffectsObserver observer = new ClaimEffectsObserver(hook, address(token));
        vm.prank(alice);
        seat.transferFrom(alice, address(observer), 1);
        vm.prank(trader);
        hook.claim(1, address(0));
        assertTrue(observer.sawClearedCredit());
        assertFalse(observer.reentered());
        assertEq(observer.errorSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hook.titheOf(1, address(token)), tokenCredit);
        assertEq(token.balanceOf(address(observer)), 0);
        // The rejected nested claim remains available after the outer claim completes.
        hook.claim(1, address(token));
        assertEq(token.balanceOf(address(observer)), tokenCredit);
    }

    function test_missingOwnerRollsBackPendingRedemptionUntilSeatExists() public {
        lp.modify(key, ModifyLiquidityParams(-600, 0, 100_000 ether, bytes32(0)));
        _swap(true, -1 ether);
        uint256 fee = hook.pendingTithe(1, address(0));
        assertGt(fee, 0);
        seat.burn(1);
        uint256 managerBefore = address(manager).balance;
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 1));
        hook.claim(1, address(0));
        assertEq(address(manager).balance, managerBefore);
        assertEq(address(hook).balance, 0);
        assertEq(hook.pendingTithe(1, address(0)), fee);
        assertEq(hook.totalPending(address(0)), fee);
        assertEq(hook.totalTithe(address(0)), fee);
        assertEq(manager.balanceOf(address(hook), 0), fee);
        seat.mint(bob, 1);
        vm.prank(alice);
        hook.claim(1, address(0));
        assertEq(bob.balance, fee);
        assertEq(alice.balance, 0);
        assertEq(hook.totalTithe(address(0)), 0);
    }

    function test_falseReturnPayoutKeepsCreditAndRetryPaysCurrentOwner() public {
        FalseReturnTitheToken asset = new FalseReturnTitheToken();
        PoolKey memory pool = key;
        pool.currency1 = Currency.wrap(address(asset));
        manager.initialize(pool, Q96);
        asset.transfer(address(lp), 10_000 ether);
        lp.modify(pool, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        asset.transfer(trader, 10 ether);
        TitheRouter.SwapRequest memory request = _request(false, -1 ether);
        request.key = pool;
        vm.startPrank(trader);
        asset.approve(address(router), 1 ether);
        router.swap(request);
        vm.stopPrank();
        uint256 fee = hook.titheOf(1, address(asset));
        assertGt(fee, 0);
        asset.blockRecipient(alice);
        vm.expectRevert(); // Currency.transfer must reject an ERC-20 false return.
        hook.claim(1, address(asset));
        assertEq(hook.titheOf(1, address(asset)), fee);
        assertEq(hook.totalTithe(address(asset)), fee);
        assertEq(asset.balanceOf(address(hook)), fee);
        assertEq(asset.balanceOf(alice), 0);
        vm.prank(alice);
        seat.transferFrom(alice, bob, 1);
        vm.prank(trader);
        assertEq(hook.claim(1, address(asset)), fee);
        assertEq(asset.balanceOf(bob), fee);
        assertEq(asset.balanceOf(address(hook)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_pendingRedemptionMeasuresTaxAndRemainsIdempotent(uint24 taxSeed) public {
        _exercisePendingTax(bound(taxSeed, 0, 10000));
    }

    function test_fullTransferTaxLeavesNoPhantomLiabilityAfterRedemption() public {
        _exercisePendingTax(10000);
    }

    function _exercisePendingTax(uint256 taxBps) internal {
        TaxToken asset = new TaxToken();
        PoolKey memory pool = key;
        pool.currency1 = Currency.wrap(address(asset));
        manager.initialize(pool, Q96);
        lp.modify(pool, ModifyLiquidityParams(0, 600, 100_000 ether, bytes32(0)));
        asset.transfer(trader, 10 ether);
        asset.configure(address(hook), address(0), taxBps);
        TitheRouter.SwapRequest memory request = _request(false, -1 ether);
        request.key = pool;
        vm.startPrank(trader);
        asset.approve(address(router), 1 ether);
        router.swap(request);
        vm.stopPrank();
        uint256 nominal = 0.0025 ether;
        assertEq(hook.pendingTithe(1, address(asset)), nominal);
        uint256 supplyBefore = asset.totalSupply();
        uint256 beforeHook = asset.balanceOf(address(hook));
        vm.prank(bob);
        uint256 received = hook.redeemTithe(1, address(asset));
        assertEq(received, asset.balanceOf(address(hook)) - beforeHook);
        assertEq(nominal, received + supplyBefore - asset.totalSupply(), "redemption lost unaccounted value");
        assertEq(hook.titheOf(1, address(asset)), received);
        assertEq(hook.totalTithe(address(asset)), received);
        assertEq(hook.pendingTithe(1, address(asset)), 0);
        assertEq(hook.totalPending(address(asset)), 0);
        uint256 managerTokens = asset.balanceOf(address(manager));
        assertEq(hook.redeemTithe(1, address(asset)), 0);
        assertEq(asset.balanceOf(address(manager)), managerTokens, "second redemption took backing twice");
        assertEq(asset.balanceOf(address(hook)), received);
        if (received != 0) {
            vm.prank(trader);
            assertEq(hook.claim(1, address(asset)), received);
        }
        assertEq(asset.balanceOf(alice), received);
        assertEq(hook.totalTithe(address(asset)), 0);
        vm.expectRevert(TitheHook.NothingToClaim.selector);
        hook.claim(1, address(asset));
    }
}
