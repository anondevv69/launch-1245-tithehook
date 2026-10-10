// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TitheFixture,
    TitheHook,
    PoolKey,
    Currency,
    SwapParams,
    ModifyLiquidityParams,
    TickMath,
    IHooks
} from "./helpers/TitheFixture.sol";
import {GenericRouter} from "./helpers/GenericRouter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice A canonical SETTLE_ALL / TAKE_ALL integrator must pay exactly `AMM input + tithe` and end
///         every swap with no ERC-6909 claims, whether the AMM fills the budget fully or partially.
contract TitheGenericRouterTest is TitheFixture {
    using TransientStateLibrary for IPoolManager;

    GenericRouter internal generic;

    function setUp() public override {
        super.setUp();
        generic = new GenericRouter(manager);
        vm.deal(address(generic), 10_000 ether);
        token.transfer(address(generic), 10_000 ether);
    }

    function _assertNothingStranded(Currency currency, uint256 seatId) internal view {
        assertEq(manager.balanceOf(address(generic), currency.toId()), 0, "router holds claims");
        assertEq(IPoolManager(address(manager)).currencyDelta(address(generic), currency), 0);
        _assertAccounting(seatId, currency);
    }

    /// @dev The independent review's scenario: 100e18 liquidity in [-600, 600], a 500 ETH budget at
    ///      the Universal Router's default price limit. The AMM consumes ~3.08 ETH of the budget.
    function test_partialExactInputBuyPaysAmmInputPlusTitheOnly() public {
        lp.modify(key, ModifyLiquidityParams(-600, 600, 100 ether, bytes32(0)));
        uint256 budget = 500 ether;
        uint256 fee = budget * 25 / 10000;
        uint256 managerEthBefore = address(manager).balance;
        (uint256 paid, uint256 received) =
            generic.swap(key, SwapParams(true, -int256(budget), TickMath.MIN_SQRT_PRICE + 1));
        assertGt(received, 0);
        assertLt(paid, budget);
        // Everything the router paid is either in the pool or credited to the seat: nothing stranded.
        uint256 ammInput = address(manager).balance - managerEthBefore;
        assertEq(paid, ammInput + fee, "router overpaid");
        assertEq(hook.titheOf(1, address(0)), fee);
        assertEq(address(hook).balance, fee);
        _assertNothingStranded(key.currency0, 1);
    }

    function test_partialExactInputSellAtPriceBoundStrandsNothing() public {
        _seed();
        uint256 budget = 100 ether;
        uint256 fee = budget * 25 / 10000;
        uint256 managerTokensBefore = token.balanceOf(address(manager));
        (uint256 paid,) = generic.swap(key, SwapParams(false, -int256(budget), TickMath.getSqrtPriceAtTick(2)));
        assertLt(paid, budget);
        assertEq(paid, token.balanceOf(address(manager)) - managerTokensBefore + fee);
        assertEq(hook.titheOf(1, address(token)), fee);
        assertEq(token.balanceOf(address(hook)), fee);
        _assertNothingStranded(key.currency1, 1);
    }

    function test_fullExactInputFillMatchesReferenceRouter() public {
        _seed();
        (uint256 paid, uint256 received) = generic.swap(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(paid, 1 ether);
        assertGt(received, 0);
        assertEq(hook.titheOf(1, address(0)), 1 ether * 25 / 10000);
        _assertNothingStranded(key.currency0, 1);
    }

    function test_exactOutputBuyAndSellStrandNothing() public {
        _seed();
        (uint256 paidEth,) = generic.swap(key, SwapParams(true, 1 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(hook.titheOf(1, address(0)), paidEth * 25 / 10000);
        _assertNothingStranded(key.currency0, 1);
        (uint256 paidTokens,) = generic.swap(key, SwapParams(false, 1 ether, TickMath.MAX_SQRT_PRICE - 1));
        assertEq(hook.titheOf(1, address(token)), paidTokens * 25 / 10000);
        _assertNothingStranded(key.currency1, 1);
    }

    /// @dev Fresh manager, tokens only: the ETH tithe is deferred as the hook's own claim, and a
    ///      partial fill still leaves the router with none.
    function test_freshManagerTokenOnlyPartialBuyDefersTitheWithoutStranding() public {
        lp.modify(key, ModifyLiquidityParams(-600, 0, 100 ether, bytes32(0)));
        assertEq(address(manager).balance, 0);
        uint256 budget = 500 ether;
        uint256 fee = budget * 25 / 10000;
        (uint256 paid, uint256 received) =
            generic.swap(key, SwapParams(true, -int256(budget), TickMath.MIN_SQRT_PRICE + 1));
        assertGt(received, 0);
        assertLt(paid, budget);
        assertEq(paid, address(manager).balance, "manager holds AMM input plus the deferred tithe");
        assertEq(hook.pendingTithe(1, address(0)), fee);
        assertEq(address(hook).balance, 0);
        _assertNothingStranded(key.currency0, 1);
        vm.prank(bob);
        hook.claim(1, address(0));
        assertEq(alice.balance, fee);
        _assertNothingStranded(key.currency0, 1);
    }

    /// @dev Reference router (TitheRouter) and generic router agree on a partial fill.
    function test_referenceRouterAgreesWithGenericRouterOnPartialFill() public {
        lp.modify(key, ModifyLiquidityParams(-600, 600, 100 ether, bytes32(0)));
        uint256 snapshot = vm.snapshotState();
        (uint256 genericPaid, uint256 genericReceived) =
            generic.swap(key, SwapParams(true, -500 ether, TickMath.MIN_SQRT_PRICE + 1));
        vm.revertToState(snapshot);
        (uint256 referencePaid, uint256 referenceReceived) = _swap(true, -500 ether);
        assertEq(referencePaid, genericPaid);
        assertEq(referenceReceived, genericReceived);
        assertEq(manager.balanceOf(address(router), 0), 0);
    }

    /// @dev Without the refund channel, a fill that consumes nothing cannot be tithed: it reverts.
    function test_exactInputWithNoLiquidityRevertsInsteadOfCharging() public {
        PoolKey memory empty = key;
        empty.tickSpacing = 120;
        hook.initializePool(empty, Q96, abi.encode(uint256(1), uint24(25)));
        vm.expectRevert();
        generic.swap(empty, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(hook.totalTithe(address(0)), 0);
        assertEq(manager.balanceOf(address(generic), 0), 0);
    }
}
