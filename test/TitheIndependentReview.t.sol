// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Independent adversarial review tests (2026-10-16). Written by the review team, which did not
// implement TitheHook/TitheRouter, to probe three areas the implementation suite does not cover:
//   (1) claim/redeem executed inside a THIRD PARTY's PoolManager unlock (the isUnlocked branch),
//       plus unlockCallback spoofing from inside that foreign unlock;
//   (2) exact-output swaps at the maximum rate (9999 bps), where the gross-up is ~10000x the
//       AMM input, checking the fee is charged exactly and settles cleanly;
//   (3) the exact-output inverse-rounding identity as a through-swap property across rates:
//       the credited fee F on gross input G must satisfy floor(G*r/B) - 1 <= F <= floor(G*r/B),
//       i.e. the seat's take is the configured fraction of gross input within one wei.

import {
    TitheFixture,
    TitheHook,
    TitheRouter,
    PoolKey,
    Currency,
    SwapParams,
    ModifyLiquidityParams,
    TickMath,
    IHooks
} from "./helpers/TitheFixture.sol";
import {GenericRouter} from "./helpers/GenericRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// @dev A token that pays its recipient a bonus out of thin air during a transfer to the hook
///      (recipient-bonus / rebasing-in-transfer behavior). Used to test whether _collect's
///      balance-delta measurement assigns in-window donations to the collecting seat.
contract BonusToken is MockERC20 {
    address public bonusRecipient;
    uint256 public bonusAmount;

    constructor() MockERC20("Bonus token", "BONUS", 1_000_000 ether) {}

    function arm(address recipient, uint256 amount) external {
        bonusRecipient = recipient;
        bonusAmount = amount;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (to == bonusRecipient && from != address(0) && bonusAmount != 0) {
            uint256 bonus = bonusAmount;
            bonusAmount = 0;
            _mint(to, bonus);
        }
    }
}

/// @dev A third party that opens its own manager unlock and, inside the callback, drives the
///      hook's permissionless claim/redeem surface while the manager is already unlocked.
contract ForeignUnlocker is IUnlockCallback {
    IPoolManager public immutable manager;
    TitheHook public immutable hook;
    uint256 public claimed;
    uint256 public redeemedAgain;
    bool public nestedClaimReverted;
    bytes4 public nestedClaimError;
    bool public spoofedCallbackReverted;
    bytes4 public spoofError;

    constructor(IPoolManager manager_, TitheHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function run(uint256 seatId, address token) external {
        manager.unlock(abi.encode(seatId, token));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (uint256 seatId, address token) = abi.decode(data, (uint256, address));
        claimed = hook.claim(seatId, token);
        redeemedAgain = hook.redeemTithe(seatId, token);
        // A second claim inside the same foreign unlock must fail: the credit is gone.
        bool ok;
        bytes memory reason;
        (ok, reason) = address(hook).call(abi.encodeCall(hook.claim, (seatId, token)));
        nestedClaimReverted = !ok;
        nestedClaimError = reason.length >= 4 ? bytes4(reason) : bytes4(0);
        // The hook's own unlockCallback cannot be invoked by anyone but the manager, and the
        // manager will only call it for a hook-initiated unlock; a direct call must revert.
        bytes memory reason2;
        (ok, reason2) = address(hook).call(abi.encodeCall(hook.unlockCallback, (abi.encode(seatId, token))));
        spoofedCallbackReverted = !ok;
        spoofError = reason2.length >= 4 ? bytes4(reason2) : bytes4(0);
        return "";
    }
}

contract TitheIndependentReviewTest is TitheFixture {
    GenericRouter internal generic;

    function setUp() public override {
        super.setUp();
        generic = new GenericRouter(manager);
        vm.deal(address(generic), 2_000_000 ether);
        token.transfer(address(generic), 20_000 ether);
    }

    /// (1) Pending (deferred) tithe, claimed from inside an unrelated contract's unlock.
    function test_claimInsideForeignUnlockUsesUnlockedBranch() public {
        // Token-side-only liquidity: the ETH fee cannot be taken immediately, so it is deferred.
        lp.modify(key, ModifyLiquidityParams(-600, 0, 100_000 ether, bytes32(0)));
        _swap(true, -1 ether);
        uint256 fee = hook.pendingTithe(1, address(0));
        assertEq(fee, 0.0025 ether);
        assertEq(address(hook).balance, 0);

        ForeignUnlocker foreign = new ForeignUnlocker(manager, hook);
        uint256 aliceBefore = alice.balance;
        foreign.run(1, address(0));

        assertEq(foreign.claimed(), fee, "foreign-unlock claim paid the wrong amount");
        assertEq(alice.balance - aliceBefore, fee, "seat owner did not receive the claim");
        assertEq(foreign.redeemedAgain(), 0, "second redemption was not idempotent");
        assertTrue(foreign.nestedClaimReverted(), "second claim inside foreign unlock did not revert");
        assertEq(foreign.nestedClaimError(), TitheHook.NothingToClaim.selector);
        assertTrue(foreign.spoofedCallbackReverted(), "direct unlockCallback call did not revert");
        assertEq(foreign.spoofError(), TitheHook.OnlyPoolManager.selector);
        assertEq(hook.titheOf(1, address(0)), 0);
        _assertAccounting(1, key.currency0);
    }

    /// (2) Maximum-rate exact-output buy: fee is 9999x the AMM's input; gross is ~10000x.
    function test_exactOutputAtMaxRateChargesExactlyAndSettles() public {
        PoolKey memory hot = key;
        hot.tickSpacing = 120;
        hook.initializePool(hot, Q96, abi.encode(uint256(2), uint24(9999)));
        lp.modify(hot, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));

        (uint256 paid, uint256 received) = generic.swap(hot, SwapParams(true, 1 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(received, 1 ether);
        uint256 fee = hook.titheOf(2, address(0));
        uint256 ammInput = paid - fee;
        // Exact formula on the AMM's actual input, and the gross-consistency band.
        assertEq(fee, ammInput * 9999 / (10_000 - 9999), "fee != floor(x*r/(B-r))");
        assertLe(fee, paid * 9999 / 10_000, "fee exceeds r of gross");
        assertGe(fee, paid * 9999 / 10_000 - 1, "fee below r of gross by more than 1 wei");
        assertEq(manager.balanceOf(address(generic), hot.currency0.toId()), 0, "router holds claims");
        _assertAccounting(2, hot.currency0);
    }

    /// (3) Inverse-rounding band across rates and amounts, both directions (exact output).
    function test_exactOutputInverseRoundingBandAcrossRates() public {
        uint24[6] memory rates = [uint24(1), uint24(25), uint24(100), uint24(1000), uint24(5000), uint24(9999)];
        int24[6] memory spacings = [int24(120), int24(121), int24(122), int24(123), int24(124), int24(125)];
        for (uint256 i; i < rates.length; ++i) {
            PoolKey memory pool = key;
            pool.tickSpacing = spacings[i];
            hook.initializePool(pool, Q96, abi.encode(uint256(2), rates[i]));
            int24 range = spacings[i] * 5;
            lp.modify(pool, ModifyLiquidityParams(-range, range, 100_000 ether, bytes32(0)));
            // Cap the exact-output size at high rates so the gross stays payable by the router.
            uint256 out = rates[i] > 5000 ? 0.01 ether : 1 ether;
            uint256 creditBefore = hook.titheOf(2, address(0));
            (uint256 paid,) = generic.swap(pool, SwapParams(true, int256(out), TickMath.MIN_SQRT_PRICE + 1));
            uint256 fee = hook.titheOf(2, address(0)) - creditBefore;
            uint256 grossShare = paid * rates[i] / 10_000;
            assertLe(fee, grossShare, "fee above r of gross");
            assertGe(fee + 1, grossShare, "fee below r of gross by more than 1 wei");
            assertEq(fee, (paid - fee) * rates[i] / (10_000 - rates[i]), "fee != floor(x*r/(B-r))");
            assertEq(manager.balanceOf(address(generic), pool.currency0.toId()), 0, "router holds claims");
            _assertAccounting(2, pool.currency0);
        }
    }

    /// (4) Exact-input partial-fill cliff: with a dust consumption (price limit one tick away),
    ///     the swapper still pays the tithe on the FULL specified budget. At 9999 bps the seat
    ///     captures ~99.99% of the budget while the AMM consumes dust. A zero-consumption swap
    ///     reverts instead. This pins the discontinuity at x = 0.
    function test_exactInputDustFillPaysFullBudgetTithe() public {
        PoolKey memory cliff = key;
        cliff.tickSpacing = 126;
        hook.initializePool(cliff, Q96, abi.encode(uint256(2), uint24(9999)));
        lp.modify(cliff, ModifyLiquidityParams(-630, 630, 1 ether, bytes32(0)));

        uint256 budget = 10 ether;
        uint256 expectedFee = budget * 9999 / 10_000;
        (uint256 paid, uint256 received) =
            generic.swap(cliff, SwapParams(true, -int256(budget), TickMath.getSqrtPriceAtTick(-1)));
        assertGt(received, 0, "dust fill produced nothing");
        assertLt(paid, budget, "fill was not partial");
        assertEq(hook.titheOf(2, address(0)), expectedFee, "seat did not capture the full budget tithe");
        // The AMM consumed less than 0.1% of the budget; the rest of what the swapper paid
        // is tithe, so the effective tithe rate on the amount paid is above 99.9%.
        assertLt(paid - expectedFee, budget / 1000, "AMM consumption was not dust");
        _assertAccounting(2, cliff.currency0);

        // The other side of the cliff: on a pool with no liquidity the AMM consumes nothing
        // and the swap reverts (SwapNotFilled) rather than charging.
        PoolKey memory empty = key;
        empty.tickSpacing = 127;
        hook.initializePool(empty, Q96, abi.encode(uint256(2), uint24(9999)));
        vm.expectRevert();
        generic.swap(empty, SwapParams(true, -int256(budget), TickMath.MIN_SQRT_PRICE + 1));
        assertEq(hook.titheOf(2, address(0)), expectedFee, "reverted swap left a charge behind");
    }

    /// (5) A token that donates to the hook DURING the manager->hook take window: the bonus is
    ///     measured as part of the collection and credited to the collecting seat, rather than
    ///     remaining unassigned surplus. Solvency is preserved (the credit is backed 1:1), but
    ///     the surplus-isolation absolute does not hold inside the measurement window.
    function test_bonusDuringTakeWindowIsCreditedToSeat() public {
        BonusToken bonus = new BonusToken();
        PoolKey memory pool = key;
        pool.currency1 = Currency.wrap(address(bonus));
        manager.initialize(pool, Q96);
        bonus.transfer(address(lp), 10_000 ether);
        lp.modify(pool, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        bonus.transfer(trader, 10 ether);

        uint256 fee = 1 ether * 25 / 10_000;
        bonus.arm(address(hook), fee); // in-window donation equal to the fee itself
        TitheRouter.SwapRequest memory request = _request(false, -1 ether);
        request.key = pool;
        vm.startPrank(trader);
        bonus.approve(address(router), 1 ether);
        router.swap(request);
        vm.stopPrank();

        // Credited is fee + in-window bonus, all assigned to seat 1, and fully backed.
        assertEq(hook.titheOf(1, address(bonus)), fee * 2, "in-window bonus was not credited to the seat");
        assertEq(bonus.balanceOf(address(hook)), fee * 2, "credit is not backed by the hook balance");
        _assertAccounting(1, pool.currency1);
    }
}
