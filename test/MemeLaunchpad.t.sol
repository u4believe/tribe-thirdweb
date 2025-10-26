// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/MemeLaunchpad.sol";
import "../src/MemeToken.sol";

contract MemeLaunchpadTest is Test {
    MemeLaunchpad public launchpad;
    address public treasury;
    address public creator;

    function setUp() public {
        treasury = makeAddr("treasury");
        creator = makeAddr("creator");
        address dexRouter = makeAddr("dexRouter");
        launchpad = new MemeLaunchpad(treasury, dexRouter);
    }

    function testCreateToken() public {
        string memory name = "TestToken";
        string memory symbol = "TEST";
        string memory metadata = "Test metadata";

        // Set the creator as the sender
        vm.prank(creator);

        // Expect the TokenCreated event (skip checking tokenAddress and data)
        vm.expectEmit(false, true, false, false, address(launchpad));
        emit MemeLaunchpad.TokenCreated(
            address(0), // placeholder, not checked
            name,
            symbol,
            metadata,
            creator, // now the creator is the sender
            0
        );

        // Create the token
        address tokenAddress = launchpad.createToken(name, symbol, metadata);

        // Verify the token was created and is valid
        assertTrue(launchpad.isValidToken(tokenAddress), "Token should be valid");

        // Verify token info
        MemeLaunchpad.TokenInfo memory info = launchpad.getTokenInfo(tokenAddress);
        assertEq(info.name, name, "Token name mismatch");
        assertEq(info.symbol, symbol, "Token symbol mismatch");
        assertEq(info.metadata, metadata, "Token metadata mismatch");
        assertEq(info.creator, creator, "Token creator mismatch");
        assertEq(info.creatorAllocation, 0, "Creator allocation should be 0");
        assertEq(info.maxSupply, 1_000_000_000 * 1e18, "Max supply mismatch");
        assertEq(info.currentSupply, 0, "Current supply should be 0");
        assertFalse(info.completed, "Token should not be completed");
        assertEq(info.heldTokens, (info.maxSupply * 30) / 100, "Held tokens mismatch");

        // Verify the MemeToken contract
        MemeToken token = MemeToken(tokenAddress);
        assertEq(token.name(), name, "Token name mismatch in MemeToken");
        assertEq(token.symbol(), symbol, "Token symbol mismatch in MemeToken");
        assertEq(token.totalSupply(), info.heldTokens, "Total supply mismatch");
        assertEq(token.balanceOf(address(launchpad)), info.heldTokens, "Launchpad balance mismatch");
        assertEq(token.launchpad(), address(launchpad), "Launchpad address mismatch");

        // Verify no creator allocation
        assertEq(token.balanceOf(creator), 0, "Creator should have no tokens");
    }

    function testCreateTokenWithEmptyName() public {
        string memory name = "";
        string memory symbol = "TEST";
        string memory metadata = "Test metadata";

        vm.expectRevert("Name required");
        launchpad.createToken(name, symbol, metadata);
    }

    function testCreateTokenWithEmptySymbol() public {
        string memory name = "TestToken";
        string memory symbol = "";
        string memory metadata = "Test metadata";

        vm.expectRevert("Symbol required");
        launchpad.createToken(name, symbol, metadata);
    }

    function testMultipleTokens() public {
        // Create first token
        address token1 = launchpad.createToken("Token1", "T1", "Metadata1");
        assertTrue(launchpad.isValidToken(token1), "First token should be valid");

        // Create second token
        address token2 = launchpad.createToken("Token2", "T2", "Metadata2");
        assertTrue(launchpad.isValidToken(token2), "Second token should be valid");

        // Verify they are different
        assertNotEq(token1, token2, "Tokens should have different addresses");

        // Verify all tokens list
        address[] memory allTokens = launchpad.getAllTokens();
        assertEq(allTokens.length, 2, "Should have 2 tokens");
        assertEq(allTokens[0], token1, "First token mismatch");
        assertEq(allTokens[1], token2, "Second token mismatch");
    }

    function testBuyTokens() public {
        // Create a token
        address tokenAddress = launchpad.createToken("BuyToken", "BT", "Buy metadata");

        address buyer = makeAddr("buyer");
        uint256 ethAmount = 1e18;

        // Give ETH to buyer and reset treasury
        vm.deal(buyer, ethAmount);
        vm.deal(treasury, 0);

        // Buy tokens
        vm.prank(buyer);
        uint256 tokens = launchpad.buyTokens{value: ethAmount}(tokenAddress, 1e18);

        // Verify basic functionality
        assertGt(tokens, 0, "Should receive tokens");
        assertEq(MemeToken(tokenAddress).balanceOf(buyer), tokens);
        assertEq(launchpad.getTokenInfo(tokenAddress).currentSupply, tokens);
        assertFalse(launchpad.getTokenInfo(tokenAddress).completed);
        assertEq(treasury.balance, 0.01e18, "Treasury should receive 1% fee");
        assertGt(launchpad.getCurrentPrice(tokenAddress), 0.0001533e18, "Price should increase");
    }

    function testBuyTokensInsufficientETH() public {
        address tokenAddress = launchpad.createToken("FailToken", "FT", "Fail metadata");
        address buyer = makeAddr("buyer");

        vm.deal(buyer, 0);
        vm.prank(buyer);
        vm.expectRevert(MemeLaunchpad.MustSendETH.selector);
        launchpad.buyTokens(tokenAddress, 1);
    }

    function testBuyTokensSlippageTooHigh() public {
        address tokenAddress = launchpad.createToken("SlipToken", "ST", "Slip metadata");
        address buyer = makeAddr("buyer");
        uint256 ethAmount = 1e18;

        // Set minTokensOut higher than possible
        uint256 minTokensOut = type(uint256).max;

        vm.deal(buyer, ethAmount);
        vm.prank(buyer);
        vm.expectRevert(MemeLaunchpad.SlippageTooHigh.selector);
        launchpad.buyTokens{value: ethAmount}(tokenAddress, minTokensOut);
    }

    function testCompleteTokenLaunch() public {
        // Create a token
        address tokenAddress = launchpad.createToken("CompleteToken", "CT", "Complete metadata");

        // Buy some tokens to have ETH in the contract
        address buyer = makeAddr("buyer");
        uint256 ethAmount = 1e18;
        vm.deal(buyer, ethAmount);
        vm.prank(buyer);
        launchpad.buyTokens{value: ethAmount}(tokenAddress, 1);

        // Mock the DEX router call
        address dexRouter = launchpad.dexRouter();
        vm.mockCall(
            dexRouter,
            abi.encodeWithSelector(IDEXRouter.addLiquidityETH.selector),
            abi.encode(1, 1, 1) // mock return values
        );

        // Complete the token launch as owner
        launchpad.completeTokenLaunch(tokenAddress);

        // Verify token is completed
        MemeLaunchpad.TokenInfo memory updatedInfo = launchpad.getTokenInfo(tokenAddress);
        assertTrue(updatedInfo.completed, "Token should be completed");

        // Verify held tokens are 0 after migration
        assertEq(updatedInfo.heldTokens, 0, "Held tokens should be 0 after migration");
    }

    function testCompleteTokenLaunchOnlyOwner() public {
        address tokenAddress = launchpad.createToken("OwnerToken", "OT", "Owner metadata");
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(0x118cdaa7, nonOwner));
        launchpad.completeTokenLaunch(tokenAddress);
    }
}