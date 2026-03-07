// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BaseRankMarketV2 — Permissionless prediction market for Base leaderboard
/// @notice Any candidateId (bytes32) is valid. No pre-registration required.
///         First prediction on a new candidateId auto-creates it in the pool.
contract BaseRankMarketV2 is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------- Types --------

    enum MarketType { BaseApp, BaseChain }
    enum MarketState { None, Open, Locked, Resolved }

    struct MarketConfig {
        uint64 epochId;
        MarketType marketType;
        uint64 openTime;
        uint64 lockTime;
        uint64 resolveTime;
        uint16 feeBps;
        bytes32 metadataHash;
    }

    struct PermitParams {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct Market {
        uint64 openTime;
        uint64 lockTime;
        uint64 resolveTime;
        uint16 feeBps;
        uint8 state;
        bytes32 metadataHash;
        bytes32 snapshotHash;
        uint256 totalPool;
        uint256 totalWinningPool;
    }

    // -------- Constants --------

    uint16 public constant MAX_FEE_BPS = 500;
    uint256 public constant MIN_STAKE = 1e4; // 0.01 USDC (6 decimals)

    // -------- State --------

    IERC20 public immutable usdc;
    address public feeRecipient;

    mapping(uint64 => mapping(MarketType => Market)) internal _markets;

    /// @notice Pool size per candidate — also serves as candidate existence check
    mapping(uint64 => mapping(MarketType => mapping(bytes32 => uint256))) public poolByCandidate;
    mapping(uint64 => mapping(MarketType => mapping(address => mapping(bytes32 => uint256)))) public userStakeByCandidate;
    mapping(uint64 => mapping(MarketType => mapping(address => uint256))) public userTotalStake;

    mapping(uint64 => mapping(MarketType => bytes32[])) public winnerList;
    mapping(uint64 => mapping(MarketType => mapping(bytes32 => bool))) public isWinner;

    mapping(uint64 => mapping(MarketType => mapping(address => bool))) public claimed;
    mapping(uint64 => mapping(MarketType => bool)) public feeCollected;

    // -------- Events --------

    event FeeRecipientUpdated(address indexed newRecipient);
    event FeeCollected(uint64 indexed epochId, MarketType indexed marketType, uint256 feeAmount, address indexed recipient);
    event MarketOpened(uint64 indexed epochId, MarketType indexed marketType, uint64 lockTime, uint64 resolveTime);
    event MarketLocked(uint64 indexed epochId, MarketType indexed marketType);
    event MarketResolved(uint64 indexed epochId, MarketType indexed marketType, bytes32[] winners, bytes32 snapshotHash);
    event Predicted(uint64 indexed epochId, MarketType indexed marketType, address indexed user, bytes32 candidateId, uint256 amount);
    event WinningsClaimed(uint64 indexed epochId, MarketType indexed marketType, address indexed user, uint256 amount);

    // -------- Errors --------

    error InvalidAddress();
    error InvalidConfig();
    error InvalidState();
    error InvalidTime();
    error InvalidAmount();
    error InvalidCandidate(); // candidateId == bytes32(0)
    error DuplicateWinner();
    error NoWinners();
    error AlreadyClaimed();
    error FeeAlreadyCollected();
    error PermitValueTooLow();

    // -------- Constructor --------

    constructor(address usdc_, address owner_, address feeRecipient_) Ownable(owner_) {
        if (usdc_ == address(0) || owner_ == address(0) || feeRecipient_ == address(0)) revert InvalidAddress();
        usdc = IERC20(usdc_);
        feeRecipient = feeRecipient_;
    }

    // -------- Emergency controls --------

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -------- Governance setters --------

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert InvalidAddress();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    // -------- Market lifecycle --------

    /// @notice Open a market epoch. No candidate pre-registration — any bytes32 can be predicted on.
    function openMarket(MarketConfig calldata config) external onlyOwner {
        if (config.feeBps > MAX_FEE_BPS) revert InvalidConfig();
        if (!(config.openTime < config.lockTime && config.lockTime < config.resolveTime)) revert InvalidConfig();
        if (config.openTime < block.timestamp) revert InvalidTime();

        Market storage m = _markets[config.epochId][config.marketType];
        if (m.state != uint8(MarketState.None)) revert InvalidState();

        m.openTime = config.openTime;
        m.lockTime = config.lockTime;
        m.resolveTime = config.resolveTime;
        m.feeBps = config.feeBps;
        m.state = uint8(MarketState.Open);
        m.metadataHash = config.metadataHash;

        emit MarketOpened(config.epochId, config.marketType, config.lockTime, config.resolveTime);
    }

    function lockMarket(uint64 epochId, MarketType marketType) external onlyOwner {
        Market storage m = _markets[epochId][marketType];
        if (m.state != uint8(MarketState.Open)) revert InvalidState();
        if (block.timestamp < m.lockTime) revert InvalidState();
        m.state = uint8(MarketState.Locked);
        emit MarketLocked(epochId, marketType);
    }

    function resolveMarket(
        uint64 epochId,
        MarketType marketType,
        bytes32[] calldata winnerIds,
        bytes32 snapshotHash
    ) external onlyOwner {
        Market storage m = _markets[epochId][marketType];
        if (m.state != uint8(MarketState.Locked)) revert InvalidState();
        if (block.timestamp < m.resolveTime) revert InvalidState();
        if (winnerIds.length == 0) revert NoWinners();

        uint256 totalWinning;
        for (uint256 i; i < winnerIds.length; ++i) {
            bytes32 w = winnerIds[i];
            if (w == bytes32(0)) revert InvalidCandidate();
            if (isWinner[epochId][marketType][w]) revert DuplicateWinner();

            isWinner[epochId][marketType][w] = true;
            winnerList[epochId][marketType].push(w);
            totalWinning += poolByCandidate[epochId][marketType][w];
        }

        m.state = uint8(MarketState.Resolved);
        m.snapshotHash = snapshotHash;
        m.totalWinningPool = totalWinning;

        emit MarketResolved(epochId, marketType, winnerIds, snapshotHash);
    }

    // -------- User actions --------

    function predict(uint64 epochId, MarketType marketType, bytes32 candidateId, uint256 amount)
        external nonReentrant whenNotPaused
    {
        _predict(epochId, marketType, candidateId, amount, msg.sender);
    }

    function predictWithPermit(
        uint64 epochId,
        MarketType marketType,
        bytes32 candidateId,
        uint256 amount,
        PermitParams calldata permit
    ) external nonReentrant whenNotPaused {
        if (permit.value < amount) revert PermitValueTooLow();
        IERC20Permit(address(usdc)).permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s);
        _predict(epochId, marketType, candidateId, amount, msg.sender);
    }

    function _predict(
        uint64 epochId,
        MarketType marketType,
        bytes32 candidateId,
        uint256 amount,
        address sender
    ) internal {
        if (amount < MIN_STAKE) revert InvalidAmount();
        if (candidateId == bytes32(0)) revert InvalidCandidate();

        Market storage m = _markets[epochId][marketType];
        if (m.state != uint8(MarketState.Open)) revert InvalidState();
        if (block.timestamp < m.openTime || block.timestamp >= m.lockTime) revert InvalidState();

        userStakeByCandidate[epochId][marketType][sender][candidateId] += amount;
        userTotalStake[epochId][marketType][sender] += amount;
        poolByCandidate[epochId][marketType][candidateId] += amount;
        m.totalPool += amount;

        usdc.safeTransferFrom(sender, address(this), amount);

        emit Predicted(epochId, marketType, sender, candidateId, amount);
    }

    function claimWinnings(uint64 epochId, MarketType marketType)
        external nonReentrant whenNotPaused returns (uint256 amount)
    {
        Market storage m = _markets[epochId][marketType];
        if (m.state != uint8(MarketState.Resolved)) revert InvalidState();
        if (claimed[epochId][marketType][msg.sender]) revert AlreadyClaimed();

        claimed[epochId][marketType][msg.sender] = true;
        amount = _claimable(msg.sender, epochId, marketType, m);

        if (amount > 0) {
            usdc.safeTransfer(msg.sender, amount);
        }
        emit WinningsClaimed(epochId, marketType, msg.sender, amount);
    }

    function collectFee(uint64 epochId, MarketType marketType)
        external onlyOwner nonReentrant returns (uint256 feeAmount)
    {
        Market storage m = _markets[epochId][marketType];
        if (m.state != uint8(MarketState.Resolved)) revert InvalidState();
        if (feeCollected[epochId][marketType]) revert FeeAlreadyCollected();

        feeCollected[epochId][marketType] = true;
        uint256 totalWinning = m.totalWinningPool;
        // If nobody predicted any winner, refund everyone
        feeAmount = (totalWinning == 0) ? 0 : (m.totalPool * m.feeBps) / 10_000;
        if (feeAmount > 0) {
            usdc.safeTransfer(feeRecipient, feeAmount);
        }
        emit FeeCollected(epochId, marketType, feeAmount, feeRecipient);
    }

    // -------- Views --------

    function claimable(address user, uint64 epochId, MarketType marketType) external view returns (uint256) {
        Market storage m = _markets[epochId][marketType];
        if (m.state != uint8(MarketState.Resolved) || claimed[epochId][marketType][user]) return 0;
        return _claimable(user, epochId, marketType, m);
    }

    function _claimable(address user, uint64 epochId, MarketType marketType, Market storage m)
        internal view returns (uint256)
    {
        uint256 totalWinning = m.totalWinningPool;
        if (totalWinning == 0) {
            // Refund mode: return user's total stake
            return userTotalStake[epochId][marketType][user];
        }

        uint256 userWinningStake;
        bytes32[] storage winners = winnerList[epochId][marketType];
        for (uint256 i; i < winners.length; ++i) {
            userWinningStake += userStakeByCandidate[epochId][marketType][user][winners[i]];
        }
        if (userWinningStake == 0) return 0;

        uint256 fee = (m.totalPool * m.feeBps) / 10_000;
        uint256 distributable = m.totalPool - fee;

        return (distributable * userWinningStake) / totalWinning;
    }

    function marketState(uint64 epochId, MarketType marketType) external view returns (uint8) {
        return _markets[epochId][marketType].state;
    }

    function marketDetails(uint64 epochId, MarketType marketType) external view returns (Market memory) {
        return _markets[epochId][marketType];
    }
}
