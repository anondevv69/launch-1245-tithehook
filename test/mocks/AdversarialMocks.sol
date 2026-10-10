// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";
import {MockSeat} from "./MockSeat.sol";
import {TitheHook} from "../../src/TitheHook.sol";

/// @dev Models a tax specifically on manager-to-hook and hook-to-owner transfers.
contract TaxToken is MockERC20 {
    address public taxedReceiver;
    address public taxedSender;
    uint256 public taxBps;
    bool public blocked;
    bool public attemptedReentry;
    bool public reentrySucceeded;
    TitheHook public target;

    constructor() MockERC20("Tax token", "TAX", 1_000_000 ether) {}

    function configure(address receiver, address sender, uint256 bps) external {
        taxedReceiver = receiver;
        taxedSender = sender;
        taxBps = bps;
    }

    function setBlocked(bool value) external {
        blocked = value;
    }

    function setReentry(TitheHook hook) external {
        target = hook;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!blocked, "blocked");
        if (address(target) != address(0) && (to == address(target) || from == address(target))) {
            attemptedReentry = true;
            (reentrySucceeded,) = address(target).call(abi.encodeCall(target.claim, (1, address(this))));
        }
        uint256 tax = (to == taxedReceiver || from == taxedSender) ? amount * taxBps / 10_000 : 0;
        if (tax != 0) super._update(from, address(0), tax);
        super._update(from, to, amount - tax);
    }
}

contract ClaimReceiver {
    TitheHook public immutable hook;
    MockSeat public immutable seat;
    bool public reject;
    bool public attempted;
    bool public reentered;
    bool public redeemed;

    constructor(TitheHook hook_, MockSeat seat_) {
        hook = hook_;
        seat = seat_;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function transferSeat(address to) external {
        seat.transferFrom(address(this), to, 1);
    }

    receive() external payable {
        require(!reject, "reject ETH");
        attempted = true;
        (reentered,) = address(hook).call(abi.encodeCall(hook.claim, (1, address(0))));
        (redeemed,) = address(hook).call(abi.encodeCall(hook.redeemTithe, (1, address(0))));
    }
}

/// @dev No-return ERC-20 to exercise v4's optional-return token transfers.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}
