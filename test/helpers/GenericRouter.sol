// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Test-only stand-in for a canonical v4 integrator (V4Router / Universal Router
///      SWAP -> SETTLE_ALL -> TAKE_ALL): prefunded, pays exactly its reported currency delta,
///      takes exactly its reported output and never reads, burns or mints ERC-6909 claims.
contract GenericRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (uint256 paid, uint256 received) {
        return abi.decode(manager.unlock(abi.encode(key, params)), (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        manager.swap(key, params, "");
        // SETTLE_ALL: pay the whole debt the manager reports, whatever the swap returned.
        uint256 paid = uint256(-manager.currencyDelta(address(this), inputCurrency));
        manager.sync(inputCurrency);
        if (inputCurrency.isAddressZero()) {
            manager.settle{value: paid}();
        } else {
            inputCurrency.transfer(address(manager), paid);
            manager.settle();
        }
        // TAKE_ALL
        uint256 received = uint256(manager.currencyDelta(address(this), outputCurrency));
        if (received != 0) manager.take(outputCurrency, address(this), received);
        return abi.encode(paid, received);
    }

    receive() external payable {}
}
