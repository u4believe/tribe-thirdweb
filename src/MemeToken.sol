// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract MemeToken is ERC20, ERC20Burnable {
    address public launchpad;

    modifier onlyLaunchpad() {
        require(msg.sender == launchpad, "Only launchpad");
        _;
    }

    constructor(string memory name, string memory symbol, uint256 /*totalSupply*/) ERC20(name, symbol) {}

    function setLaunchpad(address _launchpad) external {
        require(launchpad == address(0), "Launchpad already set");
        launchpad = _launchpad;
    }

    function mint(address to, uint256 amount) external onlyLaunchpad {
        _mint(to, amount);
    }

    function setAllowanceForUser(address spender, uint256 amount) external {
        require(msg.sender == launchpad, "Only launchpad");
        _approve(msg.sender, spender, amount);
    }
}