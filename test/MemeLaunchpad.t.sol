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

    // Helper function to unlock a token by having the creator buy enough tokens
    // Unlock threshold is 2% of max supply = 20M tokens
    // At initial price of 0.0001533e18, we need ~3066 ETH, but we'll use more to account for price increases
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
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("BuyToken", "BT", "Buy metadata");

        // Unlock the token first
        unlockToken(tokenAddress);

        // Get the current supply after unlocking (creator has already bought tokens)
        uint256 supplyBefore = launchpad.getTokenInfo(tokenAddress).currentSupply;

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
        assertEq(launchpad.getTokenInfo(tokenAddress).currentSupply, supplyBefore + tokens);
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
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("SlipToken", "ST", "Slip metadata");
        
        // Unlock the token first
        unlockToken(tokenAddress);
        
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
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("CompleteToken", "CT", "Complete metadata");

        // Unlock the token first
        unlockToken(tokenAddress);

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

    // ==================== CREATOR BUY LIMIT TESTS ====================

    function testCreatorCanBuyWithinLimit() public {
        // Create token as creator
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("CreatorToken", "CT", "Creator metadata");

        // Calculate creator max buy: 20% of bonding curve (70% of 1B = 140M tokens)
        uint256 maxSupply = 1_000_000_000 * 1e18;
        uint256 bondingMax = (maxSupply * 70) / 100; // 700M tokens
        uint256 creatorMaxBuy = (bondingMax * 20) / 100; // 140M tokens

        // Give creator enough ETH to buy a small amount within limit
        uint256 ethAmount = 1000e18; // Enough ETH for substantial purchase
        vm.deal(creator, ethAmount);
        vm.deal(treasury, 0);

        // Buy tokens as creator (should succeed)
        vm.prank(creator);
        uint256 tokensBought = launchpad.buyTokens{value: ethAmount}(tokenAddress, 1);

        // Verify tokens were bought
        assertGt(tokensBought, 0, "Creator should receive tokens");
        assertEq(MemeToken(tokenAddress).balanceOf(creator), tokensBought, "Creator balance mismatch");
        
        // Verify creator bought amount is tracked
        assertEq(
            launchpad.creatorBoughtAmount(tokenAddress, creator),
            tokensBought,
            "Creator bought amount should be tracked"
        );

        // Verify creator can still buy more (if within limit)
        assertLt(tokensBought, creatorMaxBuy, "Tokens bought should be less than max");
    }

    function testCreatorCannotExceedBuyLimit() public {
        // Create token as creator
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("LimitToken", "LT", "Limit metadata");

        // Calculate creator max buy: 140M tokens
        uint256 maxSupply = 1_000_000_000 * 1e18;
        uint256 bondingMax = (maxSupply * 70) / 100; // 700M tokens
        uint256 creatorMaxBuy = (bondingMax * 20) / 100; // 140M tokens

        // Give creator a large amount of ETH
        vm.deal(creator, 500000e18);
        vm.deal(treasury, 0);

        // Buy tokens in smaller chunks to avoid hitting limit unexpectedly
        uint256 purchaseCount = 0;
        uint256 ethPerPurchase = 2000e18; // Smaller purchases
        
        // Make purchases and verify limit is never exceeded
        for (uint256 i = 0; i < 150; i++) {
            uint256 currentBought = launchpad.creatorBoughtAmount(tokenAddress, creator);
            
            // If we're already at the limit, verify we can't buy more
            if (currentBought >= creatorMaxBuy) {
                vm.prank(creator);
                vm.expectRevert(MemeLaunchpad.CreatorBuyLimitExceeded.selector);
                launchpad.buyTokens{value: ethPerPurchase}(tokenAddress, 1);
                break;
            }
            
            // Calculate remaining capacity - if very small, use tiny purchase amount
            uint256 remainingCapacity = creatorMaxBuy - currentBought;
            uint256 purchaseAmount = ethPerPurchase;
            
            // Use very small amount when close to limit to avoid exceeding it
            if (remainingCapacity < 1e18) {
                purchaseAmount = 1e12; // Very small amount
            }
            
            // Try to buy tokens - if it would exceed limit, it will revert
            // We handle this by checking the result
            vm.prank(creator);
            
            // Use expectRevert if we're very close to limit
            if (remainingCapacity < 1e15) {
                vm.expectRevert(MemeLaunchpad.CreatorBuyLimitExceeded.selector);
                launchpad.buyTokens{value: purchaseAmount}(tokenAddress, 1);
                break;
            }
            
            // Otherwise, try to buy
            uint256 tokensBought = launchpad.buyTokens{value: purchaseAmount}(tokenAddress, 1);
            
            // Verify we got tokens
            assertGt(tokensBought, 0, "Should receive tokens");
            purchaseCount++;
            
            // Verify we haven't exceeded the limit
            uint256 newTotal = launchpad.creatorBoughtAmount(tokenAddress, creator);
            assertLe(newTotal, creatorMaxBuy, "Should never exceed creator buy limit");
            
            // If we've reached the limit, verify next purchase fails
            if (newTotal >= creatorMaxBuy) {
                vm.prank(creator);
                vm.expectRevert(MemeLaunchpad.CreatorBuyLimitExceeded.selector);
                launchpad.buyTokens{value: purchaseAmount}(tokenAddress, 1);
                break;
            }
        }
        
        // Verify we made purchases and respected the limit
        assertGt(purchaseCount, 0, "Should have made some purchases");
        uint256 finalBought = launchpad.creatorBoughtAmount(tokenAddress, creator);
        assertLe(finalBought, creatorMaxBuy, "Should never exceed limit");
    }

    function testCreatorBuyLimitTrackedAcrossMultiplePurchases() public {
        // Create token as creator
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("TrackToken", "TT", "Track metadata");

        // Calculate creator max buy: 140M tokens
        uint256 maxSupply = 1_000_000_000 * 1e18;
        uint256 bondingMax = (maxSupply * 70) / 100;
        uint256 creatorMaxBuy = (bondingMax * 20) / 100;

        // Give creator ETH for multiple purchases
        vm.deal(creator, 10000e18);
        vm.deal(treasury, 0);

        uint256 totalBought = 0;
        uint256 purchaseCount = 5;
        uint256 ethPerPurchase = 1000e18;

        // Make multiple purchases
        for (uint256 i = 0; i < purchaseCount; i++) {
            vm.prank(creator);
            uint256 tokensBought = launchpad.buyTokens{value: ethPerPurchase}(tokenAddress, 1);
            totalBought += tokensBought;

            // Verify tracking is cumulative
            assertEq(
                launchpad.creatorBoughtAmount(tokenAddress, creator),
                totalBought,
                "Creator bought amount should be cumulative"
            );
        }

        // Verify total is tracked correctly
        assertEq(
            launchpad.creatorBoughtAmount(tokenAddress, creator),
            totalBought,
            "Total bought should match tracked amount"
        );

        // Verify we haven't exceeded the limit yet
        assertLe(totalBought, creatorMaxBuy, "Total bought should not exceed limit");
    }

    function testNonCreatorNotAffectedByBuyLimit() public {
        // Create token as creator
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("PublicToken", "PT", "Public metadata");

        // Unlock the token first
        unlockToken(tokenAddress);

        address buyer = makeAddr("buyer");
        uint256 ethAmount = 1e18;
        
        vm.deal(buyer, ethAmount);
        vm.deal(treasury, 0);

        // Non-creator can buy without limit restrictions
        vm.prank(buyer);
        uint256 tokensBought = launchpad.buyTokens{value: ethAmount}(tokenAddress, 1);

        // Verify tokens were bought
        assertGt(tokensBought, 0, "Buyer should receive tokens");
        assertEq(MemeToken(tokenAddress).balanceOf(buyer), tokensBought, "Buyer balance mismatch");

        // Verify non-creator's purchases are not tracked in creatorBoughtAmount
        assertEq(
            launchpad.creatorBoughtAmount(tokenAddress, buyer),
            0,
            "Non-creator purchases should not be tracked in creatorBoughtAmount"
        );

        // Note: We only perform a single buy here; the goal is to ensure
        // non-creator purchases are not subject to the creator buy limit
        // and are not tracked in creatorBoughtAmount.
    }

    function testCreatorBuyLimitBoundary() public {
        // This test verifies boundary conditions of the creator buy limit
        // It's similar to testCreatorCannotExceedBuyLimit but focuses on boundary behavior
        
        // Create token as creator
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("BoundaryToken", "BT", "Boundary metadata");

        // Calculate creator max buy: 140M tokens
        uint256 maxSupply = 1_000_000_000 * 1e18;
        uint256 bondingMax = (maxSupply * 70) / 100;
        uint256 creatorMaxBuy = (bondingMax * 20) / 100; // 140M tokens

        vm.deal(creator, 500000e18);
        vm.deal(treasury, 0);

        // Buy tokens in smaller chunks to avoid hitting limit unexpectedly
        uint256 purchaseCount = 0;
        uint256 ethPerPurchase = 2000e18; // Smaller purchases
        
        // Make purchases and verify limit is never exceeded
        for (uint256 i = 0; i < 150; i++) {
            uint256 currentBought = launchpad.creatorBoughtAmount(tokenAddress, creator);
            
            // If we're already at the limit, verify we can't buy more
            if (currentBought >= creatorMaxBuy) {
                vm.prank(creator);
                vm.expectRevert(MemeLaunchpad.CreatorBuyLimitExceeded.selector);
                launchpad.buyTokens{value: ethPerPurchase}(tokenAddress, 1);
                break;
            }
            
            // Calculate remaining capacity - if very small, use tiny purchase amount
            uint256 remainingCapacity = creatorMaxBuy - currentBought;
            uint256 purchaseAmount = ethPerPurchase;
            
            // Use very small amount when close to limit to avoid exceeding it
            if (remainingCapacity < 1e18) {
                purchaseAmount = 1e12; // Very small amount
            }
            
            // Try to buy tokens - if it would exceed limit, it will revert
            // We handle this by checking the result
            vm.prank(creator);
            
            // Use expectRevert if we're very close to limit
            if (remainingCapacity < 1e15) {
                vm.expectRevert(MemeLaunchpad.CreatorBuyLimitExceeded.selector);
                launchpad.buyTokens{value: purchaseAmount}(tokenAddress, 1);
                break;
            }
            
            // Otherwise, try to buy
            uint256 tokensBought = launchpad.buyTokens{value: purchaseAmount}(tokenAddress, 1);
            
            // Verify we got tokens
            assertGt(tokensBought, 0, "Should receive tokens");
            purchaseCount++;
            
            // Verify we haven't exceeded the limit
            uint256 newTotal = launchpad.creatorBoughtAmount(tokenAddress, creator);
            assertLe(newTotal, creatorMaxBuy, "Should never exceed creator buy limit");
            
            // If we've reached the limit, verify next purchase fails
            if (newTotal >= creatorMaxBuy) {
                vm.prank(creator);
                vm.expectRevert(MemeLaunchpad.CreatorBuyLimitExceeded.selector);
                launchpad.buyTokens{value: purchaseAmount}(tokenAddress, 1);
                break;
            }
        }
        
        // Verify we made purchases and respected the limit
        assertGt(purchaseCount, 0, "Should have made some purchases");
        uint256 finalBought = launchpad.creatorBoughtAmount(tokenAddress, creator);
        assertLe(finalBought, creatorMaxBuy, "Should never exceed limit");
    }

    function testCreatorBuyLimitDifferentTokens() public {
        // Create two tokens as creator
        vm.prank(creator);
        address tokenAddress1 = launchpad.createToken("Token1", "T1", "Metadata1");
        
        vm.prank(creator);
        address tokenAddress2 = launchpad.createToken("Token2", "T2", "Metadata2");

        vm.deal(creator, 10000e18);
        vm.deal(treasury, 0);

        // Buy tokens from first token
        vm.prank(creator);
        uint256 tokens1 = launchpad.buyTokens{value: 1000e18}(tokenAddress1, 1);

        // Buy tokens from second token
        vm.prank(creator);
        uint256 tokens2 = launchpad.buyTokens{value: 1000e18}(tokenAddress2, 1);

        // Verify limits are tracked per token
        assertEq(
            launchpad.creatorBoughtAmount(tokenAddress1, creator),
            tokens1,
            "First token limit should be tracked separately"
        );
        assertEq(
            launchpad.creatorBoughtAmount(tokenAddress2, creator),
            tokens2,
            "Second token limit should be tracked separately"
        );

        // Creator should have separate limits for each token
        assertGt(tokens1, 0, "Should buy from first token");
        assertGt(tokens2, 0, "Should buy from second token");
    }
}