// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {
    TitheFixture,
    TitheHook,
    TitheRouter,
    PoolKey,
    Currency,
    SwapParams,
    ModifyLiquidityParams,
    TickMath,
    TitheToken,
    MockSeat
} from "./helpers/TitheFixture.sol";

contract TitheHandler is Test {
    TitheHook public immutable hook;
    TitheRouter public immutable router;
    TitheToken public immutable token;
    MockSeat public immutable seat;
    address public immutable alice;
    address public immutable bob;
    PoolKey[3] private keys;
    mapping(address => uint256) public accrued;
    mapping(address => uint256) public claimed;
    uint256 public swaps;

    constructor(
        TitheHook hook_,
        TitheRouter router_,
        TitheToken token_,
        MockSeat seat_,
        PoolKey[3] memory keys_,
        address alice_,
        address bob_
    ) {
        hook = hook_;
        router = router_;
        token = token_;
        seat = seat_;
        keys = keys_;
        alice = alice_;
        bob = bob_;
        token.approve(address(router), type(uint256).max);
    }

    function swap(uint8 poolSeed, uint96 amountSeed, bool buy, bool exactInput) external {
        PoolKey memory key = keys[poolSeed % 3];
        uint256 amount = bound(amountSeed, 1e8, 1 ether);
        uint256 maxInput = exactInput ? amount : amount * 2;
        TitheRouter.SwapRequest memory request = TitheRouter.SwapRequest({
            key: key,
            params: SwapParams(
                buy,
                exactInput ? -int256(amount) : int256(amount),
                buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            maxInput: maxInput,
            minOutput: 1,
            deadline: block.timestamp
        });
        address asset = buy ? address(0) : address(token);
        uint256 beforeTotal = hook.totalTithe(asset);
        router.swap{value: buy ? maxInput : 0}(request);
        accrued[asset] += hook.totalTithe(asset) - beforeTotal;
        swaps++;
    }

    function claim(uint8 seatSeed, bool native) external {
        uint256 seatId = seatSeed % 2 + 1;
        address asset = native ? address(0) : address(token);
        if (hook.titheOf(seatId, asset) == 0) return;
        claimed[asset] += hook.claim(seatId, asset);
    }

    function transferSeat(uint8 seatSeed) external {
        uint256 seatId = seatSeed % 2 + 1;
        address owner = seat.ownerOf(seatId);
        vm.prank(owner);
        seat.transferFrom(owner, owner == alice ? bob : alice, seatId);
    }

    receive() external payable {}
}

contract TitheInvariantTest is StdInvariant, TitheFixture {
    TitheHandler internal handler;

    function setUp() public override {
        super.setUp();
        _seed();
        PoolKey[3] memory keys;
        keys[0] = key;
        keys[1] = key;
        keys[1].tickSpacing = 120;
        hook.initializePool(keys[1], Q96, abi.encode(uint256(2), uint24(75)));
        keys[2] = key;
        keys[2].fee = 3000;
        hook.initializePool(keys[2], Q96, abi.encode(uint256(1), uint24(50)));
        for (uint256 i = 1; i < 3; ++i) {
            lp.modify(keys[i], ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        }
        handler = new TitheHandler(hook, router, token, seat, keys, alice, bob);
        vm.deal(address(handler), 10_000 ether);
        token.transfer(address(handler), 10_000 ether);
        handler.swap(0, 1 ether, true, true);
        handler.swap(1, 1 ether, false, true);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.transferSeat.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_creditsEqualBackingAndAccruedEqualsPaidPlusOutstanding() public view {
        for (uint256 i; i < 2; ++i) {
            Currency currency = i == 0 ? key.currency0 : key.currency1;
            address asset = Currency.unwrap(currency);
            assertEq(hook.titheOf(1, asset) + hook.titheOf(2, asset), hook.totalTithe(asset));
            assertEq(
                hook.totalTithe(asset),
                currency.balanceOf(address(hook)) + manager.balanceOf(address(hook), currency.toId())
            );
            assertEq(handler.accrued(asset), handler.claimed(asset) + hook.totalTithe(asset));
            assertEq(currency.balanceOf(address(router)), 0);
            assertEq(manager.balanceOf(address(router), currency.toId()), 0);
        }
    }

    function invariant_tokenSupplyConservedAcrossEveryParticipant() public view {
        uint256 accounted = token.balanceOf(address(this)) + token.balanceOf(address(lp)) + token.balanceOf(trader)
            + token.balanceOf(address(handler)) + token.balanceOf(address(manager)) + token.balanceOf(address(hook))
            + token.balanceOf(address(router)) + token.balanceOf(alice) + token.balanceOf(bob);
        assertEq(accounted, token.totalSupply());
        assertEq(token.totalSupply(), 1e27);
        assertGe(handler.swaps(), 2);
    }
}
