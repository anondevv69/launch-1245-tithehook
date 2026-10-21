// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Independent review (2026-10-16): mainnet fork rehearsal of the live demo path.
// Runs ONLY against a fork (forge test --fork-url <mainnet RPC>); on a plain local run the
// deployed addresses have no code and every test skips, keeping the offline suite green.
// It attaches to the real PoolManager, the real TitheHook (0x815d...20cc) and the real TDEMO,
// executes an exact-input buy and sell through a SETTLE_ALL/TAKE_ALL router, checks the tithe
// deltas equal floor(budget * 25 / 10000) exactly, then claims the ETH tithe to the live seat
// owner. No real funds move: all state changes exist only inside the fork.

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TitheHook} from "../src/TitheHook.sol";
import {GenericRouter} from "./helpers/GenericRouter.sol";

contract TitheForkRehearsalTest is Test {
    IPoolManager internal constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    TitheHook internal constant HOOK = TitheHook(payable(0x815dE6EcfC1e0B24b7Ae8A5Dcc05ba8f5d8F20Cc));
    address internal constant TDEMO = 0x31cA73d03093357Df8ddAaA73DBe1970f4EeaD6c;
    IERC721 internal constant SEAT = IERC721(0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D);

    PoolKey internal key;

    function setUp() public {
        if (address(HOOK).code.length == 0) vm.skip(true);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(TDEMO), 12500, 60, IHooks(address(HOOK)));
    }

    function test_fork_liveBindingAndImmutables() public view {
        (uint256 seatId, uint24 bps, bool initialized) = HOOK.poolConfig(key.toId());
        assertEq(seatId, 1);
        assertEq(bps, 25);
        assertTrue(initialized);
        assertEq(address(HOOK.poolManager()), address(MANAGER));
        assertEq(address(HOOK.IMD_SEAT()), address(SEAT));
        assertEq(HOOK.defaultSeatId(), 1);
        assertEq(HOOK.defaultTitheBps(), 25);
    }

    function test_fork_buySellClaimRehearsal() public {
        GenericRouter generic = new GenericRouter(MANAGER);
        vm.deal(address(generic), 1 ether);

        // BUY: exact input 0.01 ETH. Tithe is charged on the specified budget.
        uint256 ethTitheBefore = HOOK.titheOf(1, address(0));
        (uint256 paid, uint256 received) = generic.swap(key, SwapParams(true, -0.01 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertGt(received, 0, "buy filled nothing");
        assertLe(paid, 0.01 ether);
        assertEq(HOOK.titheOf(1, address(0)) - ethTitheBefore, 0.01 ether * 25 / 10_000, "ETH tithe mismatch");
        assertEq(MANAGER.balanceOf(address(generic), Currency.wrap(TDEMO).toId()), 0, "router holds TDEMO claims");
        assertEq(MANAGER.balanceOf(address(generic), 0), 0, "router holds ETH claims");

        // SELL: half the TDEMO just bought, exact input. Tithe charged on that budget, in TDEMO.
        uint256 sellAmount = received / 2;
        require(sellAmount > 10_000, "sell amount too small to tithe");
        uint256 tdemoTitheBefore = HOOK.titheOf(1, TDEMO);
        (uint256 paidSell,) = generic.swap(key, SwapParams(false, -int256(sellAmount), TickMath.MAX_SQRT_PRICE - 1));
        assertEq(paidSell, sellAmount, "sell did not consume its budget");
        assertEq(HOOK.titheOf(1, TDEMO) - tdemoTitheBefore, sellAmount * 25 / 10_000, "TDEMO tithe mismatch");

        // CLAIM: the accumulated ETH tithe pays the live seat owner, in full, to nobody else.
        address owner = SEAT.ownerOf(1);
        uint256 claimable = HOOK.titheOf(1, address(0));
        uint256 ownerBefore = owner.balance;
        uint256 claimed = HOOK.claim(1, address(0));
        assertEq(claimed, claimable);
        assertEq(owner.balance - ownerBefore, claimable, "owner did not receive the full claim");
        assertEq(HOOK.titheOf(1, address(0)), 0);
    }
}
