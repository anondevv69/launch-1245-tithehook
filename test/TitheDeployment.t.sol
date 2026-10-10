// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TitheFixture,
    TitheHook,
    TitheRouter,
    PoolKey,
    Currency,
    SwapParams,
    BalanceDelta,
    HookFlags
} from "./helpers/TitheFixture.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract UnsettledSwap is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function attempt(PoolKey memory key, SwapParams memory params) external {
        manager.unlock(abi.encode(key, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        manager.swap(key, params, "");
        return ""; // Deliberately leave the swapper's debt unpaid.
    }
}

contract TitheDeploymentTest is TitheFixture {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    function test_runtimeHasNoProxyOrDestructionOpcodes() public view {
        _scan(address(hook));
        _scan(address(token));
        _scan(address(router));
    }

    function _scan(address deployed) internal view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    function test_constructorDoesNotCallDependencies() public {
        vm.etch(address(manager), "");
        vm.etch(address(seat), "");
        TitheHook deployed = _deployHook(1, 26);
        assertEq(address(deployed.poolManager()), address(manager));
        assertEq(address(deployed.IMD_SEAT()), address(seat));
        TitheRouter deployedRouter = new TitheRouter(manager, deployed);
        assertEq(address(deployedRouter.hook()), address(deployed));
    }

    function test_constructorRejectsInvalidParametersAndFlags() public {
        vm.expectRevert(TitheHook.InvalidAddress.selector);
        new TitheHook(IPoolManager(address(0)), seat, 1, 25);
        vm.expectRevert(TitheHook.InvalidAddress.selector);
        new TitheHook(manager, IERC721(address(0)), 1, 25);
        vm.expectRevert(TitheHook.InvalidTitheBps.selector);
        new TitheHook(manager, seat, 1, 10000);
        vm.expectRevert(TitheHook.InvalidTitheBps.selector);
        new TitheHook(manager, seat, 1, 0);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertFalse(HookFlags.matches(predicted, HookFlags.TITHE));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new TitheHook(manager, seat, 1, 25);
    }

    function test_unsettledSwapCannotCreateUnbackedCredits() public {
        _seed();
        UnsettledSwap attacker = new UnsettledSwap(manager);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        attacker.attempt(key, SwapParams(true, -1 ether, Q96 / 2));
        assertEq(hook.totalTithe(address(0)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_nonexistentPoolAndExtremeAmountsFailExplicitly() public {
        PoolKey memory unknown = key;
        unknown.tickSpacing = 120;
        vm.prank(address(manager));
        vm.expectRevert(TitheHook.PoolNotConfigured.selector);
        hook.beforeSwap(address(this), unknown, SwapParams(true, -1 ether, Q96 / 2), "");
        int256[4] memory invalid = [int256(0), type(int256).min, type(int256).max, int256(type(int128).max) + 1];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(address(manager));
            vm.expectRevert(TitheHook.InvalidSwapAmount.selector);
            hook.beforeSwap(address(this), key, SwapParams(true, invalid[i], Q96 / 2), "");
        }
    }

    function testFuzz_reservationNeverConsumesWholeSwap(uint128 inputSeed, uint24 bpsSeed) public {
        uint256 amount = bound(inputSeed, 1, uint256(uint128(type(int128).max)));
        uint24 bps = uint24(bound(bpsSeed, 1, 9999));
        PoolKey memory second = key;
        second.tickSpacing = 120;
        hook.initializePool(second, Q96, abi.encode(uint256(1), bps));
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpOverride) =
            hook.beforeSwap(address(this), second, SwapParams(true, -int256(amount), Q96 / 2), "");
        assertEq(selector, hook.beforeSwap.selector);
        assertEq(lpOverride, 0);
        assertEq(delta.getUnspecifiedDelta(), 0);
        assertEq(uint256(int256(delta.getSpecifiedDelta())), amount * bps / 10000);
        assertLt(uint256(int256(delta.getSpecifiedDelta())), amount);
    }
}
