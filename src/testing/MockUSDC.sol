// SPDX-License-Identifier: MIT
// ... (Content is identical to the previous version, just moved here) ...
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @dev A simple ERC20 token for testing purposes.
 * The owner can mint tokens to any address.
 */
contract MockUSDC is ERC20, Ownable {
    constructor() ERC20("Mock USDC", "mUSDC") Ownable(msg.sender) {
        // Mint initial supply to the deployer
        _mint(msg.sender, 1_000_000 * 10**decimals());
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}
