// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Pay an identity seat, not a wallet. No administration or upgrade paths.
/// @dev Implements only the callbacks advertised by its address. See docs/ACCOUNTING.md
///      for exact-input reservations, partial-fill refunds and pending ERC-6909 backing.
contract TitheHook is IUnlockCallback, ReentrancyGuard {
    using TransientStateLibrary for IPoolManager;

    struct PoolConfig {
        uint256 seatId;
        uint24 titheBps;
        bool initialized;
    }

    uint256 public constant BPS = 10_000;
    IPoolManager public immutable poolManager;
    IERC721 public immutable IMD_SEAT;
    uint256 public immutable defaultSeatId;
    uint24 public immutable defaultTitheBps;

    mapping(PoolId => PoolConfig) public poolConfig;
    /// @notice Liquid credits only; titheOf additionally includes pending manager claims.
    mapping(uint256 seatId => mapping(address token => uint256)) public tithe;
    mapping(uint256 seatId => mapping(address token => uint256)) public pendingTithe;
    mapping(address token => uint256) public totalTithe;
    mapping(address token => uint256) public totalPending;

    bool private _redeeming;

    error OnlyPoolManager();
    error InvalidAddress();
    error InvalidTitheBps();
    error WrongHook();
    error AlreadyConfigured();
    error PoolNotConfigured();
    error InvalidHookData();
    error InvalidSwapAmount();
    error InvalidInputDelta();
    error NothingToClaim();
    error InvalidSeatOwner();
    error UnexpectedUnlock();
    error RedeemPendingFirst();

    event PoolConfigured(PoolId indexed poolId, uint256 indexed seatId, uint24 titheBps);
    event TitheAccrued(
        PoolId indexed poolId,
        uint256 indexed seatId,
        address indexed token,
        uint256 charged,
        uint256 credited,
        bool deferred
    );
    event InputRefund(address indexed router, address indexed token, uint256 amount);
    event TitheRedeemed(uint256 indexed seatId, address indexed token, uint256 nominal, uint256 received);
    event TitheClaimed(uint256 indexed seatId, address indexed token, address indexed recipient, uint256 amount);

    /// @param manager The launch chain's PoolManager; supplied by the deployment service.
    /// @param seat The canonical identity.md seat ERC-721 (immutable, never owner-settable).
    /// @param seatId Default for direct PoolManager initialization; demo fallback is seat 1.
    /// @param titheBps_ Default immutable cut of gross spent input; demo value is 25.
    constructor(IPoolManager manager, IERC721 seat, uint256 seatId, uint24 titheBps_) {
        if (address(manager) == address(0) || address(seat) == address(0)) revert InvalidAddress();
        _validateBps(titheBps_);
        poolManager = manager;
        IMD_SEAT = seat;
        defaultSeatId = seatId;
        defaultTitheBps = titheBps_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Atomically bind a pool to abi.encode(uint256 seatId, uint24 titheBps) and initialize it.
    /// @dev v4 initialize has no hookData parameter. Self-initiated initialization skips callbacks,
    ///      so this entry point records the configuration itself before calling the manager.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        nonReentrant
        returns (int24 tick)
    {
        if (hookData.length != 64) revert InvalidHookData();
        (uint256 seatId, uint24 bps) = abi.decode(hookData, (uint256, uint24));
        _configure(key, seatId, bps);
        tick = poolManager.initialize(key, sqrtPriceX96);
    }

    /// @notice The launch factory's ordinary initialize call binds constructor defaults.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4)
    {
        _configure(key, defaultSeatId, defaultTitheBps);
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Exact input: reserve the maximum tithe inside the caller's input budget. This is
    ///      strictly less than the budget; the real AMM still executes the remaining swap.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolConfig memory config = _config(key);
        _validateAmount(params.amountSpecified);
        uint256 reserve = params.amountSpecified < 0 ? uint256(-params.amountSpecified) * config.titheBps / BPS : 0;
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(reserve)), 0), 0);
    }

    /// @dev Charge the input currency only. Exact-output input is the unspecified currency;
    ///      exact-input uses the beforeSwap reservation and returns excess to the router as claims.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager nonReentrant returns (bytes4, int128) {
        PoolConfig memory config = _config(key);
        _validateAmount(params.amountSpecified);
        int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        if (inputDelta > 0) revert InvalidInputDelta();
        uint256 input = uint256(-int256(inputDelta));
        uint256 fee = input * config.titheBps / (BPS - config.titheBps);
        Currency currency = params.zeroForOne ? key.currency0 : key.currency1;

        bool exactInput = params.amountSpecified < 0;
        if (exactInput) {
            uint256 reserve = uint256(-params.amountSpecified) * config.titheBps / BPS;
            if (fee > reserve) fee = reserve;
            uint256 refund = reserve - fee;
            if (refund != 0) {
                poolManager.mint(sender, currency.toId(), refund);
                emit InputRefund(sender, Currency.unwrap(currency), refund);
            }
        }
        // The manager also casts the final router debt to int128. Fail before a narrowing cast.
        uint256 maxDelta = uint256(uint128(type(int128).max));
        if (input > maxDelta || fee > maxDelta - input) revert InvalidSwapAmount();
        if (fee != 0) _collect(key.toId(), config.seatId, currency, fee);
        return (IHooks.afterSwap.selector, exactInput ? int128(0) : int128(int256(fee)));
    }

    /// @notice Nominal claimable amount: liquid credit plus unredeemed manager claims.
    /// @dev Transfer-tax assets may lose value upon redemption or payout. Native ETH uses address(0).
    function titheOf(uint256 seatId, address token) external view returns (uint256) {
        return tithe[seatId][token] + pendingTithe[seatId][token];
    }

    /// @notice Anyone can redeem backing into this hook; the seat's entitlement does not change.
    function redeemTithe(uint256 seatId, address token) external nonReentrant returns (uint256 received) {
        return _redeem(seatId, token);
    }

    /// @notice Anyone may trigger payment, always to the current seat owner.
    function claim(uint256 seatId, address token) external nonReentrant returns (uint256 amount) {
        _redeem(seatId, token);
        // v4 mint/burn/take deltas are int128, while aggregate credits are uint256.
        // Extremely large pending balances must first be redeemed in bounded chunks.
        if (pendingTithe[seatId][token] != 0) revert RedeemPendingFirst();
        amount = tithe[seatId][token];
        if (amount == 0) revert NothingToClaim();
        // Resolve after redemption: a token transfer callback cannot make this owner lookup stale.
        address recipient = IMD_SEAT.ownerOf(seatId);
        if (recipient == address(0) || recipient == address(this)) revert InvalidSeatOwner();
        tithe[seatId][token] = 0;
        totalTithe[token] -= amount;
        Currency.wrap(token).transfer(recipient, amount);
        emit TitheClaimed(seatId, token, recipient, amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_redeeming) revert UnexpectedUnlock();
        _redeeming = false;
        (uint256 seatId, address token) = abi.decode(data, (uint256, address));
        return abi.encode(_redeemUnlocked(seatId, token));
    }

    /// @dev Direct ETH donations are refused. Forced ETH/ERC-20 donations remain unassigned surplus.
    receive() external payable onlyPoolManager {}

    function _validateBps(uint24 bps) private pure {
        if (bps == 0 || bps >= BPS) revert InvalidTitheBps();
    }

    function _validateAmount(int256 amount) private pure {
        if (amount == 0 || amount > type(int128).max || amount < -int256(type(int128).max)) {
            revert InvalidSwapAmount();
        }
    }

    function _configure(PoolKey calldata key, uint256 seatId, uint24 bps) private {
        if (address(key.hooks) != address(this)) revert WrongHook();
        _validateBps(bps);
        PoolId id = key.toId();
        if (poolConfig[id].initialized) revert AlreadyConfigured();
        poolConfig[id] = PoolConfig(seatId, bps, true);
        emit PoolConfigured(id, seatId, bps);
    }

    function _config(PoolKey calldata key) private view returns (PoolConfig memory config) {
        if (address(key.hooks) != address(this)) revert WrongHook();
        config = poolConfig[key.toId()];
        if (!config.initialized) revert PoolNotConfigured();
    }

    function _collect(PoolId id, uint256 seatId, Currency currency, uint256 fee) private {
        address token = Currency.unwrap(currency);
        bool deferred = currency.balanceOf(address(poolManager)) < fee;
        uint256 credited;
        if (deferred) {
            poolManager.mint(address(this), currency.toId(), fee);
            pendingTithe[seatId][token] += fee;
            totalPending[token] += fee;
            credited = fee;
        } else {
            uint256 beforeBalance = currency.balanceOfSelf();
            poolManager.take(currency, address(this), fee);
            credited = currency.balanceOfSelf() - beforeBalance;
            tithe[seatId][token] += credited;
        }
        totalTithe[token] += credited;
        emit TitheAccrued(id, seatId, token, fee, credited, deferred);
    }

    function _redeem(uint256 seatId, address token) private returns (uint256) {
        if (pendingTithe[seatId][token] == 0) return 0;
        if (poolManager.isUnlocked()) return _redeemUnlocked(seatId, token);
        _redeeming = true;
        return abi.decode(poolManager.unlock(abi.encode(seatId, token)), (uint256));
    }

    function _redeemUnlocked(uint256 seatId, address token) private returns (uint256 received) {
        uint256 amount = pendingTithe[seatId][token];
        uint256 maxDelta = uint256(uint128(type(int128).max));
        if (amount > maxDelta) amount = maxDelta;
        pendingTithe[seatId][token] -= amount;
        totalPending[token] -= amount;
        totalTithe[token] -= amount;
        Currency currency = Currency.wrap(token);
        uint256 beforeBalance = currency.balanceOfSelf();
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, address(this), amount);
        received = currency.balanceOfSelf() - beforeBalance;
        tithe[seatId][token] += received;
        totalTithe[token] += received;
        emit TitheRedeemed(seatId, token, amount, received);
    }
}
