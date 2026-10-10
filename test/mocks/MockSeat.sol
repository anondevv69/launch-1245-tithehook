// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockSeat is ERC721 {
    constructor() ERC721("Mock identity seat", "SEAT") {}

    function mint(address to, uint256 seatId) external {
        _mint(to, seatId);
    }

    function burn(uint256 seatId) external {
        _burn(seatId);
    }
}
