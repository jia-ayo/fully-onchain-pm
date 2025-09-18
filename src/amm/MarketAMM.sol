// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IConditionalTokens.sol";
import "./AMMHelper.sol";

/**
 * @title MarketAMM
 * @notice Manages liquidity and trading for a single prediction market. Deployed as a clone by MarketFactory.
 */
contract MarketAMM is ERC20, ReentrancyGuard {
    using AMMHelper for uint256;
    using SafeERC20 for IERC20;

    // --- Structs ---
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

    // --- Constants ---
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
    bool public isResolved;

    uint256 public reserveYes;
    uint256 public reserveNo;

    mapping(address => uint256) public principalDeposited;
    TradeRecord[] public tradeHistory;

    // --- Constructor ---
    // This constructor is required to satisfy the ERC20 base contract.
    // It runs only for the base logic contract, not for the clones.
    constructor() ERC20("PM LP Token", "PMLP") {}

    // --- Modifiers ---
    modifier onlyUnresolved() {
        require(!isResolved, "AMM: Market is resolved");
        _;
    }

    // --- Events ---
    event LiquidityAdded(address indexed provider, uint256 collateralAmount, uint256 lpAmount);
    event LiquidityRemoved(address indexed provider, uint256 collateralAmount, uint256 lpAmount);
    event Trade(address indexed trader, uint256 amountIn, uint256 amountOut, uint256 positionId);
    event MarketLocked(uint256 winningOutcome);

    // --- Initializer ---
    function initialize(
        address _conditionalTokens,
        address _collateral,
        bytes32 _conditionId,
        uint256 _tradingFeeBps,
        uint256 _lpFeeBps,
        address _feeRecipient
    ) external {
        require(address(collateralToken) == address(0), "AMM: Already initialized");
        // The ERC20 name and symbol are set in the constructor.
        conditionalTokens = IConditionalTokens(_conditionalTokens);
        collateralToken = IERC20(_collateral);
        conditionId = _conditionId;
        tradingFeeBps = _tradingFeeBps;
        platformFeeOnLpEarningsBps = _lpFeeBps;
        platformFeeRecipient = _feeRecipient;
        positionIdYes = conditionalTokens.getPositionId(address(collateralToken), conditionId, YES_OUTCOME_INDEX);
        positionIdNo = conditionalTokens.getPositionId(address(collateralToken), conditionId, NO_OUTCOME_INDEX);

        // Approve the conditional tokens contract to spend this contract's collateral
        collateralToken.approve(address(conditionalTokens), type(uint256).max);
    }

    // --- Post-Resolution Functions ---
    function setResolved(uint256 winningOutcome) external {
        // In a real implementation, this should have access control (e.g., onlyFactory)
        require(!isResolved, "AMM: Already resolved");
        isResolved = true;
        
        if (winningOutcome == YES_OUTCOME_INDEX) {
            uint256 amountToMerge = reserveNo;
            if(amountToMerge > 0){
                reserveYes -= amountToMerge;
                reserveNo = 0;
                conditionalTokens.mergePositions(address(collateralToken), bytes32(0), conditionId, FULL_SET_INDEXES, amountToMerge);
            }
        } else {
            uint256 amountToMerge = reserveYes;
             if(amountToMerge > 0){
                reserveNo -= amountToMerge;
                reserveYes = 0;
                conditionalTokens.mergePositions(address(collateralToken), bytes32(0), conditionId, FULL_SET_INDEXES, amountToMerge);
            }
        }

        emit MarketLocked(winningOutcome);
    }
    
    function claimLpWinnings() external nonReentrant {
        require(isResolved, "AMM: Market not resolved");
        uint256 lpAmount = balanceOf(msg.sender);
        require(lpAmount > 0, "AMM: No LP tokens");

        uint256 totalWinningTokens = reserveYes > 0 ? reserveYes : reserveNo;
        uint256 winningPositionId = reserveYes > 0 ? positionIdYes : positionIdNo;
        
        uint256 userShare = (totalWinningTokens * lpAmount) / totalSupply();

        _burn(msg.sender, lpAmount);
        
        // This transfer can't use SafeERC20 because IConditionalTokens is not an ERC20 contract.
        // It's an ERC1155, and OpenZeppelin's ERC1155 implementation has its own safety checks.
        conditionalTokens.safeTransferFrom(address(this), msg.sender, winningPositionId, userShare, "");
    }

    // --- Core Functions ---
    function addLiquidity(uint256 collateralAmount) external nonReentrant onlyUnresolved returns (uint256 lpAmount) {
        require(collateralAmount > 0, "AMM: Zero amount");
        collateralToken.safeTransferFrom(msg.sender, address(this), collateralAmount);
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
            collateralToken.safeTransfer(platformFeeRecipient, platformFee);
        }
        collateralToken.safeTransfer(msg.sender, collateralAmountOut - platformFee);
        
        emit LiquidityRemoved(msg.sender, collateralAmountOut, lpAmount);
    }

    function swap(uint256 amountIn, uint256 outcomeIndex, uint256 minAmountOut) external nonReentrant onlyUnresolved returns (uint256 amountOut) {
        require(outcomeIndex == YES_OUTCOME_INDEX || outcomeIndex == NO_OUTCOME_INDEX, "MarketAMM: Invalid outcome");
        require(amountIn > 0, "MarketAMM: Zero input amount");
        
        uint256 fee = (amountIn * tradingFeeBps) / 10000;
        uint256 amountInAfterFee = amountIn - fee;
        
        collateralToken.safeTransferFrom(msg.sender, address(this), amountIn);
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
        return amountOut;
    }
    
    function sell(uint256 amountIn, uint256 outcomeIndex, uint256 minAmountOut) external nonReentrant onlyUnresolved returns (uint256 collateralAmountOut) {
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
        collateralToken.safeTransfer(msg.sender, collateralAmountOut);
        return collateralAmountOut;
    }

    // --- View Functions ---
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

    function getCurrentPrices() external view returns (uint256 yesPrice, uint256 noPrice) {
        uint256 totalReserves = reserveYes + reserveNo;
        if (totalReserves == 0) {
            return (5 * 10**17, 5 * 10**17); // 0.5 for each if no liquidity
        }
        // Price is the proportion of the opposite reserve
        yesPrice = (reserveNo * 10**18) / totalReserves;
        noPrice = (reserveYes * 10**18) / totalReserves;
    }
}

