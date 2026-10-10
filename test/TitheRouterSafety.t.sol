// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TitheFixture,
    TitheHook,
    TitheRouter,
    PoolKey,
    Currency,
    IHooks,
    SwapParams,
    ModifyLiquidityParams
} from "./helpers/TitheFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TaxToken} from "./mocks/AdversarialMocks.sol";

contract TitheCallbackTrader {
    TitheRouter public immutable router;
    bool public rejectETH;
    bool public tryReentry;
    uint256 public attempts;
    bool public reentered;
    bytes4 public reentryError;
    TitheRouter.SwapRequest private replay;

    constructor(TitheRouter router_) {
        router = router_;
    }

    function configure(bool reject, bool reenter) external {
        rejectETH = reject;
        tryReentry = reenter;
    }

    function approve(IERC20 token) external {
        token.approve(address(router), type(uint256).max);
    }

    function trade(TitheRouter.SwapRequest calldata request) external payable returns (uint256, uint256) {
        replay = request;
        return router.swap{value: msg.value}(request);
    }

    receive() external payable {
        require(!rejectETH, "recipient rejected ETH");
        if (tryReentry) {
            attempts++;
            bytes memory reason;
            (reentered, reason) = address(router).call(abi.encodeCall(router.swap, (replay)));
            reentryError = bytes4(reason);
        }
    }
}

contract TitheRouterSafetyTest is TitheFixture {
    using StateLibrary for IPoolManager;

    function _state(PoolKey memory pool, address payer) internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(address(manager)).getSlot0(pool.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                IPoolManager(address(manager)).getLiquidity(pool.toId()),
                _assetState(pool.currency0, payer),
                _assetState(pool.currency1, payer)
            )
        );
    }

    function _assetState(Currency currency, address payer) internal view returns (bytes32) {
        address asset = Currency.unwrap(currency);
        return keccak256(
            abi.encode(
                currency.balanceOf(payer),
                currency.balanceOf(address(manager)),
                currency.balanceOf(address(router)),
                currency.balanceOf(address(hook)),
                hook.tithe(1, asset),
                hook.pendingTithe(1, asset),
                hook.totalTithe(asset),
                hook.totalPending(asset),
                manager.balanceOf(address(hook), currency.toId()),
                manager.balanceOf(address(router), currency.toId())
            )
        );
    }

    function test_invalidRequestMatrixPreservesPoolAndExistingCredits() public {
        _seed();
        _swap(true, -1 ether);
        _swap(false, -1 ether);
        bytes32 beforeState = _state(key, trader);
        for (uint256 i; i < 8; ++i) {
            TitheRouter.SwapRequest memory request = _request(false, -1 ether);
            if (i == 0) request.maxInput = 0;
            if (i == 1) request.maxInput = uint256(uint128(type(int128).max)) + 1;
            if (i == 2) request.minOutput = 0;
            if (i == 3) request.params.amountSpecified = 0;
            if (i == 4) request.params.amountSpecified = -int256(request.maxInput) - 1;
            if (i == 5) request.params.amountSpecified = type(int256).min;
            if (i == 6) request.params.amountSpecified = int256(type(int128).max) + 1;
            if (i == 7) request.key.hooks = IHooks(address(token));
            vm.prank(trader);
            vm.expectRevert(TitheRouter.InvalidRequest.selector);
            router.swap(request);
            assertEq(_state(key, trader), beforeState, "invalid request mutated balances or pool");
        }
    }

    function test_constructorAndManagerMismatchFailWithoutTakingInput() public {
        vm.expectRevert(TitheRouter.InvalidAddress.selector);
        new TitheRouter(IPoolManager(address(0)), hook);
        vm.expectRevert(TitheRouter.InvalidAddress.selector);
        new TitheRouter(manager, TitheHook(payable(address(0))));
        // A real deployed contract, deliberately the wrong dependency, is sufficient for this guard.
        TitheRouter mismatched = new TitheRouter(IPoolManager(address(token)), hook);
        TitheRouter.SwapRequest memory request = _request(true, -1 ether);
        vm.prank(trader);
        vm.expectRevert(TitheRouter.InvalidRequest.selector);
        mismatched.swap{value: 1 ether}(request);
        assertEq(address(mismatched).balance, 0);
    }

    function test_wrongValueAndInsufficientAllowanceCannotUseDonations() public {
        _seed();
        token.transfer(address(router), 99 ether);
        vm.deal(address(router), 99 ether);
        bytes32 beforeState = _state(key, trader);
        TitheRouter.SwapRequest memory request = _request(false, -1 ether);
        vm.prank(trader);
        vm.expectRevert(TitheRouter.InvalidValue.selector);
        router.swap{value: 1}(request);
        request = _request(true, -1 ether);
        vm.prank(trader);
        vm.expectRevert(TitheRouter.InvalidValue.selector);
        router.swap{value: 1 ether - 1}(request);
        vm.prank(trader);
        vm.expectRevert(TitheRouter.InvalidValue.selector);
        router.swap{value: 1 ether + 1}(request);
        request = _request(false, -1 ether);
        vm.prank(trader);
        token.approve(address(router), 1 ether - 1);
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(router), 1 ether - 1, 1 ether
            )
        );
        router.swap(request);
        assertEq(_state(key, trader), beforeState);
        assertEq(token.allowance(trader, address(router)), 1 ether - 1);
    }

    function test_exactOutputInputCapRevertsAfterAccrualAndPreservesAllowance() public {
        _seed();
        _swap(false, -1 ether);
        TitheRouter.SwapRequest memory request = _request(false, 1 ether);
        request.maxInput = 1; // Valid request shape, insufficient gross input including tithe.
        vm.prank(trader);
        token.approve(address(router), 1);
        bytes32 beforeState = _state(key, trader);
        vm.prank(trader);
        vm.expectRevert(TitheRouter.Slippage.selector);
        router.swap(request);
        assertEq(_state(key, trader), beforeState);
        assertEq(token.allowance(trader, address(router)), 1);
        // A failed unlock must not leave the router's entry guard or callback flag stuck.
        vm.prank(trader);
        token.approve(address(router), 2 ether);
        _swap(false, -1 ether);
    }

    function test_rejectedNativeRefundRollsBackOutputFeeAndPool() public {
        _seed();
        TitheCallbackTrader actor = new TitheCallbackTrader(router);
        actor.configure(true, false);
        TitheRouter.SwapRequest memory request = _request(true, 1 ether);
        bytes32 beforeState = _state(key, address(actor));
        uint256 callerBalance = address(this).balance;
        vm.expectRevert(); // v4 wraps the recipient's revert as NativeTransferFailed.
        actor.trade{value: request.maxInput}(request);
        assertEq(_state(key, address(actor)), beforeState);
        assertEq(address(this).balance, callerBalance);
        actor.configure(false, true);
        (uint256 spent, uint256 received) = actor.trade{value: request.maxInput}(request);
        assertEq(received, 1 ether);
        assertEq(address(actor).balance, request.maxInput - spent);
        assertEq(token.balanceOf(address(actor)), received);
        assertEq(actor.attempts(), 1);
        assertFalse(actor.reentered());
        assertEq(actor.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_rejectedNativeOutputRollsBackInputAndCanRetry() public {
        _seed();
        TitheCallbackTrader actor = new TitheCallbackTrader(router);
        token.transfer(address(actor), 5 ether);
        actor.approve(IERC20(address(token)));
        actor.configure(true, false);
        TitheRouter.SwapRequest memory request = _request(false, -1 ether);
        bytes32 beforeState = _state(key, address(actor));
        vm.expectRevert();
        actor.trade(request);
        assertEq(_state(key, address(actor)), beforeState);
        actor.configure(false, true);
        (uint256 spent, uint256 output) = actor.trade(request);
        assertEq(spent, 1 ether);
        assertEq(address(actor).balance, output);
        assertEq(token.balanceOf(address(actor)), 4 ether);
        assertEq(actor.attempts(), 1);
        assertFalse(actor.reentered());
        assertEq(actor.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function _taxPool() internal returns (TaxToken tax, PoolKey memory pool) {
        tax = new TaxToken();
        pool = key;
        pool.currency1 = Currency.wrap(address(tax));
        manager.initialize(pool, Q96);
        tax.transfer(address(lp), 10_000 ether);
        lp.modify(pool, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        tax.transfer(trader, 10 ether);
        vm.prank(trader);
        tax.approve(address(router), 10 ether);
    }

    function test_taxedSettlementRollsBackFeeAlreadyTakenByHook() public {
        (TaxToken tax, PoolKey memory pool) = _taxPool();
        tax.configure(address(manager), address(0), 1000);
        TitheRouter.SwapRequest memory request = _request(false, -1 ether);
        request.key = pool;
        bytes32 beforeState = _state(pool, trader);
        uint256 supply = tax.totalSupply();
        vm.prank(trader);
        vm.expectRevert(TitheRouter.TransferTaxNotSupported.selector);
        router.swap(request);
        assertEq(_state(pool, trader), beforeState);
        assertEq(tax.totalSupply(), supply, "reverted transfer burned supply");
        assertEq(tax.allowance(trader, address(router)), 10 ether);
    }

    function test_taxedOutputChecksRecipientReceiptForBothSwapModes() public {
        (TaxToken tax, PoolKey memory pool) = _taxPool();
        tax.configure(trader, address(manager), 1000); // tax manager -> router and router -> trader
        TitheRouter.SwapRequest memory request = _request(true, 1 ether);
        request.key = pool;
        bytes32 beforeState = _state(pool, trader);
        vm.prank(trader);
        vm.expectRevert(TitheRouter.Slippage.selector);
        router.swap{value: request.maxInput}(request);
        assertEq(_state(pool, trader), beforeState);

        request.params.amountSpecified = -1 ether;
        request.maxInput = 1 ether;
        uint256 snapshot = vm.snapshotState();
        vm.prank(trader);
        (, uint256 actualReceipt) = router.swap{value: 1 ether}(request);
        assertGt(actualReceipt, 0);
        assertTrue(vm.revertToState(snapshot));
        request.minOutput = actualReceipt + 1;
        vm.prank(trader);
        vm.expectRevert(TitheRouter.Slippage.selector);
        router.swap{value: 1 ether}(request);
        assertEq(_state(pool, trader), beforeState);
        request.minOutput = actualReceipt;
        uint256 tokensBefore = tax.balanceOf(trader);
        vm.prank(trader);
        (, uint256 reported) = router.swap{value: 1 ether}(request);
        assertEq(reported, actualReceipt);
        assertEq(tax.balanceOf(trader) - tokensBefore, actualReceipt);
        assertEq(tax.balanceOf(address(router)), 0);
    }
}
