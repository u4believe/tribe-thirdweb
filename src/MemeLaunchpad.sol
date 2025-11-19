// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./MemeToken.sol";

/**
 * @notice Interface for DEX router to add liquidity
 * @dev Used for migrating tokens to decentralized exchanges after launch completion
 */
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

/**
 * @title MemeLaunchpad
 * @notice Main contract for creating and managing meme tokens with bonding curve mechanics
 * @dev Implements a pump.fun-style bonding curve where tokens can be bought/sold before DEX migration
 */
contract MemeLaunchpad {
    // ==================== ACCESS CONTROL ====================
    
    /// @notice Owner address for admin functions
    address private _owner;
    
    /// @notice Restricts function access to contract owner only
    modifier onlyOwner() {
        require(msg.sender == _owner, "Not owner");
        _;
    }
    
    // ==================== REENTRANCY PROTECTION ====================
    
    /// @notice Reentrancy guard status (1 = not entered, 2 = entered)
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    
    /// @notice Prevents reentrant calls to protected functions
    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

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

    // ==================== CUSTOM ERRORS ====================
    
    error TokenLaunchCompleted();           // Token has reached max supply and completed
    error MustSendETH();                   // No ETH sent with buy transaction
    error NoTokensToBuy();                 // Calculated token amount is zero
    error SlippageTooHigh();                // Received tokens less than minimum expected
    error ExceedsMaxSupply();               // Purchase would exceed bonding curve max supply
    error MustSellTokens();                 // No tokens specified to sell
    error InsufficientCirculatingSupply();  // Not enough circulating supply to sell
    error CreatorBuyLimitExceeded();       // Creator exceeded their buy limit (20% of bonding curve)
    error TokenLocked();                    // Token is locked until creator buys 2% of max supply

    // ==================== STRUCTS ====================
    
    /// @notice Stores information about each created token
    struct TokenInfo {
        string name;              // Token name
        string symbol;            // Token symbol
        string metadata;          // Token metadata/description
        address creator;          // Address of token creator
        uint256 heldTokens;       // Tokens held by contract (30% of max supply)
        uint256 maxSupply;        // Maximum token supply (1 billion)
        uint256 currentSupply;    // Current circulating supply from bonding curve
        bool completed;           // Whether token launch has completed
        uint256 creationTime;     // Timestamp when token was created
    }

    /// @notice Stores comment information for tokens
    struct Comment {
        address commenter;        // Address of user who commented
        string text;              // Comment text
        uint256 timestamp;        // When comment was made
    }

    // ==================== CONSTANTS ====================
    
    uint256 public constant BONDING_CURVE_PERCENT = 70;              // 70% of supply for bonding curve
    uint256 public constant HELD_PERCENT = 30;                      // 30% of supply held by contract
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;      // 1 billion tokens max supply
    uint256 public constant INITIAL_PRICE = 0.0001533e18;           // Initial price per token in ETH
    uint256 public constant FEE_PERCENT = 2;                         // 2% fee on buy/sell transactions
    uint256 public constant PRICE_STEP_SIZE = 10_000_000 * 1e18;    // Price increases every 10M tokens
    uint256 public constant CREATOR_MAX_BUY_PERCENT = 20;           // Creator can buy max 20% of bonding curve
    uint256 public constant CREATOR_UNLOCK_THRESHOLD_PERCENT = 2;   // Creator must buy 2% to unlock token
    uint256 public constant COMMENT_FEE = 0.025 ether;              // Fee required to comment on tokens 
    
    // ==================== STATE VARIABLES ====================
    
    /// @notice Maps token address to its information
    mapping(address => TokenInfo) public tokenInfo;
    
    /// @notice Tracks which token addresses are valid
    mapping(address => bool) public isValidToken;
    
    /// @notice Array of all created token addresses
    address[] public allTokens;

    /// @notice Tracks unique addresses that have purchased tokens per token
    mapping(address => address[]) private tokenHolders;
    
    /// @notice Quick lookup to check if address has purchased from bonding curve
    mapping(address => mapping(address => bool)) private isTokenHolder;
    
    /// @notice Stores comments for each token
    mapping(address => Comment[]) private tokenComments;
    
    /// @notice Tracks how much each creator has bought from bonding curve
    mapping(address => mapping(address => uint256)) public creatorBoughtAmount;

    /// @notice Tracks if a token is unlocked (once unlocked, stays unlocked)
    mapping(address => bool) public tokenUnlocked;

    /// @notice Treasury address that receives fees
    address public treasuryAddress;

    /// @notice Tracks user trading volumes
    struct UserVolume {
        uint256 totalBuyVolume;   // Total ETH spent buying tokens
        uint256 totalSellVolume;  // Total ETH received selling tokens
    }

    /// @notice Maps user address to their trading volume
    mapping(address => UserVolume) public userVolumes;

    /// @notice Tracks total value traded (TVT) per token in ETH
    mapping(address => uint256) public tokenTotalValueTraded;

    /// @notice DEX router address for liquidity migration
    address public dexRouter;

    // ==================== MODIFIERS ====================
    
    /// @notice Validates that the token address is a valid token created through this launchpad
    modifier onlyValidToken(address tokenAddress) {
        require(isValidToken[tokenAddress], "Invalid");
        _;
    }

    // ==================== CONSTRUCTOR ====================
    
    /**
     * @notice Initializes the MemeLaunchpad contract
     * @param _treasuryAddress Address that will receive all fees
     * @param _dexRouter Address of DEX router for liquidity migration
     */
    constructor(address _treasuryAddress, address _dexRouter) {
        _owner = msg.sender;
        _status = _NOT_ENTERED;
        treasuryAddress = _treasuryAddress;
        dexRouter = _dexRouter;
    }
    
    // ==================== OWNER FUNCTIONS ====================
    
    /// @notice Returns the current owner address
    function owner() external view returns (address) {
        return _owner;
    }
    
    /// @notice Transfers ownership to a new address
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        _owner = newOwner;
    }

    // ==================== TOKEN CREATION ====================
    
    /**
     * @notice Creates a new meme token with bonding curve mechanics
     * @dev Creates token with 70% for bonding curve, 30% held by contract
     * @param name Token name
     * @param symbol Token symbol
     * @param metadata Token description/metadata
     * @return Address of the newly created token
     */
    function createToken(
        string memory name,
        string memory symbol,
        string memory metadata
    ) external returns (address) {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, "Invalid");
        uint256 totalSupply = MAX_SUPPLY;

        // Deploy new MemeToken contract
        MemeToken token = new MemeToken(name, symbol, totalSupply);

        // Set this contract as the launchpad (allows minting)
        token.setLaunchpad(address(this));

        // Calculate 30% of supply to be held by contract
        uint256 heldAmount = (totalSupply * HELD_PERCENT) / 100;

        // Store token information
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

        // Mark token as valid and add to list
        isValidToken[address(token)] = true;
        allTokens.push(address(token));

        // Mint the 30% held tokens to this contract
        token.mint(address(this), heldAmount); 

        emit TokenCreated(address(token), name, symbol, metadata, msg.sender, 0);

        return address(token);
    }

    // ==================== TOKEN BUYING ====================
    
    /**
     * @notice Buy tokens from the bonding curve
     * @dev Uses quadratic bonding curve pricing. Token must be unlocked unless buyer is creator.
     * @param tokenAddress Address of the token to buy
     * @param minTokensOut Minimum tokens expected (slippage protection)
     * @return tokensBought Amount of tokens purchased
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

        // Check if purchase would exceed bonding curve max supply (70% of total)
        uint256 bondingMax = (token.maxSupply * BONDING_CURVE_PERCENT) / 100;
        if (token.currentSupply + tokensBought > bondingMax) revert ExceedsMaxSupply();

        // Handle creator-specific logic (buy limits and unlock mechanism)
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

        // Check if token should be completed (reached bonding curve max)
        if (token.currentSupply >= bondingMax && !token.completed) {
            token.completed = true;
            uint256 finalPrice = _calculatePrice(token.currentSupply);
            _finalizeTokenCompletion(tokenAddress);
            emit TokenCompleted(tokenAddress, token.currentSupply, finalPrice);
        }

        // Mint tokens to buyer
        MemeToken(tokenAddress).mint(msg.sender, tokensBought);

        // Track unique holders
        if (!isTokenHolder[tokenAddress][msg.sender]) {
            isTokenHolder[tokenAddress][msg.sender] = true;
            tokenHolders[tokenAddress].push(msg.sender);
        }
        
        // Send fee to treasury
        payable(treasuryAddress).transfer(fee);

        // Update volume tracking
        userVolumes[msg.sender].totalBuyVolume += msg.value;
        tokenTotalValueTraded[tokenAddress] += (msg.value - fee);

        emit TokensBought(tokenAddress, msg.sender, msg.value - fee, tokensBought, currentPrice);
        return tokensBought;
    }

    // ==================== TOKEN SELLING ====================
    
    /**
     * @notice Sell tokens back to the bonding curve
     * @dev User must approve this contract to spend their tokens first
     * @param tokenAddress Address of the token to sell
     * @param tokenAmount Amount of tokens to sell
     * @return ethReceived Net ETH received after fees
     */
    function sellTokens(
        address tokenAddress,
        uint256 tokenAmount
    ) external nonReentrant onlyValidToken(tokenAddress) returns (uint256 ethReceived) {
        TokenInfo storage token = tokenInfo[tokenAddress];
        if (token.completed) revert TokenLaunchCompleted();
        if (tokenAmount == 0) revert MustSellTokens();

        // Calculate current price and ETH to receive
        uint256 currentPrice = _calculatePrice(token.currentSupply);
        uint256 calculatedEth = (tokenAmount * currentPrice) / 1e18;
        
        // Cap to available contract balance (safety check)
        ethReceived = calculatedEth > address(this).balance ? address(this).balance : calculatedEth;

        // Ensure sufficient circulating supply
        if (token.currentSupply <= tokenAmount) revert InsufficientCirculatingSupply();

        // Update supply and burn tokens
        token.currentSupply -= tokenAmount;
        MemeToken(tokenAddress).burnFrom(msg.sender, tokenAmount);

        // Calculate fee and transfer ETH
        uint256 fee = (ethReceived * FEE_PERCENT) / 100;
        uint256 netEth = ethReceived - fee;
        payable(msg.sender).transfer(netEth);
        payable(treasuryAddress).transfer(fee);

        // Update volume tracking
        userVolumes[msg.sender].totalSellVolume += netEth;
        tokenTotalValueTraded[tokenAddress] += netEth;

        emit TokensSold(tokenAddress, msg.sender, netEth, tokenAmount, currentPrice);
        return netEth;
    }

    // ==================== PRICING ====================
    
    /**
     * @notice Calculates the current price using quadratic bonding curve
     * @dev Price increases quadratically based on supply: price = initialPrice * (1 + (supply/stepSize)^2)
     * @param currentSupply Current circulating supply of tokens
     * @return Current price per token in ETH
     */
    function _calculatePrice(uint256 currentSupply) internal pure returns (uint256) {
        if (currentSupply == 0) {
            return INITIAL_PRICE;
        }
        uint256 supplyRatio = (currentSupply * 1e18) / PRICE_STEP_SIZE;
        return (INITIAL_PRICE * (1e18 + (supplyRatio * supplyRatio) / 1e18)) / 1e18;
    }

    /**
     * @notice Get the current price for a token
     * @param tokenAddress Address of the token
     * @return Current price per token in ETH
     */
    function getCurrentPrice(address tokenAddress) public view onlyValidToken(tokenAddress) returns (uint256) {
        return _calculatePrice(tokenInfo[tokenAddress].currentSupply);
    }

    // ==================== UTILITY FUNCTIONS ====================
    
    /**
     * @notice Get token information
     * @param tokenAddress Address of the token
     * @return TokenInfo struct containing all token details
     */
    function getTokenInfo(address tokenAddress) external view returns (TokenInfo memory) {
        return tokenInfo[tokenAddress];
    }

    // ==================== COMMENT SYSTEM ====================
    
    /**
     * @notice Add a comment to a token (requires exact fee)
     * @dev User must send exactly COMMENT_FEE with the transaction
     * @param tokenAddress Address of the token to comment on
     * @param commentText The comment text
     */
    function addComment(address tokenAddress, string calldata commentText)
        external
        payable
        nonReentrant
        onlyValidToken(tokenAddress)
    {
        require(bytes(commentText).length > 0, "Invalid comment");
        require(msg.value == COMMENT_FEE, "Exact fee required");

        // Store comment
        tokenComments[tokenAddress].push(
            Comment({
                commenter: msg.sender,
                text: commentText,
                timestamp: block.timestamp
            })
        );

        // Transfer fee to treasury
        payable(treasuryAddress).transfer(COMMENT_FEE);

        emit TokenCommented(tokenAddress, msg.sender, commentText, block.timestamp);
    }

    /**
     * @notice Get all comments for a token
     * @param tokenAddress Address of the token
     * @return Array of Comment structs
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
     * @notice Get user's trading volume
     * @param user Address of the user
     * @return buyVolume Total ETH spent buying tokens
     * @return sellVolume Total ETH received selling tokens
     */
    function getUserVolume(address user) external view returns (uint256 buyVolume, uint256 sellVolume) {
        UserVolume storage volume = userVolumes[user];
        return (volume.totalBuyVolume, volume.totalSellVolume);
    }

    /**
     * @notice Get all created token addresses
     * @return Array of all token addresses
     */
    function getAllTokens() external view returns (address[] memory) {
        return allTokens;
    }

    /**
     * @notice Get all addresses that have purchased from bonding curve
     * @param tokenAddress Address of the token
     * @return Array of holder addresses
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
     * @notice Get total value traded (TVT) for a specific token
     * @param tokenAddress Address of the token
     * @return Total ETH traded for this token
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
     * @notice Get total value traded across all tokens
     * @return total Total ETH traded across all tokens
     */
    function getTotalTVT() external view returns (uint256 total) {
        uint256 tokenCount = allTokens.length;
        for (uint256 i = 0; i < tokenCount; i++) {
            total += tokenTotalValueTraded[allTokens[i]];
        }
    }

    /**
     * @notice Get held tokens amount for a token
     * @param tokenAddress Address of the token
     * @return Amount of tokens held by contract
     */
    function getHeldTokens(address tokenAddress) external view onlyValidToken(tokenAddress) returns (uint256) {
        return tokenInfo[tokenAddress].heldTokens;
    }

    // ==================== ADMIN FUNCTIONS ====================
    
    /**
     * @notice Approve router to spend tokens (for DEX migration)
     * @param tokenAddress Address of the token
     * @param router Address of the DEX router
     * @param amount Amount to approve
     */
    function approveRouter(address tokenAddress, address router, uint256 amount) external onlyOwner onlyValidToken(tokenAddress) {
        MemeToken(tokenAddress).approve(router, amount);
    }


    // ==================== TOKEN COMPLETION & MIGRATION ====================
    
    /**
     * @notice Finalizes token completion: migrates all liquidity to DEX
     * @dev Called automatically when bonding curve reaches max or manually by owner
     *      Migrates all held tokens (30% of max supply) and all accumulated ETH to DEX
     * @param tokenAddress Address of the token to finalize
     */
    function _finalizeTokenCompletion(address tokenAddress) internal {
        // Migrate all liquidity to DEX (all held tokens + all ETH balance)
        _migrateToDEX(tokenAddress);
    }

    /**
     * @notice Migrates token liquidity to a DEX (Uniswap, etc.)
     * @dev Adds liquidity using all held tokens (30% of max supply) and all accumulated ETH
     * @param tokenAddress Address of the token to migrate
     */
    function _migrateToDEX(address tokenAddress) internal {
        TokenInfo storage token = tokenInfo[tokenAddress];
        MemeToken tokenContract = MemeToken(tokenAddress);
        
        // Get all tokens held by contract (should be 30% of max supply)
        uint256 tokenAmount = tokenContract.balanceOf(address(this));
        uint256 ethAmount = address(this).balance;
        
        require(tokenAmount > 0 && ethAmount > 0, "No liquidity to migrate");
        require(dexRouter != address(0), "DEX router not set");

        // Approve router to spend all tokens
        tokenContract.approve(dexRouter, tokenAmount);

        // Add liquidity to DEX with all tokens and all ETH
        IDEXRouter(dexRouter).addLiquidityETH{value: ethAmount}(
            tokenAddress,
            tokenAmount,
            tokenAmount,     // Min tokens (slippage protection)
            ethAmount,       // Min ETH (slippage protection)
            address(this),  // LP tokens go to this contract
            block.timestamp
        );

        // Mark held tokens as migrated
        token.heldTokens = 0;
    }

    /**
     * @notice Manually complete a token launch (owner only)
     * @dev Allows owner to force completion before reaching max supply
     * @param tokenAddress Address of the token to complete
     */
    function completeTokenLaunch(address tokenAddress) external onlyOwner onlyValidToken(tokenAddress) {
        TokenInfo storage token = tokenInfo[tokenAddress];
        require(!token.completed, "Completed");

        token.completed = true;
        
        uint256 finalPrice = _calculatePrice(token.currentSupply);
        _finalizeTokenCompletion(tokenAddress);
        emit TokenCompleted(tokenAddress, token.currentSupply, finalPrice);
    }

}
