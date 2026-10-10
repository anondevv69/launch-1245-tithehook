// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {
    TitheFixture,
    TitheHook,
    TitheRouter,
    TitheToken,
    MockSeat,
    PoolKey,
    Currency,
    SwapParams,
    ModifyLiquidityParams,
    TickMath
} from "./helpers/TitheFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {ClaimDonationHarness, ForcedTitheDonation} from "./helpers/ClaimDonationHarness.sol";

/// @dev Ghost accrual comes from actual trader debits, never from totalTithe changes.
contract TitheLifecycleHandler is Test {
    using StateLibrary for IPoolManager;

    TitheHook public immutable hook;
    TitheRouter public immutable router;
    TitheToken public immutable token;
    MockSeat public immutable seat;
    IPoolManager public immutable manager;
    ClaimDonationHarness public immutable donor;
    address public immutable alice;
    address public immutable bob;
    PoolKey[3] private keys;
    uint24[3] private rates = [uint24(25), 9999, 1];
    uint256[3] private seats = [uint256(1), 2, 1];

    mapping(uint256 => mapping(address => uint256)) public earned;
    mapping(uint256 => mapping(address => uint256)) public paid;
    mapping(address => uint256) public liquidSurplus;
    mapping(address => uint256) public claimSurplus;
    mapping(address => uint256) public routerClaimSurplus;
    uint256 public swaps;
    uint256 public partialFills;
    uint256 public redemptions;
    uint256 public payouts;
    uint256 public rejectedSwaps;

    constructor(
        TitheHook hook_,
        TitheRouter router_,
        TitheToken token_,
        MockSeat seat_,
        PoolKey[3] memory keys_,
        address alice_,
        address bob_
    ) {
        hook = hook_;
        router = router_;
        token = token_;
        seat = seat_;
        manager = hook_.poolManager();
        donor = new ClaimDonationHarness(manager);
        keys = keys_;
        alice = alice_;
        bob = bob_;
        token.approve(address(router), type(uint256).max);
    }

    function swap(uint8 poolSeed, uint96 amountSeed, bool buy, bool exactInput, bool priceBound) public {
        uint256 index = poolSeed % 3;
        PoolKey memory pool = keys[index];
        uint256 amount = bound(amountSeed, 1e8, 1e16);
        uint160 limit = buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (priceBound && exactInput) {
            amount = bound(amountSeed, 20 ether, 30 ether);
            (, int24 tick,,) = manager.getSlot0(pool.toId());
            limit = TickMath.getSqrtPriceAtTick(tick + (buy ? int24(-2) : int24(2)));
        }
        TitheRouter.SwapRequest memory request = TitheRouter.SwapRequest({
            key: pool,
            params: SwapParams(buy, exactInput ? -int256(amount) : int256(amount), limit),
            maxInput: exactInput ? amount + 101 : amount * 20_000,
            minOutput: 1,
            deadline: block.timestamp
        });
        Currency inputAsset = buy ? pool.currency0 : pool.currency1;
        Currency outputAsset = buy ? pool.currency1 : pool.currency0;
        uint256 beforeInput = inputAsset.balanceOf(address(this));
        uint256 beforeOutput = outputAsset.balanceOf(address(this));
        (uint256 input, uint256 output) = router.swap{value: buy ? request.maxInput : 0}(request);
        uint256 spent = beforeInput - inputAsset.balanceOf(address(this));
        assertEq(input, spent, "router reports a different amount than the trader spent");
        assertEq(output, outputAsset.balanceOf(address(this)) - beforeOutput, "output was not delivered");
        assertGt(output, 0);
        assertLe(input, request.maxInput);
        // Exact input: the tithe is the pool's rate on the specified budget, whether or not the AMM
        // consumed all of the rest. Exact output: it is the rate on the gross input actually spent.
        uint256 fee = (exactInput ? amount : spent) * rates[index] / 10_000;
        if (exactInput) {
            assertLe(input, amount);
            assertGt(input, fee, "the swapper paid only the tithe: the AMM consumed nothing");
            if (input < amount) partialFills++;
        } else {
            assertEq(output, amount);
        }
        earned[seats[index]][Currency.unwrap(inputAsset)] += fee;
        swaps++;
    }

    function claim(uint8 seatSeed, bool native) public {
        uint256 seatId = seatSeed % 2 + 1;
        address asset = native ? address(0) : address(token);
        uint256 expected = earned[seatId][asset] - paid[seatId][asset];
        address owner = seat.ownerOf(seatId);
        uint256 beforeOwner = Currency.wrap(asset).balanceOf(owner);
        uint256 beforeCaller = Currency.wrap(asset).balanceOf(address(this));
        if (expected == 0) {
            vm.expectRevert(TitheHook.NothingToClaim.selector);
            hook.claim(seatId, asset);
        } else {
            assertEq(hook.claim(seatId, asset), expected);
            paid[seatId][asset] += expected;
            assertEq(Currency.wrap(asset).balanceOf(owner) - beforeOwner, expected, "claim missed current owner");
            payouts++;
        }
        assertEq(Currency.wrap(asset).balanceOf(address(this)), beforeCaller, "caller received a claim bounty");
    }

    function redeem(uint8 seatSeed, bool native) public {
        uint256 seatId = seatSeed % 2 + 1;
        address asset = native ? address(0) : address(token);
        uint256 pending = hook.pendingTithe(seatId, asset);
        assertEq(hook.redeemTithe(seatId, asset), pending);
        assertEq(hook.titheOf(seatId, asset), earned[seatId][asset] - paid[seatId][asset]);
        if (pending != 0) redemptions++;
    }

    function transferSeat(uint8 seatSeed) public {
        uint256 seatId = seatSeed % 2 + 1;
        address owner = seat.ownerOf(seatId);
        vm.prank(owner);
        seat.transferFrom(owner, owner == alice ? bob : alice, seatId);
    }

    function donate(uint96 amountSeed, bool native, uint8 kindSeed) public {
        uint256 amount = bound(amountSeed, 1, 1e12);
        address asset = native ? address(0) : address(token);
        uint256 kind = kindSeed % 3;
        if (kind == 0) {
            if (native) new ForcedTitheDonation{value: amount}(payable(address(hook)));
            else token.transfer(address(hook), amount);
            liquidSurplus[asset] += amount;
        } else {
            if (!native) token.transfer(address(donor), amount);
            donor.donate{value: native ? amount : 0}(
                Currency.wrap(asset), kind == 1 ? address(hook) : address(router), amount
            );
            if (kind == 1) claimSurplus[asset] += amount;
            else routerClaimSurplus[asset] += amount;
        }
    }

    function rejectSwap(bool buy, bool exactInput) public {
        TitheRouter.SwapRequest memory request = TitheRouter.SwapRequest({
            key: keys[0],
            params: SwapParams(
                buy,
                exactInput ? -int256(1 ether) : int256(1 ether),
                buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            maxInput: 2 ether,
            minOutput: type(uint128).max,
            deadline: block.timestamp
        });
        (uint160 beforePrice,,,) = manager.getSlot0(keys[0].toId());
        uint256 beforeEth = address(this).balance;
        uint256 beforeToken = token.balanceOf(address(this));
        vm.expectRevert(TitheRouter.Slippage.selector);
        router.swap{value: buy ? request.maxInput : 0}(request);
        (uint160 afterPrice,,,) = manager.getSlot0(keys[0].toId());
        assertEq(afterPrice, beforePrice, "failed swap moved price");
        assertEq(address(this).balance, beforeEth);
        assertEq(token.balanceOf(address(this)), beforeToken);
        rejectedSwaps++;
    }

    receive() external payable {}
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TitheLifecycleInvariantTest is StdInvariant, TitheFixture {
    using TransientStateLibrary for IPoolManager;
    TitheLifecycleHandler internal lifecycle;
    PoolKey[3] private keys;

    function setUp() public override {
        super.setUp();
        keys[0] = key;
        keys[1] = key;
        keys[1].tickSpacing = 120;
        hook.initializePool(keys[1], Q96, abi.encode(uint256(2), uint24(9999)));
        keys[2] = key;
        keys[2].fee = 3000;
        hook.initializePool(keys[2], Q96, abi.encode(uint256(1), uint24(1)));
        lifecycle = new TitheLifecycleHandler(hook, router, token, seat, keys, alice, bob);
        vm.deal(address(lifecycle), 1_000_000 ether);
        token.transfer(address(lifecycle), 1_000_000 ether);

        // Genuine first-buy deferral, before any ETH reaches the fresh manager.
        lp.modify(key, ModifyLiquidityParams(-600, 0, 100_000 ether, bytes32("token-only")));
        assertEq(address(manager).balance, 0);
        lifecycle.swap(0, 1e16, true, true, false);
        assertGt(hook.pendingTithe(1, address(0)), 0);
        // Leave that pending balance outstanding when the random sequences begin.
        for (uint256 i; i < 3; ++i) {
            lp.modify(keys[i], ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        }
        // Pin nonvacuity of extreme-rate, partial-fill and rejected-swap branches.
        lifecycle.swap(1, 1e16, false, false, false);
        lifecycle.swap(2, 20 ether, true, true, true);
        lifecycle.rejectSwap(false, true);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = lifecycle.swap.selector;
        selectors[1] = lifecycle.claim.selector;
        selectors[2] = lifecycle.redeem.selector;
        selectors[3] = lifecycle.transferSeat.selector;
        selectors[4] = lifecycle.donate.selector;
        selectors[5] = lifecycle.rejectSwap.selector;
        targetContract(address(lifecycle));
        targetSelector(FuzzSelector(address(lifecycle), selectors));
    }

    function invariant_seatCreditsEqualIndependentlyEarnedLessPaid() public view {
        for (uint256 i; i < 2; ++i) {
            address asset = i == 0 ? address(0) : address(token);
            uint256 sum;
            uint256 sumPaid;
            for (uint256 id = 1; id <= 2; ++id) {
                uint256 expected = lifecycle.earned(id, asset) - lifecycle.paid(id, asset);
                assertEq(hook.titheOf(id, asset), expected);
                assertEq(hook.tithe(id, asset) + hook.pendingTithe(id, asset), expected);
                sum += expected;
                sumPaid += lifecycle.paid(id, asset);
            }
            assertEq(hook.totalTithe(asset), sum);
            assertEq(Currency.wrap(asset).balanceOf(alice) + Currency.wrap(asset).balanceOf(bob), sumPaid);
        }
        assertGe(lifecycle.swaps(), 3);
        assertGt(lifecycle.partialFills(), 0);
        assertGt(lifecycle.rejectedSwaps(), 0);
    }

    function invariant_liquidAndPendingBackingAndSurplusRemainSeparate() public view {
        for (uint256 i; i < 2; ++i) {
            Currency currency = i == 0 ? key.currency0 : key.currency1;
            address asset = Currency.unwrap(currency);
            uint256 liquid = hook.tithe(1, asset) + hook.tithe(2, asset);
            uint256 pending = hook.pendingTithe(1, asset) + hook.pendingTithe(2, asset);
            assertEq(currency.balanceOf(address(hook)), liquid + lifecycle.liquidSurplus(asset));
            assertEq(manager.balanceOf(address(hook), currency.toId()), pending + lifecycle.claimSurplus(asset));
            assertEq(hook.totalPending(asset), pending);
            assertEq(currency.balanceOf(address(router)), 0);
            assertEq(manager.balanceOf(address(router), currency.toId()), lifecycle.routerClaimSurplus(asset));
            assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), currency), 0);
            assertEq(IPoolManager(address(manager)).currencyDelta(address(router), currency), 0);
        }
        assertFalse(IPoolManager(address(manager)).isUnlocked());
    }

    function invariant_supplyAndPoolBindingsCannotChange() public view {
        uint256 tracked = token.balanceOf(address(this)) + token.balanceOf(address(lp)) + token.balanceOf(trader)
            + token.balanceOf(address(lifecycle)) + token.balanceOf(address(lifecycle.donor()))
            + token.balanceOf(address(manager)) + token.balanceOf(address(hook)) + token.balanceOf(address(router))
            + token.balanceOf(alice) + token.balanceOf(bob);
        assertEq(token.totalSupply(), 1e27);
        assertEq(tracked, 1e27);
        for (uint256 i; i < 3; ++i) {
            (uint256 id, uint24 bps, bool initialized) = hook.poolConfig(keys[i].toId());
            assertTrue(initialized);
            assertEq(id, i == 1 ? 2 : 1);
            assertEq(bps, i == 0 ? 25 : i == 1 ? 9999 : 1);
        }
    }

    /// @dev At the end of every sequence, every outstanding standard-asset credit is payable.
    function afterInvariant() public {
        for (uint8 id; id < 2; ++id) {
            lifecycle.claim(id, true);
            lifecycle.claim(id, false);
        }
        assertEq(hook.totalTithe(address(0)), 0);
        assertEq(hook.totalTithe(address(token)), 0);
        invariant_liquidAndPendingBackingAndSurplusRemainSeparate();
        invariant_seatCreditsEqualIndependentlyEarnedLessPaid();
    }
}
