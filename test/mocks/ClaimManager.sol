// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TitheHook} from "../../src/TitheHook.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev Accounting-only harness for aggregate uint256 claim balances above v4's per-call int128 cap.
///      AMM behavior is tested separately against the real PoolManager.
contract ClaimManager {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    bool private unlocked;

    function initializeHook(TitheHook hook, PoolKey memory key) external {
        hook.beforeInitialize(msg.sender, key, 1);
    }

    function accrue(TitheHook hook, PoolKey memory key, SwapParams memory params, BalanceDelta delta) external {
        unlocked = true;
        hook.afterSwap(msg.sender, key, params, delta, "");
        unlocked = false;
    }

    function exttload(bytes32) external view returns (bytes32) {
        return unlocked ? bytes32(uint256(1)) : bytes32(0);
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!unlocked);
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        require(unlocked && amount <= uint256(uint128(type(int128).max)));
        balanceOf[to][id] += amount;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        require(unlocked && msg.sender == from && amount <= uint256(uint128(type(int128).max)));
        balanceOf[from][id] -= amount;
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(unlocked && amount <= uint256(uint128(type(int128).max)));
        currency.transfer(to, amount);
    }
}
