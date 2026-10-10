// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TitheFixture, TitheHook, Currency, SwapParams, IHooks, MockERC20} from "./helpers/TitheFixture.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ClaimManager} from "./mocks/ClaimManager.sol";

contract TitheLargeClaimsTest is TitheFixture {
    function test_largeAggregateRedeemsInChunksThenClaimsFullBalance() public {
        ClaimManager harness = new ClaimManager();
        manager = PoolManager(address(harness));
        hook = _deployHook(1, 7500);
        MockERC20 asset = new MockERC20("Large supply", "LARGE", 0);
        key.hooks = IHooks(address(hook));
        key.currency1 = Currency.wrap(address(asset));
        harness.initializeHook(hook, key);
        int128 coreInput = type(int128).max / 4;
        for (uint256 i; i < 2; ++i) {
            harness.accrue(hook, key, SwapParams(false, 1, type(uint160).max), toBalanceDelta(1, -coreInput));
        }
        uint256 amount = uint256(int256(coreInput)) * 6;
        assertEq(hook.pendingTithe(1, address(asset)), amount);
        asset.mint(address(harness), amount);
        vm.expectRevert(TitheHook.RedeemPendingFirst.selector);
        hook.claim(1, address(asset));
        assertEq(hook.pendingTithe(1, address(asset)), amount);
        assertEq(hook.redeemTithe(1, address(asset)), uint256(uint128(type(int128).max)));
        assertGt(hook.pendingTithe(1, address(asset)), 0);
        // claim now redeems the remaining chunk and pays all liquid and redeemed credit.
        assertEq(hook.claim(1, address(asset)), amount);
        assertEq(asset.balanceOf(alice), amount);
        assertEq(hook.totalTithe(address(asset)), 0);
        assertEq(harness.balanceOf(address(hook), uint160(address(asset))), 0);
    }
}
