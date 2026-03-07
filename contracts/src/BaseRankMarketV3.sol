// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BaseRankMarketV3
/// @notice Tier-bucketed pari-mutuel prediction market for Base leaderboard rankings.
///         Users predict which apps finish Top 10, Top 5, or #1.
///         Net pool splits into 3 isolated reward buckets (30/40/30).
///         Pari-mutuel runs within each bucket independently.
/// @dev Permissionless candidateIds. Resolution via ranked top-10 array.
contract BaseRankMarketV3 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Types ───────────────────────────────────────────────────────────

    enum MarketType { APP, CHAIN }
    enum MarketState { INACTIVE, OPEN, LOCKED, RESOLVED }
    enum BetType { TOP_10, TOP_5, TOP_1 }

    struct MarketConfig {
        uint64 openTime;
        uint64 lockTime;
        uint64 resolveTime;
        uint16 feeBps;
        MarketState state;
        bytes32 snapshotHash;
    }

    struct UserBet {
        bytes32 candidateId;
        BetType betType;
        uint256 amount;
        bool claimed;
    }

    struct BucketState {
        uint256 totalStaked;       // total staked into this tier
        uint256 winningShares;     // winning weighted shares in this tier
        uint256 reward;            // allocated reward for this tier
    }

    // ─── Constants ───────────────────────────────────────────────────────

    uint256 public constant MIN_STAKE = 10_000; // $0.01 USDC (6 decimals)
    uint16 public constant MAX_FEE_BPS = 1000;  // 10%
    uint256 public constant RESOLUTION_SIZE = 10;

    // Bucket splits (basis points, sum = 10000)
    uint256 public constant BUCKET_TOP10_BPS = 3000; // 30%
    uint256 public constant BUCKET_TOP5_BPS = 4000;  // 40%
    uint256 public constant BUCKET_NUM1_BPS = 3000;  // 30%

    // ─── State ───────────────────────────────────────────────────────────

    IERC20 public immutable STAKE_TOKEN;
    address public feeRecipient;

    /// @notice Market config per epoch per market type
    mapping(uint64 => mapping(uint8 => MarketConfig)) public markets;

    /// @notice Total pool per epoch per market type (all tiers combined)
    mapping(uint64 => mapping(uint8 => uint256)) public totalPool;

    /// @notice Bucket state per epoch per market type per bet type
    mapping(uint64 => mapping(uint8 => mapping(uint8 => BucketState))) public buckets;

    /// @notice Stake per candidate per betType (for resolution math)
    mapping(uint64 => mapping(uint8 => mapping(bytes32 => mapping(uint8 => uint256)))) public candidateBetTypeStake;

    /// @notice User bets array
    mapping(address => mapping(uint64 => mapping(uint8 => UserBet[]))) internal _userBets;

    /// @notice User total stake (quick lookup)
    mapping(uint64 => mapping(uint8 => mapping(address => uint256))) public userTotalStake;

    /// @notice Resolved rankings
    mapping(uint64 => mapping(uint8 => bytes32[10])) public resolvedRankings;

    // ─── Events ──────────────────────────────────────────────────────────

    event MarketOpened(uint64 indexed epochId, uint8 indexed marketType, uint64 openTime, uint64 lockTime, uint64 resolveTime, uint16 feeBps);
    event Predicted(uint64 indexed epochId, uint8 indexed marketType, address indexed user, bytes32 candidateId, uint256 amount, uint8 betType);
    event MarketResolved(uint64 indexed epochId, uint8 indexed marketType, bytes32[10] rankedCandidates, bytes32 snapshotHash);
    event Claimed(uint64 indexed epochId, uint8 indexed marketType, address indexed user, uint256 payout);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    // ─── Errors ──────────────────────────────────────────────────────────

    error MarketNotOpen();
    error MarketNotResolved();
    error MarketAlreadyExists();
    error InvalidCandidate();
    error StakeTooLow();
    error InvalidTime();
    error InvalidFee();
    error InvalidRankings();
    error NothingToClaim();
    error ZeroAddress();
    error InvalidBetType();

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(address _stakeToken, address _feeRecipient, address _owner) Ownable(_owner) {
        if (_stakeToken == address(0) || _feeRecipient == address(0)) revert ZeroAddress();
        STAKE_TOKEN = IERC20(_stakeToken);
        feeRecipient = _feeRecipient;
    }

    // ─── Admin ───────────────────────────────────────────────────────────

    function openMarket(
        uint64 epochId,
        uint8 marketType,
        uint64 openTime,
        uint64 lockTime,
        uint64 resolveTime,
        uint16 feeBps
    ) external onlyOwner {
        MarketConfig storage m = markets[epochId][marketType];
        if (m.state != MarketState.INACTIVE) revert MarketAlreadyExists();
        if (lockTime <= block.timestamp) revert InvalidTime();
        if (resolveTime <= lockTime) revert InvalidTime();
        if (openTime >= lockTime) revert InvalidTime();
        if (feeBps > MAX_FEE_BPS) revert InvalidFee();

        m.openTime = openTime;
        m.lockTime = lockTime;
        m.resolveTime = resolveTime;
        m.feeBps = feeBps;
        m.state = MarketState.OPEN;

        emit MarketOpened(epochId, marketType, openTime, lockTime, resolveTime, feeBps);
    }

    /// @notice Resolve market with ranked top-10. Computes winning shares per bucket.
    function resolveMarket(
        uint64 epochId,
        uint8 marketType,
        bytes32[10] calldata rankedCandidates,
        bytes32 snapshotHash
    ) external onlyOwner {
        MarketConfig storage m = markets[epochId][marketType];
        if (m.state != MarketState.OPEN && m.state != MarketState.LOCKED) revert MarketNotOpen();
        if (block.timestamp < m.resolveTime) revert InvalidTime();

        bool hasCandidate = false;
        for (uint256 i = 0; i < 10; i++) {
            if (rankedCandidates[i] != bytes32(0)) { hasCandidate = true; break; }
        }
        if (!hasCandidate) revert InvalidRankings();

        resolvedRankings[epochId][marketType] = rankedCandidates;
        m.snapshotHash = snapshotHash;
        m.state = MarketState.RESOLVED;

        // Calculate fee and net pool
        uint256 pool = totalPool[epochId][marketType];
        uint256 fee = (pool * m.feeBps) / 10_000;
        uint256 netPool = pool - fee;

        // Allocate reward buckets
        buckets[epochId][marketType][uint8(BetType.TOP_10)].reward = (netPool * BUCKET_TOP10_BPS) / 10_000;
        buckets[epochId][marketType][uint8(BetType.TOP_5)].reward = (netPool * BUCKET_TOP5_BPS) / 10_000;
        buckets[epochId][marketType][uint8(BetType.TOP_1)].reward = (netPool * BUCKET_NUM1_BPS) / 10_000;

        // Compute winning shares per bucket from candidate stakes
        uint256 top10Wins;
        uint256 top5Wins;
        uint256 top1Wins;

        for (uint256 rank = 0; rank < 10; rank++) {
            bytes32 cid = rankedCandidates[rank];
            if (cid == bytes32(0)) continue;

            // All ranked candidates qualify for Top 10
            top10Wins += candidateBetTypeStake[epochId][marketType][cid][uint8(BetType.TOP_10)];

            // Rank 0-4 qualify for Top 5
            if (rank < 5) {
                top5Wins += candidateBetTypeStake[epochId][marketType][cid][uint8(BetType.TOP_5)];
            }

            // Rank 0 only qualifies for #1
            if (rank == 0) {
                top1Wins += candidateBetTypeStake[epochId][marketType][cid][uint8(BetType.TOP_1)];
            }
        }

        buckets[epochId][marketType][uint8(BetType.TOP_10)].winningShares = top10Wins;
        buckets[epochId][marketType][uint8(BetType.TOP_5)].winningShares = top5Wins;
        buckets[epochId][marketType][uint8(BetType.TOP_1)].winningShares = top1Wins;

        if (fee > 0) {
            STAKE_TOKEN.safeTransfer(feeRecipient, fee);
        }

        emit MarketResolved(epochId, marketType, rankedCandidates, snapshotHash);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── User Actions ────────────────────────────────────────────────────

    function predict(
        uint64 epochId,
        uint8 marketType,
        bytes32 candidateId,
        uint256 amount,
        uint8 betType
    ) external whenNotPaused nonReentrant {
        MarketConfig storage m = markets[epochId][marketType];
        if (m.state != MarketState.OPEN) revert MarketNotOpen();
        if (block.timestamp < m.openTime || block.timestamp >= m.lockTime) revert MarketNotOpen();
        if (candidateId == bytes32(0)) revert InvalidCandidate();
        if (amount < MIN_STAKE) revert StakeTooLow();
        if (betType > uint8(BetType.TOP_1)) revert InvalidBetType();

        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        _userBets[msg.sender][epochId][marketType].push(UserBet({
            candidateId: candidateId,
            betType: BetType(betType),
            amount: amount,
            claimed: false
        }));

        totalPool[epochId][marketType] += amount;
        userTotalStake[epochId][marketType][msg.sender] += amount;
        candidateBetTypeStake[epochId][marketType][candidateId][betType] += amount;
        buckets[epochId][marketType][betType].totalStaked += amount;

        emit Predicted(epochId, marketType, msg.sender, candidateId, amount, betType);
    }

    /// @notice Claim winnings across all buckets. Per-bucket refund if bucket has no winners.
    function claim(uint64 epochId, uint8 marketType) external nonReentrant {
        MarketConfig storage m = markets[epochId][marketType];
        if (m.state != MarketState.RESOLVED) revert MarketNotResolved();

        UserBet[] storage bets = _userBets[msg.sender][epochId][marketType];
        if (bets.length == 0) revert NothingToClaim();

        uint256 totalPayout;
        bool anyUnclaimed = false;

        for (uint256 i = 0; i < bets.length; i++) {
            if (bets[i].claimed) continue;
            anyUnclaimed = true;
            bets[i].claimed = true;

            uint8 bt = uint8(bets[i].betType);
            BucketState storage bucket = buckets[epochId][marketType][bt];

            if (bucket.winningShares > 0) {
                // Bucket has winners — pay from bucket reward if this bet won
                if (_isWinnerInternal(epochId, marketType, bets[i].candidateId, bets[i].betType)) {
                    totalPayout += (bets[i].amount * bucket.reward) / bucket.winningShares;
                }
            } else if (bucket.totalStaked > 0) {
                // Bucket has no winners — pro-rata refund from bucket reward
                totalPayout += (bets[i].amount * bucket.reward) / bucket.totalStaked;
            }
        }

        if (!anyUnclaimed) revert NothingToClaim();

        if (totalPayout > 0) {
            STAKE_TOKEN.safeTransfer(msg.sender, totalPayout);
        }

        emit Claimed(epochId, marketType, msg.sender, totalPayout);
    }

    // ─── Views ───────────────────────────────────────────────────────────

    function getUserBets(address user, uint64 epochId, uint8 marketType) external view returns (UserBet[] memory) {
        return _userBets[user][epochId][marketType];
    }

    function getUserBetCount(address user, uint64 epochId, uint8 marketType) external view returns (uint256) {
        return _userBets[user][epochId][marketType].length;
    }

    function marketDetails(uint64 epochId, uint8 marketType) external view returns (MarketConfig memory) {
        return markets[epochId][marketType];
    }

    function getBucketState(uint64 epochId, uint8 marketType, uint8 betType) external view returns (BucketState memory) {
        return buckets[epochId][marketType][betType];
    }

    /// @notice Preview total payout for a user across all buckets
    function previewPayout(address user, uint64 epochId, uint8 marketType) external view returns (uint256 payout) {
        if (markets[epochId][marketType].state != MarketState.RESOLVED) return 0;

        UserBet[] storage bets = _userBets[user][epochId][marketType];

        for (uint256 i = 0; i < bets.length; i++) {
            if (bets[i].claimed) continue;

            uint8 bt = uint8(bets[i].betType);
            BucketState storage bucket = buckets[epochId][marketType][bt];

            if (bucket.winningShares > 0) {
                if (_isWinnerInternal(epochId, marketType, bets[i].candidateId, bets[i].betType)) {
                    payout += (bets[i].amount * bucket.reward) / bucket.winningShares;
                }
            } else if (bucket.totalStaked > 0) {
                payout += (bets[i].amount * bucket.reward) / bucket.totalStaked;
            }
        }
    }

    function isWinner(
        uint64 epochId,
        uint8 marketType,
        bytes32 candidateId,
        BetType betType
    ) public view returns (bool) {
        return _isWinnerInternal(epochId, marketType, candidateId, betType);
    }

    // ─── Internal ────────────────────────────────────────────────────────

    function _isWinnerInternal(
        uint64 epochId,
        uint8 marketType,
        bytes32 candidateId,
        BetType betType
    ) internal view returns (bool) {
        bytes32[10] storage rankings = resolvedRankings[epochId][marketType];
        uint256 limit;
        if (betType == BetType.TOP_1) limit = 1;
        else if (betType == BetType.TOP_5) limit = 5;
        else limit = 10;

        for (uint256 i = 0; i < limit; i++) {
            if (rankings[i] == candidateId) return true;
        }
        return false;
    }
}
