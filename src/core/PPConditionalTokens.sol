// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import "../interfaces/IConditionalTokens.sol";

/**
 * @title PPConditionalTokens
 * @notice This is a custom, in-house implementation of the Conditional Tokens standard (ERC-1155).
 * @dev This version incorporates critical security fixes based on audit feedback, including:
 * - Use of SafeERC20 for all token transfers.
 * - Pausable contract for emergency stops.
 * - Stricter access control on sensitive functions.
 * - Zero-address and input validation checks.
 * - Adherence to the Checks-Effects-Interactions pattern where possible.
 */
contract PPConditionalTokens is
    IConditionalTokens,
    ERC1155,
    Ownable,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;

    // --- Structs ---
    struct Condition {
        address oracle;
        bytes32 questionId;
        uint256 outcomeSlotCount;
        bool resolved;
        uint256[] payouts;
    }

    struct FeePolicy {
        uint256 feeBps;
        address recipient;
    }

    // --- Mappings ---
    mapping(bytes32 => Condition) private conditions;
    mapping(bytes32 => FeePolicy) private feePolicies;

    // --- Constructor ---
    constructor() ERC1155("") Ownable(msg.sender) {}

    // --- External Functions ---

    /**
     * @notice Prepares a condition, represented by a unique ID.
     * @dev This should be called by the MarketFactory before a market is created.
     * Now restricted to `onlyOwner` to prevent front-running and spam.
     */
    function prepareCondition(
        address oracle,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) external override onlyOwner whenNotPaused {
        bytes32 conditionId = getConditionId(
            oracle,
            questionId,
            outcomeSlotCount
        );
        require(
            conditions[conditionId].oracle == address(0),
            "CT: Condition already prepared"
        );
        conditions[conditionId] = Condition({
            oracle: oracle,
            questionId: questionId,
            outcomeSlotCount: outcomeSlotCount,
            resolved: false,
            payouts: new uint256[](0)
        });
    }

    /**
     * @notice Reports the payouts for a condition, effectively resolving the market.
     * @dev Now restricted to `onlyOwner` (the MarketFactory) to ensure legitimacy.
     */
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts)
        external
        override
        onlyOwner
        whenNotPaused
    {
        bytes32 conditionId = getConditionId(
            address(this),
            questionId,
            payouts.length
        );
        Condition storage condition = conditions[conditionId];
        require(
            condition.oracle == msg.sender,
            "CT: Reporter is not the oracle"
        );
        require(condition.oracle != address(0), "CT: Condition not prepared");
        require(!condition.resolved, "CT: Condition already resolved");
        require(
            payouts.length == condition.outcomeSlotCount,
            "CT: Payouts length mismatch"
        );

        condition.resolved = true;
        condition.payouts = payouts;
    }

    /**
     * @notice Splits a position, turning collateral into a full set of outcome tokens.
     * @dev The deposit pattern (transferFrom -> mint) is protected by a nonReentrant guard.
     */
    function splitPosition(
        address collateralToken,
        bytes32, // parentCollectionId - not used in this simple implementation
        bytes32 conditionId,
        uint256[] calldata indexSet,
        uint256 amount
    ) external override nonReentrant whenNotPaused {
        require(collateralToken != address(0), "CT: Invalid collateral token");
        // Interaction: Pull collateral from the user first.
        IERC20(collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        // Effects: Mint the corresponding outcome tokens.
        uint256[] memory positionIds = new uint256[](indexSet.length);
        uint256[] memory amounts = new uint256[](indexSet.length);
        for (uint256 i = 0; i < indexSet.length; i++) {
            positionIds[i] = getPositionId(
                collateralToken,
                conditionId,
                indexSet[i]
            );
            amounts[i] = amount;
        }

        _mintBatch(msg.sender, positionIds, amounts, "");
    }

    /**
     * @notice Merges a full set of outcome tokens back into collateral.
     * @dev Follows Checks-Effects-Interactions: tokens are burned before collateral is sent.
     */
    function mergePositions(
        address collateralToken,
        bytes32, // parentCollectionId
        bytes32 conditionId,
        uint256[] calldata indexSet,
        uint256 amount
    ) external override nonReentrant whenNotPaused {
        require(collateralToken != address(0), "CT: Invalid collateral token");
        // Effects: Burn the user's outcome tokens first.
        uint256[] memory positionIds = new uint256[](indexSet.length);
        uint256[] memory amounts = new uint256[](indexSet.length);
        for (uint256 i = 0; i < indexSet.length; i++) {
            positionIds[i] = getPositionId(
                collateralToken,
                conditionId,
                indexSet[i]
            );
            amounts[i] = amount;
        }
        _burnBatch(msg.sender, positionIds, amounts);

        // Interaction: Send collateral to the user.
        IERC20(collateralToken).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Redeems positions for collateral after a condition has been resolved.
     * @dev Follows Checks-Effects-Interactions: tokens are burned before collateral is sent.
     */
    function redeemPositions(
        address user,
        address collateralToken,
        bytes32, // parentCollectionId
        bytes32 conditionId,
        uint256[] calldata indexSet
    ) external override nonReentrant whenNotPaused {
        require(collateralToken != address(0), "CT: Invalid collateral token");
        Condition storage condition = conditions[conditionId];
        require(condition.resolved, "CT: Condition not resolved");

        uint256 totalPayout = 0;
        uint256[] memory positionIds = new uint256[](indexSet.length);
        uint256[] memory amounts = new uint256[](indexSet.length);

        for (uint256 i = 0; i < indexSet.length; i++) {
            uint256 outcomeIndex = indexSet[i];
            uint256 positionId = getPositionId(
                collateralToken,
                conditionId,
                outcomeIndex
            );
            uint256 balance = balanceOf(user, positionId);

            if (balance > 0) {
                uint256 payout = condition.payouts[outcomeIndex - 1];
                totalPayout += (balance * payout);
                positionIds[i] = positionId;
                amounts[i] = balance;
            }
        }

        if (totalPayout > 0) {
            // Effects: Burn the user's outcome tokens first.
            _burnBatch(user, positionIds, amounts);

            // Interaction: Send the final collateral payout.
            FeePolicy storage policy = feePolicies[conditionId];
            if (policy.feeBps > 0 && policy.recipient != address(0)) {
                uint256 fee = (totalPayout * policy.feeBps) / 10000;
                if (fee > 0) {
                    IERC20(collateralToken).safeTransfer(policy.recipient, fee);
                }
                IERC20(collateralToken).safeTransfer(user, totalPayout - fee);
            } else {
                IERC20(collateralToken).safeTransfer(user, totalPayout);
            }
        }
    }

    /**
     * @notice Sets the fee policy for redemptions on a specific market.
     */
    function setFeePolicy(
        bytes32 conditionId,
        uint256 feeBps,
        address recipient
    ) external override onlyOwner whenNotPaused {
        require(recipient != address(0), "CT: Invalid recipient");
        require(feeBps <= 10000, "CT: Fee too high");
        feePolicies[conditionId] = FeePolicy(feeBps, recipient);
    }

    // --- Pausable Admin Functions ---
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- View Functions ---
    function getConditionId(
        address oracle,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) public pure override returns (bytes32) {
        return
            keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    function getPositionId(
        address collateralToken,
        bytes32 collectionId,
        uint256 indexSet
    ) public pure override returns (uint256) {
        // This implementation uses a hash, which does not have the overflow risk
        // of bitmask-based implementations.
        return
            uint256(
                keccak256(
                    abi.encodePacked(collateralToken, collectionId, indexSet)
                )
            );
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public override(ERC1155, IConditionalTokens) {
        ERC1155.safeTransferFrom(from, to, id, amount, data);
    }

    function setApprovalForAll(address operator, bool approved)
        public
        override(ERC1155, IConditionalTokens)
    {
        ERC1155.setApprovalForAll(operator, approved);
    }
}
