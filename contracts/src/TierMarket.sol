// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal interface for EventRegistry consumed by TierMarket.
interface IEventRegistry {
    function isResolved(uint256 eventId) external view returns (bool);
    function isCancelled(uint256 eventId) external view returns (bool);
    function resolvedFinalRank(uint256 eventId, bytes32 candidateId) external view returns (uint16);
    function claimDeadline(uint256 eventId) external view returns (uint256);
    function denylist(address account) external view returns (bool);
    function candidates(uint256 eventId) external view returns (bytes32[] memory);
}

/// @title TierMarket
/// @notice Isolated pari-mutuel prediction pool for one tier (Top 10 / Top 5 / #1) of one event.
///
/// @dev Security guarantees:
///  - CEI pattern + ReentrancyGuard on all value-transferring functions
///  - feeBps immutable after construction
///  - Resolver denylist enforced from EventRegistry
///  - No ETH accepted — USDC pull only
///  - No cross-market fund movement
///  - No-winner: feeAmount forced to 0, full refunds
///  - claim() and finalizeMarket() check deadline and finalized flag
///  - finalizeMarket() is one-shot (sets finalized = true before transfer)
///  - resolve() reads ranks only from EventRegistry (never from caller args)
///  - cancelMarket() callable if registry event is cancelled
contract TierMarket is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum MarketStatus { OPEN, LOCKED, RESOLVED, CANCELLED }

    // -------------------------------------------------------------------------
    // Immutable config
    // -------------------------------------------------------------------------

    IERC20           public immutable usdc;
    IEventRegistry   public immutable registry;
    uint256          public immutable eventId;
    uint16           public immutable tierThreshold; // 10 = Top10, 5 = Top5, 1 = #1
    uint16           public immutable feeBps;        // e.g. 200 = 2%; immutable per market
    address          public immutable feeRecipient;
    uint256          public immutable lockTime;
    uint256          public immutable minStake;                 // per predict() call
    uint256          public immutable maxStakePerUserPerCandidate; // 0 = uncapped

    // -------------------------------------------------------------------------
    // Mutable state — accounting
    // -------------------------------------------------------------------------

    MarketStatus public status;
    bool         public finalized;

    uint256 public totalStaked;
    uint256 public feeAmount;    // computed at resolve(); held until finalizeMarket()
    uint256 public netPool;      // totalStaked - feeAmount
    uint256 public winningStake; // sum of stakes on winning candidates
    uint256 public totalClaimed;
    bool    public noWinner;     // true if winningStake == 0

    // candidateId => total USDC staked on that candidate
    mapping(bytes32 => uint256) public candidateStake;

    // user => candidateId => USDC staked
    mapping(address => mapping(bytes32 => uint256)) public userCandidateStake;

    // candidateId => true after resolve() marks it as winning
    mapping(bytes32 => bool) public isWinner;

    // user => true once claimed (or refunded)
    mapping(address => bool) public claimed;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Predicted(address indexed user, bytes32 indexed candidateId, uint256 amount);
    event MarketLocked(uint256 totalStaked_);
    event MarketResolved(uint256 feeAmount_, uint256 netPool_, uint256 winningStake_, bool noWinner_);
    event MarketCancelled();
    event Claimed(address indexed user, uint256 amount);
    event MarketFinalized(uint256 remaining);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotOpen();
    error NotLocked();
    error NotResolved();
    error NotCancelled();
    error AlreadyResolved();
    error AlreadyCancelled();
    error AlreadyFinalized();
    error AlreadyClaimed();
    error ClaimDeadlinePassed();
    error FinalizeBeforeDeadline(uint256 deadline, uint256 blockTime);
    error NothingToClaim();
    error BelowMinStake(uint256 provided, uint256 minimum);
    error MaxStakeExceeded(uint256 wouldBe, uint256 maximum);
    error DeniedAddress(address account);
    error EventNotResolvedYet();
    error EventNotCancelledYet();
    error RegistryNotYetResolvable();
    error FeeBpsTooHigh(uint16 provided, uint16 maximum);
    error ZeroAddress();
    error LockTimeInPast();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param owner_                       Market owner (should be Safe multisig)
    /// @param usdc_                        USDC token address
    /// @param registry_                    EventRegistry address
    /// @param eventId_                     Event this market belongs to
    /// @param tierThreshold_               1 = #1, 5 = Top5, 10 = Top10
    /// @param feeBps_                      Protocol fee in basis points (max 1000 = 10%)
    /// @param feeRecipient_                Where fees/sweeps go
    /// @param lockTime_                    When staking closes (must be in future)
    /// @param minStake_                    Minimum USDC per predict() call
    /// @param maxStakePerUserPerCandidate_ Per-user per-candidate cap (0 = uncapped)
    constructor(
        address owner_,
        address usdc_,
        address registry_,
        uint256 eventId_,
        uint16  tierThreshold_,
        uint16  feeBps_,
        address feeRecipient_,
        uint256 lockTime_,
        uint256 minStake_,
        uint256 maxStakePerUserPerCandidate_
    ) Ownable(owner_) {
        if (usdc_ == address(0) || registry_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeBps_ > 1000) revert FeeBpsTooHigh(feeBps_, 1000);
        if (lockTime_ <= block.timestamp) revert LockTimeInPast();

        usdc                        = IERC20(usdc_);
        registry                    = IEventRegistry(registry_);
        eventId                     = eventId_;
        tierThreshold               = tierThreshold_;
        feeBps                      = feeBps_;
        feeRecipient                = feeRecipient_;
        lockTime                    = lockTime_;
        minStake                    = minStake_;
        maxStakePerUserPerCandidate = maxStakePerUserPerCandidate_;

        status = MarketStatus.OPEN;
    }

    // -------------------------------------------------------------------------
    // Staking
    // -------------------------------------------------------------------------

    /// @notice Stake USDC on a candidate app within this tier.
    ///         Caller must pre-approve this contract for `amount` USDC.
    ///         Cannot be called by addresses on the EventRegistry denylist.
    function predict(bytes32 candidateId, uint256 amount) external nonReentrant {
        // Status checks
        if (status != MarketStatus.OPEN) revert NotOpen();
        if (block.timestamp >= lockTime) revert NotOpen(); // auto-lock enforcement

        // Denylist check (resolver signers may not stake)
        if (registry.denylist(msg.sender)) revert DeniedAddress(msg.sender);

        // Stake size checks
        if (amount < minStake) revert BelowMinStake(amount, minStake);
        if (maxStakePerUserPerCandidate != 0) {
            uint256 wouldBe = userCandidateStake[msg.sender][candidateId] + amount;
            if (wouldBe > maxStakePerUserPerCandidate) {
                revert MaxStakeExceeded(wouldBe, maxStakePerUserPerCandidate);
            }
        }

        // Effects
        userCandidateStake[msg.sender][candidateId] += amount;
        candidateStake[candidateId]                  += amount;
        totalStaked                                  += amount;

        // Interaction — pull USDC from caller (CEI: state written above)
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit Predicted(msg.sender, candidateId, amount);
    }

    // -------------------------------------------------------------------------
    // Lifecycle transitions
    // -------------------------------------------------------------------------

    /// @notice Transitions OPEN → LOCKED. Permissionless once block.timestamp >= lockTime.
    function lock() external {
        if (status != MarketStatus.OPEN) revert NotOpen();
        if (block.timestamp < lockTime) revert NotOpen();
        status = MarketStatus.LOCKED;
        emit MarketLocked(totalStaked);
    }

    /// @notice Permissionless: resolves market by pulling final ranks from EventRegistry.
    ///         Market must be LOCKED; registry event must be RESOLVED (not just submitted).
    ///         Snapshots feeAmount, netPool, winningStake, and winner set.
    ///         If winningStake == 0 (no-winner): feeAmount forced to 0, full refunds.
    function resolve() external {
        if (status != MarketStatus.LOCKED) revert NotLocked();

        // Enforce auto-lock if lock() was never called
        if (block.timestamp < lockTime) revert NotLocked();

        // Only read from registry after it has fully finalized (past challenge window)
        if (!registry.isResolved(eventId)) revert EventNotResolvedYet();

        // Snapshot winner set from registry — never from caller args
        bytes32[] memory cands = registry.candidates(eventId);
        uint256 _winningStake;
        for (uint256 i = 0; i < cands.length; ) {
            bytes32 cId = cands[i];
            uint16 rank = registry.resolvedFinalRank(eventId, cId);
            // rank > 0 && rank <= tierThreshold → winner in this tier
            if (rank > 0 && rank <= tierThreshold) {
                isWinner[cId]   = true;
                _winningStake  += candidateStake[cId];
            }
            unchecked { ++i; }
        }

        winningStake = _winningStake;

        if (_winningStake == 0) {
            // No-winner: full refunds, no fee
            noWinner   = true;
            feeAmount  = 0;
            netPool    = totalStaked;
        } else {
            feeAmount  = (totalStaked * feeBps) / 10_000;
            netPool    = totalStaked - feeAmount;
        }

        status = MarketStatus.RESOLVED;
        emit MarketResolved(feeAmount, netPool, winningStake, noWinner);
    }

    /// @notice Cancels this market if the corresponding registry event is cancelled.
    ///         Permissionless — anyone can trigger once the event is cancelled.
    function cancelMarket() external {
        if (status == MarketStatus.CANCELLED) revert AlreadyCancelled();
        if (status == MarketStatus.RESOLVED)  revert AlreadyResolved();
        if (!registry.isCancelled(eventId))   revert EventNotCancelledYet();

        status    = MarketStatus.CANCELLED;
        feeAmount = 0;
        netPool   = totalStaked; // full refund basis

        emit MarketCancelled();
    }

    // -------------------------------------------------------------------------
    // Claims
    // -------------------------------------------------------------------------

    /// @notice Claim winnings (RESOLVED) or refund (CANCELLED / no-winner RESOLVED).
    ///         Follows CEI: mark claimed before transfer.
    ///         Reverts after claimDeadline or after finalization.
    function claim() external nonReentrant {
        if (status != MarketStatus.RESOLVED && status != MarketStatus.CANCELLED) {
            revert NotResolved();
        }
        if (finalized) revert AlreadyFinalized();
        if (claimed[msg.sender]) revert AlreadyClaimed();

        uint256 deadline = registry.claimDeadline(eventId);
        if (block.timestamp > deadline) revert ClaimDeadlinePassed();

        uint256 payout = _computePayout(msg.sender);
        if (payout == 0) revert NothingToClaim();

        // Effects — set before transfer (CEI)
        claimed[msg.sender]  = true;
        totalClaimed        += payout;

        // Interaction
        usdc.safeTransfer(msg.sender, payout);

        emit Claimed(msg.sender, payout);
    }

    /// @notice Preview claimable amount for a user without side effects.
    function claimable(address user) external view returns (uint256) {
        if (status != MarketStatus.RESOLVED && status != MarketStatus.CANCELLED) return 0;
        if (finalized) return 0;
        if (claimed[user]) return 0;
        uint256 deadline = registry.claimDeadline(eventId);
        if (block.timestamp > deadline) return 0;
        return _computePayout(user);
    }

    // -------------------------------------------------------------------------
    // Finalization
    // -------------------------------------------------------------------------

    /// @notice Owner sweeps remaining balance (feeAmount + forfeited/unclaimed winnings)
    ///         to feeRecipient after claimDeadline. One-shot; sets finalized = true.
    function finalizeMarket() external onlyOwner nonReentrant {
        if (status != MarketStatus.RESOLVED && status != MarketStatus.CANCELLED) {
            revert NotResolved();
        }
        if (finalized) revert AlreadyFinalized();

        uint256 deadline = registry.claimDeadline(eventId);
        if (block.timestamp <= deadline) {
            revert FinalizeBeforeDeadline(deadline, block.timestamp);
        }

        // Effects — set finalized before transfer (CEI)
        finalized = true;

        uint256 remaining = usdc.balanceOf(address(this));
        if (remaining > 0) {
            usdc.safeTransfer(feeRecipient, remaining);
        }

        emit MarketFinalized(remaining);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Computes the payout for a user.
    ///      Normal (winner): userStakeOnWinners * netPool / winningStake
    ///      No-winner / cancelled: full stake refund (netPool == totalStaked, fee == 0)
    function _computePayout(address user) internal view returns (uint256) {
        if (noWinner || status == MarketStatus.CANCELLED) {
            // Refund: sum all stakes across all candidates for this user
            return _userTotalStake(user);
        }

        // Normal payout: only stakes on winning candidates count
        bytes32[] memory cands = registry.candidates(eventId);
        uint256 userWinningStake;
        for (uint256 i = 0; i < cands.length; ) {
            if (isWinner[cands[i]]) {
                userWinningStake += userCandidateStake[user][cands[i]];
            }
            unchecked { ++i; }
        }
        if (userWinningStake == 0) return 0;

        // Mul before div to preserve precision
        return (userWinningStake * netPool) / winningStake;
    }

    /// @dev Returns total USDC a user has staked across all candidates in this market.
    function _userTotalStake(address user) internal view returns (uint256) {
        bytes32[] memory cands = registry.candidates(eventId);
        uint256 total;
        for (uint256 i = 0; i < cands.length; ) {
            total += userCandidateStake[user][cands[i]];
            unchecked { ++i; }
        }
        return total;
    }
}
