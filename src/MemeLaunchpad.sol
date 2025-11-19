// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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

    event TokenCommented(
        address indexed tokenAddress,
        address indexed commenter,
        string comment,
        uint256 timestamp
    );

    event TokenUnlocked(
        address indexed tokenAddress,
        address indexed creator,
        uint256 creatorBoughtAmount
    );

    // Custom Errors
    error TokenLaunchCompleted();
    error MustSendETH();
    error NoTokensToBuy();
    error SlippageTooHigh();
    error ExceedsMaxSupply();
    error MustSellTokens();
    error InsufficientCirculatingSupply();
    error CreatorBuyLimitExceeded();
    error TokenLocked();

    // ==================== STRUCTS ====================

    struct TokenInfo {
        string name;
        string symbol;
        string metadata;
        address creator;
        uint256 heldTokens; // Amount of tokens held in the contract
        uint256 maxSupply; // Maximum token supply before completion
        uint256 currentSupply; // Current token supply
        bool completed; // Whether the token has reached completion
        uint256 creationTime;
    }

    struct Comment {
        address commenter;
        string text;
        uint256 timestamp;
    }

    // ==================== CONSTANTS ====================

    uint256 public constant BONDING_CURVE_PERCENT = 70; // 70% for bonding curve
    uint256 public constant HELD_PERCENT = 30; // 30% held in memelaunchpad
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18; // 1B tokens max
    uint256 public constant INITIAL_PRICE = 0.0001533e18; // Initial price in ETH
    uint256 public constant FEE_PERCENT = 1; // 1% fee
    uint256 public constant PRICE_STEP_SIZE = 10_000_000 * 1e18; // Price increases every 10M tokens (makes price increase significantly)
    uint256 public constant CREATOR_MAX_BUY_PERCENT = 20; // Creator can buy max 20% of bonding curve supply (140M tokens)
    uint256 public constant CREATOR_UNLOCK_THRESHOLD_PERCENT = 2; // Creator must buy 2% of max supply to unlock token
    uint256 public constant COMMENT_FEE = 0.025 ether; // Fee to comment on a token

    // ==================== STATE VARIABLES ====================
    
    mapping(address => TokenInfo) public tokenInfo;
    mapping(address => bool) public isValidToken;
    address[] public allTokens;

    // Track unique addresses that have ever purchased from the bonding curve per token
    mapping(address => address[]) private tokenHolders;
    mapping(address => mapping(address => bool)) private isTokenHolder;
    
     // Track comments per token
    mapping(address => Comment[]) private tokenComments;
    
    // Track creator purchases from bonding curve per token
    mapping(address => mapping(address => uint256)) public creatorBoughtAmount;

    // Track if a token is unlocked (once unlocked, stays unlocked)
    mapping(address => bool) public tokenUnlocked;

    // Treasury address for fees
    address public treasuryAddress;

    // Track total buy and sell volume (in ETH) per user
    struct UserVolume {
        uint256 totalBuyVolume;
        uint256 totalSellVolume;
    }

    mapping(address => UserVolume) public userVolumes;

    // Track total ETH traded (TVT) per token
    mapping(address => uint256) public tokenTotalValueTraded;

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

        // Initialize token info
        tokenInfo[address(token)] = TokenInfo({
            name: name,
            symbol: symbol,
            metadata: metadata,
            creator: msg.sender,
            heldTokens: heldAmount,
            maxSupply: totalSupply,
            currentSupply: 0,
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

        // Check if token is locked - only creator can buy if locked
        if (!tokenUnlocked[tokenAddress]) {
            if (msg.sender != token.creator) {
                revert TokenLocked();
            }
        }

        // Calculate current price using quadratic bonding curve
        uint256 currentPrice = _calculatePrice(token.currentSupply);

        // Calculate tokens that can be bought with the ETH sent
        tokensBought = (msg.value * 1e18) / currentPrice;
        if (tokensBought == 0) revert NoTokensToBuy();
        if (tokensBought < minTokensOut) revert SlippageTooHigh();

        uint256 bondingMax = (token.maxSupply * BONDING_CURVE_PERCENT) / 100;
        if (token.currentSupply + tokensBought > bondingMax) revert ExceedsMaxSupply();

        // Check creator buy limit (20% of bonding curve supply = 140M tokens)
        if (msg.sender == token.creator) {
            uint256 creatorMaxBuy = (bondingMax * CREATOR_MAX_BUY_PERCENT) / 100;
            if (creatorBoughtAmount[tokenAddress][msg.sender] + tokensBought > creatorMaxBuy) {
                revert CreatorBuyLimitExceeded();
            }
            creatorBoughtAmount[tokenAddress][msg.sender] += tokensBought;

            // Check if creator has reached unlock threshold (2% of max supply)
            if (!tokenUnlocked[tokenAddress]) {
                uint256 unlockThreshold = (token.maxSupply * CREATOR_UNLOCK_THRESHOLD_PERCENT) / 100;
                if (creatorBoughtAmount[tokenAddress][msg.sender] >= unlockThreshold) {
                    tokenUnlocked[tokenAddress] = true;
                    emit TokenUnlocked(tokenAddress, msg.sender, creatorBoughtAmount[tokenAddress][msg.sender]);
                }
            }
        }

        // Calculate fee and update supply
        uint256 fee = (msg.value * FEE_PERCENT) / 100;
        token.currentSupply += tokensBought;

        // Check if token should be completed (when circulating supply reaches bonding max)
        if (token.currentSupply >= bondingMax && !token.completed) {
            token.completed = true;
            uint256 finalPrice = _calculatePrice(token.currentSupply);
            _finalizeTokenCompletion(tokenAddress);
            emit TokenCompleted(tokenAddress, token.currentSupply, finalPrice);
        }

        // Mint tokens to buyer
        MemeToken(tokenAddress).mint(msg.sender, tokensBought);

        // Track unique holders that have ever bought from the bonding curve
        if (!isTokenHolder[tokenAddress][msg.sender]) {
            isTokenHolder[tokenAddress][msg.sender] = true;
            tokenHolders[tokenAddress].push(msg.sender);
        }
        
        // Send fee to treasury
        payable(treasuryAddress).transfer(fee);

        // Track user buy volume (in ETH)
        userVolumes[msg.sender].totalBuyVolume += msg.value;

        // Track total value traded (TVT) for this token (ETH amount after fee)
        tokenTotalValueTraded[tokenAddress] += (msg.value - fee);

        // Emit event with calculated price
        emit TokensBought(tokenAddress, msg.sender, msg.value - fee, tokensBought, currentPrice);
        return tokensBought;
    }

    // ==================== TOKEN SELLING ====================

    /**
       * @dev Sell tokens to the bonding curve using pump.fun style calculation
       * Note: Users must approve this contract to spend their tokens first
       * Note: Selling is allowed even when token is locked (creator can sell before reaching 2% unlock threshold)
       */
    function sellTokens(
        address tokenAddress,
        uint256 tokenAmount
    ) external nonReentrant onlyValidToken(tokenAddress) returns (uint256 ethReceived) {
        TokenInfo storage token = tokenInfo[tokenAddress];
        if (token.completed) revert TokenLaunchCompleted();
        if (tokenAmount == 0) revert MustSellTokens();

        // Calculate current price using quadratic bonding curve
        uint256 currentPrice = _calculatePrice(token.currentSupply);

        // Calculate ETH to receive (before burning) and cap to available balance
        uint256 calculatedEth = (tokenAmount * currentPrice) / 1e18;
        ethReceived = calculatedEth > address(this).balance ? address(this).balance : calculatedEth;

        // Check if sufficient circulating supply
        if (token.currentSupply <= tokenAmount) revert InsufficientCirculatingSupply();

        // Update supply and burn tokens
        token.currentSupply -= tokenAmount;
        MemeToken(tokenAddress).burnFrom(msg.sender, tokenAmount);

        // Calculate fee and send ETH
        uint256 fee = (ethReceived * FEE_PERCENT) / 100;
        uint256 netEth = ethReceived - fee;
        payable(msg.sender).transfer(netEth);
        payable(treasuryAddress).transfer(fee);

        // Track user sell volume (in ETH)
        userVolumes[msg.sender].totalSellVolume += netEth;

        // Track total value traded (TVT) for this token (ETH amount after fee)
        tokenTotalValueTraded[tokenAddress] += netEth;

        // Emit event with calculated price
        emit TokensSold(tokenAddress, msg.sender, netEth, tokenAmount, currentPrice);
        return netEth;
    }

    // ==================== PRICING ====================

    /**
      * @dev Calculate price based on current supply using quadratic bonding curve
      * Price formula: price = INITIAL_PRICE * (1 + (currentSupply / PRICE_STEP_SIZE)^2)
      */
    function _calculatePrice(uint256 currentSupply) internal pure returns (uint256) {
        if (currentSupply == 0) {
            return INITIAL_PRICE;
        }
        uint256 supplyRatio = (currentSupply * 1e18) / PRICE_STEP_SIZE;
        return (INITIAL_PRICE * (1e18 + (supplyRatio * supplyRatio) / 1e18)) / 1e18;
    }

    /**
      * @dev Get current price of a token based on aggressive quadratic bonding curve
      */
    function getCurrentPrice(address tokenAddress) public view onlyValidToken(tokenAddress) returns (uint256) {
        return _calculatePrice(tokenInfo[tokenAddress].currentSupply);
    }

    // ==================== UTILITY FUNCTIONS ====================

    /**
     * @dev Get token information
     */
    function getTokenInfo(address tokenAddress) external view returns (TokenInfo memory) {
        return tokenInfo[tokenAddress];
    }

    /**
     * @dev Add a comment on a specific meme token.
     * Requires paying the fixed COMMENT_FEE, which is forwarded to the treasury.
     */
    function addComment(address tokenAddress, string calldata commentText)
        external
        payable
        nonReentrant
        onlyValidToken(tokenAddress)
    {
        require(msg.value == COMMENT_FEE, "Incorrect comment fee");
        require(bytes(commentText).length > 0, "Comment required");

        tokenComments[tokenAddress].push(
            Comment({
                commenter: msg.sender,
                text: commentText,
                timestamp: block.timestamp
            })
        );

        // Forward fee to treasury
        payable(treasuryAddress).transfer(msg.value);

        emit TokenCommented(tokenAddress, msg.sender, commentText, block.timestamp);
    }

    /**
     * @dev Get all comments for a specific meme token.
     * NOTE: This returns all stored comments on-chain and may become large over time.
     */
    function getComments(address tokenAddress)
        external
        view
        onlyValidToken(tokenAddress)
        returns (Comment[] memory)
    {
        return tokenComments[tokenAddress];
    }

    /**
     * @dev Get user volume statistics (total ETH spent buying / received selling)
     */
    function getUserVolume(address user) external view returns (uint256 buyVolume, uint256 sellVolume) {
        UserVolume memory volume = userVolumes[user];
        return (volume.totalBuyVolume, volume.totalSellVolume);
    }

    /**
     * @dev Get all tokens (required by tests)
     */
    function getAllTokens() external view returns (address[] memory) {
        return allTokens;
    }

    /**
     * @dev Get all addresses that have ever bought from the bonding curve for a token
     * NOTE: This returns addresses that have interacted with the launchpad's bonding curve.
     * It does not guarantee that each address currently holds a non-zero token balance,
     * nor does it include addresses that only acquired tokens via peer-to-peer transfers
     * or on external DEXes after migration.
     */
    function getTokenHolders(address tokenAddress)
        external
        view
        onlyValidToken(tokenAddress)
        returns (address[] memory)
    {
        return tokenHolders[tokenAddress];
    }

    /**
     * @dev Get the Total Value Traded (TVT) for a specific token
     * @param tokenAddress The address of the meme token
     * @return The total ETH value traded for this token (after fees)
     */
    function getTokenTVT(address tokenAddress)
        external
        view
        onlyValidToken(tokenAddress)
        returns (uint256)
    {
        return tokenTotalValueTraded[tokenAddress];
    }

    /**
     * @dev Get the Total Value Traded (TVT) across all meme tokens on the launchpad
     * @return The total ETH value traded across all tokens (after fees)
     */
    function getTotalTVT() external view returns (uint256) {
        uint256 total = 0;
        uint256 tokenCount = allTokens.length;
        for (uint256 i = 0; i < tokenCount; i++) {
            total += tokenTotalValueTraded[allTokens[i]];
        }
        return total;
    }
    
    // Other view functions removed to reduce contract size - can be computed off-chain from events

    // ==================== MIGRATION ====================

    /**
       * @dev Get held tokens for a token (required by DEXMigrator)
       */
    function getHeldTokens(address tokenAddress) external view onlyValidToken(tokenAddress) returns (uint256) {
        return tokenInfo[tokenAddress].heldTokens;
    }

    /**
       * @dev Approve DEX router to spend tokens (required by DEXMigrator)
       */
    function approveRouter(address tokenAddress, address router, uint256 amount) external onlyOwner onlyValidToken(tokenAddress) {
        MemeToken(tokenAddress).approve(router, amount);
    }

    /**
       * @dev Set held tokens (required by DEXMigrator)
       */
    function setHeldTokens(address tokenAddress, uint256 amount) external onlyOwner onlyValidToken(tokenAddress) {
        tokenInfo[tokenAddress].heldTokens = amount;
    }

    /**
       * @dev Finalize token completion: burn leftover bonding curve tokens and migrate liquidity to DEX
       * Only MemeLaunchpad contract can call this (internal function)
       * This function:
       * 1. Burns any leftover tokens the contract holds beyond what's needed for DEX migration
       * 2. Migrates liquidity (heldTokens + ETH) to DEX
       * 3. Ensures trading on bonding curve has stopped (token.completed = true)
       */
    function _finalizeTokenCompletion(address tokenAddress) internal {
        TokenInfo storage token = tokenInfo[tokenAddress];
        MemeToken tokenContract = MemeToken(tokenAddress);
        
        // Get contract's token balance
        uint256 contractBalance = tokenContract.balanceOf(address(this));
        uint256 heldTokens = token.heldTokens;
        
        // Burn any excess tokens the contract holds beyond heldTokens
        // This represents any leftover tokens that shouldn't be in the bonding curve
        // heldTokens are reserved for DEX migration, anything beyond that should be burned
        if (contractBalance > heldTokens) {
            uint256 excessTokens = contractBalance - heldTokens;
            tokenContract.burn(excessTokens);
        }
        
        // Migrate liquidity to DEX (only MemeLaunchpad can do this via internal call)
        _migrateToDEX(tokenAddress);
    }

    /**
       * @dev Migrate liquidity to DEX
       * Only callable internally by MemeLaunchpad contract
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
       * This stops all trading on the bonding curve and migrates liquidity to DEX
       */
    function completeTokenLaunch(address tokenAddress) external onlyOwner onlyValidToken(tokenAddress) {
        TokenInfo storage token = tokenInfo[tokenAddress];
        require(!token.completed, "Already completed");

        // Mark as completed first to stop trading
        token.completed = true;
        
        // Finalize completion: burn leftover tokens and migrate liquidity
        uint256 finalPrice = _calculatePrice(token.currentSupply);
        _finalizeTokenCompletion(tokenAddress);
        emit TokenCompleted(tokenAddress, token.currentSupply, finalPrice);
    }

    // Removed withdrawRemainingBalance - all ETH should be migrated to DEX on completion

}
