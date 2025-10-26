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

    function testSellTokens() public {
        // Create a token
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("SellToken", "ST", "Sell metadata");

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
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", address(launchpad), 0, sellAmount));
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