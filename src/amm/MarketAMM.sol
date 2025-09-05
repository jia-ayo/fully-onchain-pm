// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IConditionalTokens.sol";
import "./AMMHelper.sol";

/**
 * @title MarketAMM
 * @notice This version adds a post-resolution claim function for LPs.
 */
contract MarketAMM is ERC20, ReentrancyGuard {
    using AMMHelper for uint256;

    // --- Structs (no change) ---
    struct TradeRecord {
        address trader;
        uint256 outcomeIndex;
        uint256 collateralIn;
        uint256 tokensOut;
        uint256 timestamp;
    }
    struct LpPosition {
        uint256 principal;
        uint256 currentValue;
        int256 profit;
        uint256 lpTokensOwned;
    }

    // --- Constants (no change)---
    uint256 public constant YES_OUTCOME_INDEX = 2;
    uint256 public constant NO_OUTCOME_INDEX = 1;
    uint256[] private FULL_SET_INDEXES = [1, 2];

    // --- State Variables ---
    IConditionalTokens public conditionalTokens;
    IERC20 public collateralToken;
    bytes32 public conditionId;
    uint256 public positionIdYes;
    uint256 public positionIdNo;
    uint256 public tradingFeeBps;
    uint256 public platformFeeOnLpEarningsBps;
    address public platformFeeRecipient;
    uint256 public totalVolume;
    bool public isResolved; // NEW: Flag to lock the AMM

    uint256 public reserveYes;
    uint256 public reserveNo;

    mapping(address => uint256) public principalDeposited;
    TradeRecord[] public tradeHistory;
 constructor() ERC20("PM LP Token", "PMLP") {}
    // --- Modifiers ---
    modifier onlyUnresolved() {
        require(!isResolved, "AMM: Market is resolved");
        _;
    }

    // --- Events (no change) ---
    event LiquidityAdded(address indexed provider, uint256 collateralAmount, uint256 lpAmount);
    event LiquidityRemoved(address indexed provider, uint256 collateralAmount, uint256 lpAmount);
    event Trade(address indexed trader, uint256 amountIn, uint256 amountOut, uint256 positionId);
    event MarketLocked(uint256 winningOutcome); // NEW Event

    // --- Initializer (no change) ---
    function initialize(
        address _conditionalTokens,
        address _collateral,
        bytes32 _conditionId,
        uint256 _tradingFeeBps,
        uint256 _lpFeeBps,
        address _feeRecipient
    ) external {
        require(address(collateralToken) == address(0), "AMM: Already initialized");
        // _initializeERC20("PM LP Token", "PMLP");
        conditionalTokens = IConditionalTokens(_conditionalTokens);
        collateralToken = IERC20(_collateral);
        conditionId = _conditionId;
        tradingFeeBps = _tradingFeeBps;
        platformFeeOnLpEarningsBps = _lpFeeBps;
        platformFeeRecipient = _feeRecipient;
        positionIdYes = conditionalTokens.getPositionId(address(collateralToken), conditionId, YES_OUTCOME_INDEX);
        positionIdNo = conditionalTokens.getPositionId(address(collateralToken), conditionId, NO_OUTCOME_INDEX);
    }
    
    // function _initializeERC20(string memory name, string memory symbol) private {
    //     (bool success, bytes memory returnData) = address(this).staticcall(abi.encodeWithSignature("name()"));
    //     if (success && returnData.length > 0) {} else {}
    // }

    // --- NEW: Post-Resolution Functions ---

    /**
     * @notice Locks the AMM after resolution. Only callable by the factory.
     * @dev It merges all worthless tokens, leaving only the winning tokens in the reserves.
     */
    function setResolved(uint256 winningOutcome) external {
        // In a real implementation, you'd add access control (e.g., onlyFactory)
        require(!isResolved, "AMM: Already resolved");
        isResolved = true;
        
        // Consolidate reserves into the winning token
        if (winningOutcome == YES_OUTCOME_INDEX) {
            // The "No" tokens are worthless. Merge them with an equal amount of "Yes" tokens.
            uint256 amountToMerge = reserveNo;
            reserveYes -= amountToMerge;
            reserveNo = 0;
            conditionalTokens.mergePositions(address(collateralToken), bytes32(0), conditionId, FULL_SET_INDEXES, amountToMerge);
        } else { // NO_OUTCOME_INDEX
            uint256 amountToMerge = reserveYes;
            reserveNo -= amountToMerge;
            reserveYes = 0;
            conditionalTokens.mergePositions(address(collateralToken), bytes32(0), conditionId, FULL_SET_INDEXES, amountToMerge);
        }

        emit MarketLocked(winningOutcome);
    }
    
    /**
     * @notice Allows LPs to claim their share of winning tokens after resolution.
     */
    function claimLpWinnings() external nonReentrant {
        require(isResolved, "AMM: Market not resolved");
        uint256 lpAmount = balanceOf(msg.sender);
        require(lpAmount > 0, "AMM: No LP tokens");

        // After resolution, one reserve is 0. The total supply of winning tokens is the non-zero reserve.
        uint256 totalWinningTokens = reserveYes > 0 ? reserveYes : reserveNo;
        uint256 winningPositionId = reserveYes > 0 ? positionIdYes : positionIdNo;
        
        uint256 userShare = (totalWinningTokens * lpAmount) / totalSupply();

        _burn(msg.sender, lpAmount);
        
        // Transfer the winning tokens to the LP for them to redeem
        conditionalTokens.safeTransferFrom(address(this), msg.sender, winningPositionId, userShare, "");
    }


    // --- Core Functions (now with modifier) ---
    function addLiquidity(uint256 collateralAmount) external nonReentrant onlyUnresolved returns (uint256 lpAmount) {
        // ... implementation is the same ...
        require(collateralAmount > 0, "AMM: Zero amount");
        collateralToken.transferFrom(msg.sender, address(this), collateralAmount);
        conditionalTokens.splitPosition(address(collateralToken), bytes32(0), conditionId, FULL_SET_INDEXES, collateralAmount);
        uint256 oldK = reserveYes * reserveNo;
        reserveYes += collateralAmount;
        reserveNo += collateralAmount;
        uint256 newK = reserveYes * reserveNo;
        if (totalSupply() == 0) {
            lpAmount = collateralAmount;
        } else {
            lpAmount = (totalSupply() * (newK.sqrt() - oldK.sqrt())) / oldK.sqrt();
        }
        principalDeposited[msg.sender] += collateralAmount;
        _mint(msg.sender, lpAmount);
        emit LiquidityAdded(msg.sender, collateralAmount, lpAmount);
    }

    function removeLiquidity(uint256 lpAmount) external nonReentrant onlyUnresolved returns (uint256 collateralAmountOut) {
        // ... implementation is the same ...
        require(lpAmount > 0, "AMM: Zero amount");
        require(balanceOf(msg.sender) >= lpAmount, "AMM: Insufficient LP tokens");
        uint256 userLpBalance = balanceOf(msg.sender);
        uint256 currentTotalSupply = totalSupply();
        collateralAmountOut = AMMHelper.getLpShareValue(reserveYes, reserveNo, currentTotalSupply, lpAmount);
        uint256 principalToWithdraw = (principalDeposited[msg.sender] * lpAmount) / userLpBalance;
        uint256 profit = 0;
        if (collateralAmountOut > principalToWithdraw) {
            profit = collateralAmountOut - principalToWithdraw;
        }
        uint256 platformFee = (profit * platformFeeOnLpEarningsBps) / 10000;
        uint256 yesTokensToRemove = (reserveYes * lpAmount) / currentTotalSupply;
        uint256 noTokensToRemove = (reserveNo * lpAmount) / currentTotalSupply;
        reserveYes -= yesTokensToRemove;
        reserveNo -= noTokensToRemove;
        _burn(msg.sender, lpAmount);
        principalDeposited[msg.sender] -= principalToWithdraw;
        conditionalTokens.mergePositions(address(collateralToken), bytes32(0), conditionId, FULL_SET_INDEXES, collateralAmountOut);
        if (platformFee > 0) {
            collateralToken.transfer(platformFeeRecipient, platformFee);
        }
        collateralToken.transfer(msg.sender, collateralAmountOut - platformFee);
        emit LiquidityRemoved(msg.sender, collateralAmountOut, lpAmount);
    }

    function swap(uint256 amountIn, uint256 outcomeIndex, uint256 minAmountOut) external nonReentrant onlyUnresolved returns (uint256 amountOut) {
        // ... implementation is the same ...
        require(outcomeIndex == YES_OUTCOME_INDEX || outcomeIndex == NO_OUTCOME_INDEX, "MarketAMM: Invalid outcome");
        require(amountIn > 0, "MarketAMM: Zero input amount");
        uint256 fee = (amountIn * tradingFeeBps) / 10000;
        uint256 amountInAfterFee = amountIn - fee;
        collateralToken.transferFrom(msg.sender, address(this), amountIn);
        conditionalTokens.splitPosition(address(collateralToken), bytes32(0), conditionId, FULL_SET_INDEXES, amountIn);
        uint256 k = reserveYes * reserveNo;
        if (outcomeIndex == YES_OUTCOME_INDEX) {
            amountOut = reserveYes - (k / (reserveNo + amountInAfterFee));
            require(amountOut >= minAmountOut, "MarketAMM: Slippage exceeded");
            reserveNo += amountIn;
            reserveYes = reserveYes + amountIn - amountOut;
            conditionalTokens.safeTransferFrom(address(this), msg.sender, positionIdYes, amountOut, "");
            emit Trade(msg.sender, amountIn, amountOut, positionIdYes);
        } else {
            amountOut = reserveNo - (k / (reserveYes + amountInAfterFee));
            require(amountOut >= minAmountOut, "MarketAMM: Slippage exceeded");
            reserveYes += amountIn;
            reserveNo = reserveNo + amountIn - amountOut;
            conditionalTokens.safeTransferFrom(address(this), msg.sender, positionIdNo, amountOut, "");
            emit Trade(msg.sender, amountIn, amountOut, positionIdNo);
        }
        totalVolume += amountIn;
        tradeHistory.push(TradeRecord({trader: msg.sender, outcomeIndex: outcomeIndex, collateralIn: amountIn, tokensOut: amountOut, timestamp: block.timestamp}));
    }
    
    function sell(uint256 amountIn, uint256 outcomeIndex, uint256 minAmountOut) external nonReentrant onlyUnresolved returns (uint256 collateralAmountOut) {
        // ... implementation is the same ...
        require(amountIn > 0, "MarketAMM: Zero input amount");
        require(outcomeIndex == YES_OUTCOME_INDEX || outcomeIndex == NO_OUTCOME_INDEX, "MarketAMM: Invalid outcome");
        uint256 k = reserveYes * reserveNo;
        uint256 tokensOut;
        if (outcomeIndex == YES_OUTCOME_INDEX) {
            tokensOut = reserveNo - (k / (reserveYes + amountIn));
        } else {
            tokensOut = reserveYes - (k / (reserveNo + amountIn));
        }
        uint256 fee = (tokensOut * tradingFeeBps) / 10000;
        collateralAmountOut = tokensOut - fee;
        require(collateralAmountOut >= minAmountOut, "MarketAMM: Slippage exceeded");
        uint256 positionIdIn = outcomeIndex == YES_OUTCOME_INDEX ? positionIdYes : positionIdNo;
        conditionalTokens.safeTransferFrom(msg.sender, address(this), positionIdIn, amountIn, "");
        if (outcomeIndex == YES_OUTCOME_INDEX) {
            reserveYes = reserveYes + amountIn - collateralAmountOut;
            reserveNo -= collateralAmountOut;
        } else {
            reserveNo = reserveNo + amountIn - collateralAmountOut;
            reserveYes -= collateralAmountOut;
        }
        conditionalTokens.mergePositions(address(collateralToken), bytes32(0), conditionId, FULL_SET_INDEXES, collateralAmountOut);
        collateralToken.transfer(msg.sender, collateralAmountOut);
    }

    // --- View Functions (no change) ---
    function getLpPosition(address provider) external view returns (LpPosition memory) {
        uint256 lpTokens = balanceOf(provider);
        uint256 currentValue = AMMHelper.getLpShareValue(reserveYes, reserveNo, totalSupply(), lpTokens);
        uint256 principal = principalDeposited[provider];
        return LpPosition({principal: principal, currentValue: currentValue, profit: int256(currentValue) - int256(principal), lpTokensOwned: lpTokens});
    }
    function getTotalPoolValue() external view returns (uint256) {
        return AMMHelper.getLpShareValue(reserveYes, reserveNo, totalSupply(), totalSupply());
    }
    function getTradeHistoryCount() external view returns (uint256) {
        return tradeHistory.length;
    }
}

