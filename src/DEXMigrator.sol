// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./MemeLaunchpad.sol";

contract DEXMigrator {
    function migrateToDEX(
        address launchpadAddress,
        address tokenAddress,
        address dexRouter
    ) external {
        // Ensure only owner of launchpad can call
        require(msg.sender == MemeLaunchpad(launchpadAddress).owner(), "Only launchpad owner");

        // Read heldTokens from launchpad
        uint256 heldAmount = MemeLaunchpad(launchpadAddress).getHeldTokens(tokenAddress);
        uint256 ethAmount = address(launchpadAddress).balance;
        require(heldAmount > 0 && ethAmount > 0, "No liquidity to migrate");

        // Approve the router to spend the tokens
        MemeLaunchpad(launchpadAddress).approveRouter(tokenAddress, dexRouter, heldAmount);

        // Add liquidity to DEX
        IDEXRouter(dexRouter).addLiquidityETH{value: ethAmount}(
            tokenAddress,
            heldAmount,
            heldAmount,
            ethAmount,
            launchpadAddress,
            block.timestamp
        );

        // Note: heldTokens is automatically set to 0 in the MemeLaunchpad's _migrateToDEX function
    }
}