// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./MemeToken.sol";

interface IDEXRouter {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

// ==================== EVENTS ====================

/**
 * @title MemeLaunchpad
 * @dev A bonding curve based token launchpad 
 */
contract MemeLaunchpad is Ownable, ReentrancyGuard {
    using Math for uint256;

    // Events
    event TokenCreated(
        address indexed tokenAddress,
        string name,
        string symbol,
        string metadata,
        address indexed creator,
        uint256 creatorAllocation
    );

    event TokensBought(
        address indexed tokenAddress,
        address indexed buyer,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 newPrice
    );

    event TokensSold(
        address indexed tokenAddress,
        address indexed seller,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 newPrice
    );

    event TokenCompleted(
        address indexed tokenAddress,
        uint256 finalSupply,
        uint256 finalPrice
    );

    event HeldTokensWithdrawn(
        address indexed tokenAddress,
        address indexed owner,
        uint256 amount
    );

    // Custom Errors
    error TokenLaunchCompleted();
    error MustSendETH();
    error NoTokensToBuy();
    error SlippageTooHigh();
    error ExceedsMaxSupply();
    error MustSellTokens();
    error NoEthToReceive();
    error InsufficientCirculatingSupply();

// ==================== STRUCTS ====================

    // Structs
    struct TokenInfo {
        string name;
        string symbol;
        string metadata;
        address creator;
        uint256 creatorAllocation; // Amount of tokens allocated to creator
        uint256 heldTokens; // Amount of tokens held in the contract
        uint256 maxSupply; // Maximum token supply before completion
        uint256 currentSupply; // Current token supply
        uint256 virtualTrust; // Virtual TRUST in the bonding curve
        uint256 virtualTokens; // Virtual tokens in the bonding curve
        bool completed; // Whether the token has reached completion
        uint256 creationTime;
    }

// ==================== CONSTANTS ====================

    // Constants
    uint256 public constant CREATOR_ALLOCATION_PERCENT = 0; // 0% for creator (no creator allocation)
    uint256 public constant BONDING_CURVE_PERCENT = 70; // 70% for bonding curve
    uint256 public constant HELD_PERCENT = 30; // 30% held in memelaunchpad
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18; // 1B tokens max
    uint256 public constant INITIAL_PRICE = 0.0001533e18; // Initial price in ETH
    uint256 public constant FEE_PERCENT = 1; // 1% fee

// ==================== STATE VARIABLES ====================

    // State variables
    mapping(address => TokenInfo) public tokenInfo;
    mapping(address => bool) public isValidToken;
    address[] public allTokens;

    // Treasury address for fees
    address public treasuryAddress;

    // DEX router for migration
    address public dexRouter;


// ==================== MODIFIERS ====================

    // Modifiers
    modifier onlyValidToken(address tokenAddress) {
        require(isValidToken[tokenAddress], "Invalid token");
        _;
    }

// ==================== CONSTRUCTOR ====================

    constructor(address _treasuryAddress, address _dexRouter) Ownable(msg.sender) {
        treasuryAddress = _treasuryAddress;
        dexRouter = _dexRouter;
    }

// ==================== TOKEN CREATION ====================

    /**
      * @dev Create a new meme token with bonding curve
      */
    function createToken(
        string memory name,
        string memory symbol,
        string memory metadata
    ) external returns (address) {
        require(bytes(name).length > 0, "Name required");
        require(bytes(symbol).length > 0, "Symbol required");
        uint256 totalSupply = MAX_SUPPLY;

        // Create the token contract
        MemeToken token = new MemeToken(name, symbol, totalSupply);

        // Set launchpad for minting permissions
        token.setLaunchpad(address(this));

        // Calculate allocations (70% bonding curve, 30% memelaunchpad, 0% creator)
        uint256 heldAmount = (totalSupply * HELD_PERCENT) / 100;

        // Initialize token info with simplified bonding curve
        tokenInfo[address(token)] = TokenInfo({
            name: name,
            symbol: symbol,
            metadata: metadata,
            creator: msg.sender,
            creatorAllocation: 0, // No creator allocation
            heldTokens: heldAmount,
            maxSupply: totalSupply,
            currentSupply: 0, // Start with 0 circulating supply
            virtualTrust: 0, // Not used in simplified curve
            virtualTokens: 0, // Not used in simplified curve
            completed: false,
            creationTime: block.timestamp
        });

        isValidToken[address(token)] = true;
        allTokens.push(address(token));

        // Mint allocations (no creator tokens)
        token.mint(address(this), heldAmount); // 30% held in memelaunchpad

        emit TokenCreated(address(token), name, symbol, metadata, msg.sender, 0);

        return address(token);
    }

// ==================== TOKEN BUYING ====================

    /**
      * @dev Buy tokens from the bonding curve using pump.fun style calculation
      */
    function buyTokens(address tokenAddress, uint256 minTokensOut)
        external
        payable
        nonReentrant
        onlyValidToken(tokenAddress)
        returns (uint256 tokensBought)
    {
        TokenInfo storage token = tokenInfo[tokenAddress];
        if (token.completed) revert TokenLaunchCompleted();
        if (msg.value == 0) revert MustSendETH();

        uint256 ethAmount = msg.value;

        // Simple linear bonding curve calculation
        // Price increases linearly with supply: price = basePrice * (1 + currentSupply/totalSupply)
        uint256 basePrice = INITIAL_PRICE;
        uint256 priceIncrease = (token.currentSupply * basePrice) / token.maxSupply;
        uint256 currentPrice = basePrice + priceIncrease;

        // Calculate tokens that can be bought with the ETH sent
        tokensBought = (ethAmount * 1e18) / currentPrice;

        if (tokensBought == 0) revert NoTokensToBuy();

        if (tokensBought < minTokensOut) revert SlippageTooHigh();
        uint256 bondingMax = (token.maxSupply * BONDING_CURVE_PERCENT) / 100;
        if (token.currentSupply + tokensBought > bondingMax) revert ExceedsMaxSupply();

        // Calculate fee
        uint256 fee = (ethAmount * FEE_PERCENT) / 100;

        // Update token info (simplified approach)
        uint256 ethAmountAfterFee = ethAmount - fee;
        // For linear curve, we don't need complex virtual token management
        token.currentSupply += tokensBought;

        // Check if token should be completed (when circulating supply reaches bonding max)
        if (token.currentSupply >= bondingMax && !token.completed) {
            token.completed = true;
            emit TokenCompleted(tokenAddress, token.currentSupply, getCurrentPrice(tokenAddress));
        }

        // Mint tokens to buyer
        MemeToken(tokenAddress).mint(msg.sender, tokensBought);

        // Send fee to treasury
        payable(treasuryAddress).transfer(fee);

        // Emit event with calculated price
        emit TokensBought(tokenAddress, msg.sender, ethAmountAfterFee, tokensBought, currentPrice);
        return tokensBought;
    }

// ==================== TOKEN SELLING ====================

    /**
       * @dev Approve tokens for selling (users must call this before sellTokens if not already approved)
       */
    function approveTokensForSelling(address tokenAddress, uint256 amount) external onlyValidToken(tokenAddress) {
        MemeToken(tokenAddress).approve(address(this), amount);
    }

    /**
       * @dev Sell tokens to the bonding curve using pump.fun style calculation
       */
    function sellTokens(
        address tokenAddress,
        uint256 tokenAmount
    ) external nonReentrant onlyValidToken(tokenAddress) returns (uint256 ethReceived) {
        TokenInfo storage token = tokenInfo[tokenAddress];
        if (token.completed) revert TokenLaunchCompleted();
        if (tokenAmount == 0) revert MustSellTokens();

        // Simple linear bonding curve calculation for selling
        // Price at time of sale: basePrice * (1 + currentSupply/totalSupply)
        uint256 basePrice = INITIAL_PRICE;
        uint256 priceIncrease = (token.currentSupply * basePrice) / token.maxSupply;
        uint256 currentPrice = basePrice + priceIncrease;

        // Calculate ETH to receive (before burning)
        uint256 calculatedEth = (tokenAmount * currentPrice) / 1e18;

        // Cap to available balance
        uint256 availableBalance = address(this).balance;
        ethReceived = calculatedEth > availableBalance ? availableBalance : calculatedEth;


        // Check if sufficient circulating supply
        if (token.currentSupply <= tokenAmount) revert InsufficientCirculatingSupply();

        // Update supply (simplified approach)
        token.currentSupply -= tokenAmount;

        // Burn tokens from seller
        MemeToken(tokenAddress).burnFrom(msg.sender, tokenAmount);

        // Calculate and deduct fee from received ETH
        uint256 fee = (ethReceived * FEE_PERCENT) / 100;
        uint256 ethAfterFee = ethReceived - fee;

        // Send ETH to seller (after fee deduction)
        payable(msg.sender).transfer(ethAfterFee);

        // Send fee to treasury
        payable(treasuryAddress).transfer(fee);

        // Emit event with calculated price
        emit TokensSold(tokenAddress, msg.sender, ethAfterFee, tokenAmount, currentPrice);
        return ethAfterFee;
    }

// ==================== PRICING ====================

    /**
      * @dev Get current price of a token based on pump.fun style bonding curve
      */
    function getCurrentPrice(address tokenAddress) public view onlyValidToken(tokenAddress) returns (uint256) {
        TokenInfo memory token = tokenInfo[tokenAddress];

        if (token.currentSupply == 0) {
            return INITIAL_PRICE;
        }

        // Linear bonding curve: price increases with supply
        // price = basePrice * (1 + currentSupply/maxSupply)
        uint256 basePrice = INITIAL_PRICE;
        uint256 priceIncrease = (token.currentSupply * basePrice) / token.maxSupply;
        return basePrice + priceIncrease;
    }

// ==================== UTILITY FUNCTIONS ====================

    /**
      * @dev Calculate tokens after buying using pump.fun integral formula
      * Formula: tokens_after = (tokens_before * trust_before) / (trust_before - trust_amount)
      */
    function calculateTokensAfterBuy(uint256 tokensBefore, uint256 trustBefore, uint256 trustAmount) public pure returns (uint256) {
        if (trustAmount == 0) return tokensBefore;
        uint256 trustAfter = trustBefore + trustAmount;
        return (tokensBefore * trustBefore) / trustAfter;
    }

    /**
     * @dev Calculate TRUST after selling using pump.fun integral formula
     * Formula: trust_after = (tokens_after * trust_before) / tokens_before
     */
    function calculateTrustAfterSell(uint256 tokensBefore, uint256 trustBefore, uint256 tokensAfter) public pure returns (uint256) {
        if (tokensAfter == tokensBefore) return trustBefore;
        return (tokensAfter * trustBefore) / tokensBefore;
    }

    /**
     * @dev Calculate token amount for given TRUST amount (legacy function for compatibility)
     */
    function calculateTokenAmount(uint256 trustAmount, uint256 currentPrice) public pure returns (uint256) {
        return (trustAmount * 1e18) / currentPrice;
    }

    /**
     * @dev Get token information
     */
    function getTokenInfo(address tokenAddress) external view returns (TokenInfo memory) {
        return tokenInfo[tokenAddress];
    }

    /**
     * @dev Get all tokens
     */
    function getAllTokens() external view returns (address[] memory) {
        return allTokens;
    }

    /**
     * @dev Get token count
     */
    function getTokenCount() external view returns (uint256) {
        return allTokens.length;
    }

// ==================== MIGRATION ====================

    /**
       * @dev Get held tokens for a token (for migration)
       */
    function getHeldTokens(address tokenAddress) public view onlyValidToken(tokenAddress) returns (uint256) {
        return tokenInfo[tokenAddress].heldTokens;
    }

    /**
       * @dev Approve DEX router to spend tokens (for migration)
       */
    function approveRouter(address tokenAddress, address router, uint256 amount) public onlyOwner onlyValidToken(tokenAddress) {
        MemeToken(tokenAddress).approve(router, amount);
    }

    /**
       * @dev Set held tokens (for migration)
       */
    function setHeldTokens(address tokenAddress, uint256 amount) public onlyOwner onlyValidToken(tokenAddress) {
        tokenInfo[tokenAddress].heldTokens = amount;
    }

    /**
       * @dev Migrate liquidity to DEX
       */
    function _migrateToDEX(address tokenAddress) internal {
        TokenInfo storage token = tokenInfo[tokenAddress];
        uint256 heldAmount = token.heldTokens;
        uint256 ethAmount = address(this).balance;
        require(heldAmount > 0 && ethAmount > 0, "No liquidity to migrate");
        require(dexRouter != address(0), "DEX router not set");

        // Approve the router to spend the tokens
        MemeToken(tokenAddress).approve(dexRouter, heldAmount);

        // Add liquidity to DEX
        IDEXRouter(dexRouter).addLiquidityETH{value: ethAmount}(
            tokenAddress,
            heldAmount,
            heldAmount,
            ethAmount,
            address(this),
            block.timestamp
        );

        // Set heldTokens to 0
        token.heldTokens = 0;
    }

// ==================== ADMIN FUNCTIONS ====================

    /**
       * @dev Complete token launch early (only owner)
       */
    function completeTokenLaunch(address tokenAddress) external onlyOwner onlyValidToken(tokenAddress) {
        TokenInfo storage token = tokenInfo[tokenAddress];
        require(!token.completed, "Already completed");

        // Migrate liquidity to DEX
        _migrateToDEX(tokenAddress);

        token.completed = true;
        emit TokenCompleted(tokenAddress, token.currentSupply, getCurrentPrice(tokenAddress));
    }

    /**
      * @dev Withdraw remaining balance after completion (only owner)
      */
    function withdrawRemainingBalance(address tokenAddress) external onlyOwner onlyValidToken(tokenAddress) nonReentrant {
        TokenInfo storage token = tokenInfo[tokenAddress];
        require(token.completed, "Token not completed yet");

        uint256 remainingBalance = address(this).balance;
        require(remainingBalance > 0, "No balance to withdraw");

        // Send remaining ETH to owner
        payable(owner()).transfer(remainingBalance);
    }


// ==================== HELD TOKENS WITHDRAWAL ====================

    /**
       * @dev Withdraw held tokens (only owner)
       */
    function withdrawHeldTokens(address tokenAddress) external onlyOwner onlyValidToken(tokenAddress) nonReentrant {
        TokenInfo storage token = tokenInfo[tokenAddress];
        uint256 amount = token.heldTokens;
        require(amount > 0, "No held tokens");

        // Transfer held tokens to owner
        bool success = MemeToken(tokenAddress).transfer(owner(), amount);
        require(success, "Transfer failed");

        // Update held tokens
        token.heldTokens = 0;

        emit HeldTokensWithdrawn(tokenAddress, owner(), amount);
    }

}

