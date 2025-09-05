// SPDX-License-Identifier: MIT
// ... (Content is identical to the previous version, just moved here) ...
pragma solidity ^0.8.20;

interface IConditionalTokens {
    function prepareCondition(
        address oracle,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) external;

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts)
        external;

    function splitPosition(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSet,
        uint256 amount
    ) external;

    function mergePositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSet,
        uint256 amount
    ) external;

    function redeemPositions(
        address user,
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSet
    ) external;
    
    function setFeePolicy(
        bytes32 conditionId, 
        uint256 feeBps, 
        address recipient
    ) external;

    function getConditionId(
        address oracle,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) external pure returns (bytes32);

    function getPositionId(
        address collateralToken,
        bytes32 collectionId,
        uint256 indexSet
    ) external pure returns (uint256);

    function setApprovalForAll(address operator, bool approved) external;
    
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;
}

