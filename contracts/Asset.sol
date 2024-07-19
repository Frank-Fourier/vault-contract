// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./dependencies/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Asset is ERC20, Ownable {

    string private _symbol = "LOCK";

    constructor() ERC20("Lock Token") Ownable(msg.sender) {
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }

    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    function setSymbol(string memory symbol_) external onlyOwner {
        _symbol = symbol_;
    }

    function mint(address to, uint amount) public {
        _mint(to, amount);
    }
}