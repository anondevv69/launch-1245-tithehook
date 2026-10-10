// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TitheHook} from "./TitheHook.sol";

/// @notice Single-hop reference router for Tithe pools: pays exactly the manager's reported debt.
/// @dev Pulls funds only from msg.sender, before unlocking; no approvals or arbitrary payer in callbacks.
///      Any router that settles its full currency delta (SETTLE_ALL) integrates the same way.
contract TitheRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct SwapRequest {
        PoolKey key;
        SwapParams params;
        uint256 maxInput;
        uint256 minOutput;
        uint256 deadline;
    }

    IPoolManager public immutable poolManager;
    TitheHook public immutable hook;
    bool private _swapping;

    error InvalidAddress();
    error InvalidRequest();
    error Expired();
    error InvalidValue();
    error OnlyPoolManager();
    error UnexpectedUnlock();
    error TransferTaxNotSupported();
    error Slippage();

    event Swapped(address indexed trader, bytes32 indexed poolId, bool zeroForOne, uint256 input, uint256 output);

    constructor(IPoolManager manager, TitheHook hook_) {
        if (address(manager) == address(0) || address(hook_) == address(0)) revert InvalidAddress();
        poolManager = manager;
        hook = hook_;
    }

    /// @notice Exact input is a maximum budget including tithe; exact output must fill completely.
    /// @dev Refunds input and sends output to the caller. ERC-20 approvals are to this router.
    function swap(SwapRequest calldata request) external payable nonReentrant returns (uint256 input, uint256 output) {
        if (block.timestamp > request.deadline) revert Expired();
        if (
            address(request.key.hooks) != address(hook) || address(hook.poolManager()) != address(poolManager)
                || request.maxInput == 0 || request.maxInput > uint256(uint128(type(int128).max))
                || request.minOutput == 0 || request.params.amountSpecified == 0
                || request.params.amountSpecified < -int256(request.maxInput)
                || request.params.amountSpecified > type(int128).max
        ) revert InvalidRequest();

        Currency inputCurrency = request.params.zeroForOne ? request.key.currency0 : request.key.currency1;
        Currency outputCurrency = request.params.zeroForOne ? request.key.currency1 : request.key.currency0;
        if (inputCurrency.isAddressZero()) {
            if (msg.value != request.maxInput) revert InvalidValue();
        } else {
            if (msg.value != 0) revert InvalidValue();
            uint256 beforeBalance = inputCurrency.balanceOfSelf();
            IERC20(Currency.unwrap(inputCurrency)).safeTransferFrom(msg.sender, address(this), request.maxInput);
            if (inputCurrency.balanceOfSelf() - beforeBalance != request.maxInput) revert TransferTaxNotSupported();
        }

        _swapping = true;
        (input, output) = abi.decode(poolManager.unlock(abi.encode(request)), (uint256, uint256));
        uint256 beforeOutput = outputCurrency.balanceOf(msg.sender);
        outputCurrency.transfer(msg.sender, output);
        output = outputCurrency.balanceOf(msg.sender) - beforeOutput;
        if (
            output < request.minOutput
                || (request.params.amountSpecified > 0 && output < uint256(request.params.amountSpecified))
        ) revert Slippage();
        uint256 refund = request.maxInput - input;
        if (refund != 0) inputCurrency.transfer(msg.sender, refund);
        emit Swapped(msg.sender, PoolId.unwrap(request.key.toId()), request.params.zeroForOne, input, output);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (!_swapping) revert UnexpectedUnlock();
        _swapping = false;
        SwapRequest memory request = abi.decode(data, (SwapRequest));
        Currency inputCurrency = request.params.zeroForOne ? request.key.currency0 : request.key.currency1;
        Currency outputCurrency = request.params.zeroForOne ? request.key.currency1 : request.key.currency0;
        BalanceDelta delta = poolManager.swap(request.key, request.params, "");

        int128 inputDelta = request.params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = request.params.zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta > 0 || outputDelta < 0) revert InvalidRequest();
        uint256 input = uint256(-int256(inputDelta));
        if (input > request.maxInput) revert Slippage();
        // settle native after sync too: another hook may have left an ERC-20 currency synced.
        poolManager.sync(inputCurrency);
        if (inputCurrency.isAddressZero()) {
            if (poolManager.settle{value: input}() != input) revert InvalidValue();
        } else {
            inputCurrency.transfer(address(poolManager), input);
            if (poolManager.settle() != input) revert TransferTaxNotSupported();
        }
        uint256 beforeOutput = outputCurrency.balanceOfSelf();
        if (outputDelta != 0) poolManager.take(outputCurrency, address(this), uint128(outputDelta));
        uint256 output = outputCurrency.balanceOfSelf() - beforeOutput;
        return abi.encode(input, output);
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
    }
}
