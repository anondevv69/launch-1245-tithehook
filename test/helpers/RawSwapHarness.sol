// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TitheHook} from "../../src/TitheHook.sol";

/// @dev Test-only prefunded raw v4 integration: supports partial exact output and multiple swaps/unlock.
contract RawSwapHarness is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData, uint256 count)
        external
        returns (uint256 input, uint256 output)
    {
        return abi.decode(
            manager.unlock(abi.encode(uint8(0), abi.encode(key, params, hookData, count))), (uint256, uint256)
        );
    }

    function redeem(TitheHook hook, uint256 seatId, address token) external {
        manager.unlock(abi.encode(uint8(1), abi.encode(hook, seatId, token)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == 1) {
            (TitheHook hook, uint256 seatId, address token) = abi.decode(payload, (TitheHook, uint256, address));
            hook.redeemTithe(seatId, token);
            return "";
        }
        (PoolKey memory key, SwapParams memory params, bytes memory hookData, uint256 count) =
            abi.decode(payload, (PoolKey, SwapParams, bytes, uint256));
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        uint256 totalInput;
        uint256 totalOutput;
        for (uint256 i; i < count; ++i) {
            BalanceDelta delta = manager.swap(key, params, hookData);
            uint256 input = uint256(-int256(params.zeroForOne ? delta.amount0() : delta.amount1()));
            uint256 output = uint256(int256(params.zeroForOne ? delta.amount1() : delta.amount0()));
            manager.sync(inputCurrency);
            if (inputCurrency.isAddressZero()) {
                manager.settle{value: input}();
            } else {
                inputCurrency.transfer(address(manager), input);
                manager.settle();
            }
            if (output != 0) manager.take(outputCurrency, address(this), output);
            totalInput += input;
            totalOutput += output;
        }
        return abi.encode(totalInput, totalOutput);
    }

    receive() external payable {}
}
