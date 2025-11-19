// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/MemeLaunchpad.sol";
import "../src/MemeToken.sol";

contract SellTokenTest is Test {
    MemeLaunchpad public launchpad;
    address public treasury;
    address public creator;
    address public dexRouter;

    function setUp() public {
        treasury = makeAddr("treasury");
        creator = makeAddr("creator");
        dexRouter = makeAddr("dexRouter");
        launchpad = new MemeLaunchpad(treasury, dexRouter);
    }

    // Helper function to unlock a token by having the creator buy enough tokens
    // Unlock threshold is 2% of max supply = 20M tokens
    function unlockToken(address tokenAddress) internal {
        // Check if already unlocked
        if (launchpad.tokenUnlocked(tokenAddress)) {
            return;
        }
        
        uint256 maxSupply = 1_000_000_000 * 1e18;
        uint256 unlockThreshold = (maxSupply * 2) / 100; // 20M tokens
        
        // Buy tokens until unlocked
        uint256 maxIterations = 100; // Safety limit
        for (uint256 i = 0; i < maxIterations && !launchpad.tokenUnlocked(tokenAddress); i++) {
            uint256 currentBought = launchpad.creatorBoughtAmount(tokenAddress, creator);
            if (currentBought >= unlockThreshold) {
                break;
            }
            
            // Give creator enough ETH for this purchase (refresh balance each iteration)
            uint256 ethAmount = 5000e18;
            vm.deal(creator, ethAmount);
            
            // Buy with a reasonable amount of ETH
            vm.prank(creator);
            launchpad.buyTokens{value: ethAmount}(tokenAddress, 1);
        }
    }

    function testSellTokens() public {
        // Create a token
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("SellToken", "ST", "Sell metadata");

        // Unlock the token first
        unlockToken(tokenAddress);

        // Buy some tokens first to have circulating supply
        address buyer = makeAddr("buyer");
        uint256 buyEth = 1e18;
        vm.deal(buyer, buyEth);
        vm.prank(buyer);
        uint256 initialTokens = launchpad.buyTokens{value: buyEth}(tokenAddress, 1e18);

        // Get current info and approve
        MemeLaunchpad.TokenInfo memory info = launchpad.getTokenInfo(tokenAddress);
        uint256 sellAmount = 1e18;
        vm.prank(buyer);
        MemeToken(tokenAddress).approve(address(launchpad), sellAmount);

        // Record balances
        uint256 ethBefore = buyer.balance;
        uint256 treasuryBefore = treasury.balance;

        // Sell tokens
        vm.prank(buyer);
        uint256 received = launchpad.sellTokens(tokenAddress, sellAmount);

        // Verify basic functionality
        assertGt(received, 0);
        assertEq(buyer.balance, ethBefore + received);
        assertEq(MemeToken(tokenAddress).balanceOf(buyer), initialTokens - sellAmount);
        assertEq(launchpad.getTokenInfo(tokenAddress).currentSupply, info.currentSupply - sellAmount);
        assertGt(treasury.balance, treasuryBefore);
    }

    function testSellTokensInsufficientAllowance() public {
        // Create a token
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("FailSellToken", "FST", "Fail metadata");

        // Unlock the token first
        unlockToken(tokenAddress);

        // Buy some tokens
        address buyer = makeAddr("buyer");
        uint256 buyEth = 1e18;
        vm.deal(buyer, buyEth);
        vm.prank(buyer);
        launchpad.buyTokens{value: buyEth}(tokenAddress, 1);

        address seller = buyer;
        uint256 sellAmount = 1e18;

        // Do not approve

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                0xfb8f41b2, // ERC20InsufficientAllowance selector
                address(launchpad),
                0,
                sellAmount
            )
        );
        launchpad.sellTokens(tokenAddress, sellAmount);
    }

    function testSellTokensNoTokens() public {
        // Create a token
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("NoSellToken", "NST", "No metadata");

        address seller = makeAddr("seller");
        uint256 sellAmount = 0;

        vm.prank(seller);
        vm.expectRevert(MemeLaunchpad.MustSellTokens.selector);
        launchpad.sellTokens(tokenAddress, sellAmount);
    }

    function testSellTokensExceedsCirculatingSupply() public {
        // Create a token
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("ExceedToken", "ET", "Exceed metadata");

        // Unlock the token first
        unlockToken(tokenAddress);

        // Buy some tokens
        address buyer = makeAddr("buyer");
        uint256 buyEth = 1e18;
        vm.deal(buyer, buyEth);
        vm.prank(buyer);
        launchpad.buyTokens{value: buyEth}(tokenAddress, 1);

        // Try to sell more than available
        vm.prank(buyer);
        MemeToken(tokenAddress).approve(address(launchpad), 1e28);

        vm.prank(buyer);
        vm.expectRevert(MemeLaunchpad.InsufficientCirculatingSupply.selector);
        launchpad.sellTokens(tokenAddress, 1e28);
    }
}