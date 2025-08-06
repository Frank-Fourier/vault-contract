// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Asset
 * @dev A simple ERC20 token for testing purposes, mintable by the owner.
 */
contract Asset is ERC20, Ownable {
    /**
     * @dev Sets the name, symbol, and initial owner, and mints initial supply.
     */
    constructor() ERC20("Lock Token", "LOCK") Ownable(msg.sender) {
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }

    /**
     * @dev Creates `amount` new tokens for `to`.
     * @param to The address that will receive the minted tokens.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint amount) public {
        _mint(to, amount);
    }
}