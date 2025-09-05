// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import "../amm/MarketAMM.sol";
import "../interfaces/IConditionalTokens.sol";

/**
 * @title MarketFactory
 * @notice This version adds a fee on LP earnings and locks the AMM on resolution.
 */
contract MarketFactory is Ownable {
    // ... (State Variables and Events are the same) ...
    IConditionalTokens public immutable conditionalTokens;
    address public immutable collateralToken;
    address public immutable marketAMMLogic; 
    mapping(bytes32 => address) public markets; 
    uint256 public platformFeeBps; 
    uint256 public platformFeeOnLpEarningsBps;
    address public platformFeeRecipient;
    event MarketCreation(bytes32 indexed questionId, address indexed marketAddress, uint256 feeBps);
    event MarketResolved(bytes32 indexed questionId, uint256 winningOutcome);
    event PlatformFeeSet(uint256 newFeeBps);
    event PlatformLpFeeSet(uint256 newFeeBps);
    event FeeRecipientSet(address newRecipient);

    constructor(
        address _conditionalTokens,
        address _collateralToken
    ) Ownable(msg.sender) {
        conditionalTokens = IConditionalTokens(_conditionalTokens);
        collateralToken = _collateralToken;
        marketAMMLogic = address(new MarketAMM());
    }

    // --- Admin Functions (no change) ---
    function setPlatformFee(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 10000, "Factory: Fee too high");
        platformFeeBps = _feeBps;
        emit PlatformFeeSet(_feeBps);
    }
    function setPlatformFeeOnLpEarnings(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 10000, "Factory: Fee too high");
        platformFeeOnLpEarningsBps = _feeBps;
        emit PlatformLpFeeSet(_feeBps);
    }
    function setFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), "Factory: Zero address");
        platformFeeRecipient = _recipient;
        emit FeeRecipientSet(_recipient);
    }

    // --- createMarket function (no change) ---
    function createMarket(bytes32 questionId, uint256 tradingFeeBps) external returns (address marketAddress) {
    require(markets[questionId] == address(0), "Factory: Market exists");
    uint256 outcomeSlotCount = 2;
    conditionalTokens.prepareCondition(address(this), questionId, outcomeSlotCount);
    bytes32 conditionId = conditionalTokens.getConditionId(address(this), questionId, outcomeSlotCount);

    if (platformFeeBps > 0 && platformFeeRecipient != address(0)) {
        conditionalTokens.setFeePolicy(conditionId, platformFeeBps, platformFeeRecipient);
    }

    bytes memory creationCode = abi.encodePacked(
        hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
        marketAMMLogic,
        hex"5af43d82803e903d91602b57fd5bf3"
    );

    assembly {
        marketAddress := create2(0, add(creationCode, 0x20), mload(creationCode), questionId)
    }

    require(marketAddress != address(0), "Factory: Clone deployment failed");
    MarketAMM(marketAddress).initialize(
        address(conditionalTokens),
        collateralToken,
        conditionId,
        tradingFeeBps,
        platformFeeOnLpEarningsBps,
        platformFeeRecipient
    );
    markets[questionId] = marketAddress;
    emit MarketCreation(questionId, marketAddress, tradingFeeBps);
}
    
    // --- resolveMarket function (UPDATED) ---
    function resolveMarket(bytes32 questionId, uint256 winningOutcome) external onlyOwner {
        address marketAddress = markets[questionId];
        require(marketAddress != address(0), "Factory: Market not found");
        require(winningOutcome == 1 || winningOutcome == 2, "Factory: Invalid outcome");

        // 1. Report payouts to the conditional tokens contract
        uint256[] memory payouts = new uint256[](2);
        payouts[winningOutcome - 1] = 1;
        conditionalTokens.reportPayouts(questionId, payouts);

        // 2. NEW: Lock the AMM and consolidate its reserves
        MarketAMM(marketAddress).setResolved(winningOutcome);

        emit MarketResolved(questionId, winningOutcome);
    }
}

