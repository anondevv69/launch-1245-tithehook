// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TitheHook} from "../../src/TitheHook.sol";
import {TitheToken} from "../../src/TitheToken.sol";
import {TitheRouter} from "../../src/TitheRouter.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MockSeat} from "../mocks/MockSeat.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {LiquidityHarness} from "./LiquidityHarness.sol";

abstract contract TitheFixture is Test {
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant Q96 = 79228162514264337593543950336;
    PoolManager internal manager;
    MockSeat internal seat;
    TitheHook internal hook;
    TitheToken internal token;
    TitheRouter internal router;
    LiquidityHarness internal lp;
    PoolKey internal key;
    address internal alice;
    address internal bob;
    address internal trader;

    function setUp() public virtual {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        trader = makeAddr("trader");
        manager = new PoolManager(address(this));
        seat = new MockSeat();
        seat.mint(alice, 1);
        seat.mint(bob, 2);
        token = new TitheToken();
        hook = _deployHook(1, 25);
        router = new TitheRouter(manager, hook);
        lp = new LiquidityHarness(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(address(hook)));
        manager.initialize(key, Q96);
        vm.deal(address(this), 100_000 ether);
        vm.deal(address(lp), 50_000 ether);
        vm.deal(trader, 20_000 ether);
        token.transfer(address(lp), 50_000 ether);
        token.transfer(trader, 20_000 ether);
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    function _deployHook(uint256 seatId, uint24 bps) internal returns (TitheHook deployed) {
        bytes32 hash = keccak256(abi.encodePacked(type(TitheHook).creationCode, abi.encode(manager, seat, seatId, bps)));
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, hash)))));
            if (HookFlags.matches(predicted, HookFlags.TITHE)) {
                deployed = new TitheHook{salt: salt}(manager, seat, seatId, bps);
                assertEq(address(deployed), predicted);
                return deployed;
            }
        }
        revert("mining failed");
    }

    function _seed() internal {
        lp.modify(key, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
    }

    function _request(bool buy, int256 amount) internal view returns (TitheRouter.SwapRequest memory request) {
        request = TitheRouter.SwapRequest({
            key: key,
            params: SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            maxInput: amount < 0 ? uint256(-amount) : uint256(amount) * 2,
            minOutput: 1,
            deadline: block.timestamp
        });
    }

    function _swap(bool buy, int256 amount) internal returns (uint256 input, uint256 output) {
        TitheRouter.SwapRequest memory request = _request(buy, amount);
        vm.prank(trader);
        return router.swap{value: buy ? request.maxInput : 0}(request);
    }

    function _assertAccounting(uint256 seatId, Currency currency) internal view {
        address asset = Currency.unwrap(currency);
        assertEq(hook.titheOf(seatId, asset), hook.tithe(seatId, asset) + hook.pendingTithe(seatId, asset));
        assertEq(
            hook.totalTithe(asset),
            currency.balanceOf(address(hook)) + manager.balanceOf(address(hook), currency.toId())
        );
        assertEq(hook.totalPending(asset), manager.balanceOf(address(hook), currency.toId()));
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), currency), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(router), currency), 0);
        assertEq(manager.balanceOf(address(router), currency.toId()), 0);
    }

    receive() external payable {}
}
