// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Test-only, prefunded depositor. Creates genuine, settled ERC-6909 surplus claims.
contract ClaimDonationHarness is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(Currency currency, address recipient, uint256 amount) external payable {
        manager.unlock(abi.encode(currency, recipient, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (Currency currency, address recipient, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        manager.mint(recipient, currency.toId(), amount);
        manager.sync(currency);
        if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            currency.transfer(address(manager), amount);
            manager.settle();
        }
        return "";
    }
}

/// @dev Force an unsolicited native donation without impersonating the PoolManager.
contract ForcedTitheDonation {
    constructor(address payable recipient) payable {
        selfdestruct(recipient);
    }
}
