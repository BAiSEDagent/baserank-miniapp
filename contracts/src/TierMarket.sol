// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
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
///  - CEI + ReentrancyGuard on all value-transferring and state-mutating functions
///  - feeBps immutable after construction
///  - Local candidate snapshot at construction: O(1) isCandidate check, no repeated external calls
///  - Resolver denylist enforced from EventRegistry
///  - No ETH accepted — USDC pull only (no receive/fallback)
///  - No cross-market fund movement
///  - No-winner: feeAmount forced to 0, full refunds (also set for cancelled markets)
///  - claim() reverts after claimDeadline or if finalized
///  - finalizeMarket() is one-shot (sets finalized = true before transfer)
///  - resolve() reads ranks only from EventRegistry (never from caller args)
///  - resolve() auto-locks the market if lock() was never called
///  - lock() allows owner to lock early for emergency; permissionless after lockTime
///  - cancelMarket() permissionless once registry event is cancelled; nonReentrant
contract TierMarket is Ownable2Step, ReentrancyGuard {
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
    uint16           public immutable feeBps;        // immutable per market; max 1000 (10%)
    address          public immutable feeRecipient;
    uint256          public immutable lockTime;
    uint256          public immutable minStake;                  // must be > 0
    uint256          public immutable maxStakePerUserPerCandidate; // 0 = uncapped

    // -------------------------------------------------------------------------
    // Local candidate snapshot (populated at construction; never mutated)
    // -------------------------------------------------------------------------

    bytes32[] public candidateList;                     // ordered list for iteration
    mapping(bytes32 => bool) public isCandidate;        // O(1) membership check

    // -------------------------------------------------------------------------
    // Mutable state — accounting
    // -------------------------------------------------------------------------

    MarketStatus public status;
    bool         public finalized;
    bool         public noWinner; // true if winningStake == 0 OR market is cancelled

    uint256 public totalStaked;
    uint256 public feeAmount;    // computed at resolve(); held until finalizeMarket()
    uint256 public netPool;      // totalStaked - feeAmount
    uint256 public winningStake; // sum of stakes on winning candidates
    uint256 public totalClaimed;

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
    error NotACandidate(bytes32 candidateId);
    error EventNotResolvedYet();
    error EventNotCancelledYet();
    error FeeBpsTooHigh(uint16 provided, uint16 maximum);
    error InvalidTierThreshold(uint16 provided);
    error ZeroAddress();
    error ZeroMinStake();
    error LockTimeInPast();
    error TooEarlyToLock(uint256 lockTime_, uint256 blockTime);
    error StakingWindowClosed();
    error EventCancelled();
    error EmptyCandidateSet();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param owner_                         Market owner (should be Safe multisig)
    /// @param usdc_                          USDC token address
    /// @param registry_                      EventRegistry address
    /// @param eventId_                       Event this market belongs to
    /// @param tierThreshold_                 1 = #1, 5 = Top5, 10 = Top10 (must be 1–100)
    /// @param feeBps_                        Protocol fee in basis points (max 1000 = 10%)
    /// @param feeRecipient_                  Where fees and forfeited funds go
    /// @param lockTime_                      When staking closes (must be in future)
    /// @param minStake_                      Minimum USDC per predict() call (must be > 0)
    /// @param maxStakePerUserPerCandidate_   Per-user per-candidate cap (0 = uncapped)
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
        if (usdc_ == address(0) || registry_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        if (feeBps_ > 1000) revert FeeBpsTooHigh(feeBps_, 1000);
        // Only spec-defined tier values are valid
        if (tierThreshold_ != 1 && tierThreshold_ != 5 && tierThreshold_ != 10) {
            revert InvalidTierThreshold(tierThreshold_);
        }
        if (lockTime_ <= block.timestamp) revert LockTimeInPast();
        if (minStake_ == 0) revert ZeroMinStake();

        usdc                        = IERC20(usdc_);
        registry                    = IEventRegistry(registry_);
        eventId                     = eventId_;
        tierThreshold               = tierThreshold_;
        feeBps                      = feeBps_;
        feeRecipient                = feeRecipient_;
        lockTime                    = lockTime_;
        minStake                    = minStake_;
        maxStakePerUserPerCandidate = maxStakePerUserPerCandidate_;

        // Snapshot candidate list locally for O(1) membership checks and gas-efficient iteration
        bytes32[] memory cands = IEventRegistry(registry_).candidates(eventId_);
        if (cands.length == 0) revert EmptyCandidateSet(); // event doesn't exist or has no candidates
        for (uint256 i = 0; i < cands.length; ) {
            candidateList.push(cands[i]);
            isCandidate[cands[i]] = true;
            unchecked { ++i; }
        }

        status = MarketStatus.OPEN;
    }

    // -------------------------------------------------------------------------
    // Staking
    // -------------------------------------------------------------------------

    /// @notice Stake USDC on a candidate app within this tier.
    ///         Caller must pre-approve this contract for `amount` USDC.
    ///         Reverts for unknown candidates and addresses on the denylist.
    function predict(bytes32 candidateId, uint256 amount) external nonReentrant {
        if (status != MarketStatus.OPEN) revert NotOpen();
        if (block.timestamp >= lockTime) revert StakingWindowClosed();

        // Registry event already cancelled — block new stakes immediately
        if (registry.isCancelled(eventId)) revert EventCancelled();

        // Candidate must be in the event's canonical set
        if (!isCandidate[candidateId]) revert NotACandidate(candidateId);

        // Resolver signers may not stake (insider trading prevention)
        if (registry.denylist(msg.sender)) revert DeniedAddress(msg.sender);

        // Stake size checks
        if (amount < minStake) revert BelowMinStake(amount, minStake);
        if (maxStakePerUserPerCandidate != 0) {
            uint256 wouldBe = userCandidateStake[msg.sender][candidateId] + amount;
            if (wouldBe > maxStakePerUserPerCandidate) {
                revert MaxStakeExceeded(wouldBe, maxStakePerUserPerCandidate);
            }
        }

        // Effects (CEI: state written before interaction)
        userCandidateStake[msg.sender][candidateId] += amount;
        candidateStake[candidateId]                  += amount;
        totalStaked                                  += amount;

        // Interaction
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit Predicted(msg.sender, candidateId, amount);
    }

    // -------------------------------------------------------------------------
    // Lifecycle transitions
    // -------------------------------------------------------------------------

    /// @notice Transitions OPEN → LOCKED.
    ///         Owner can lock at any time (emergency); anyone can lock after lockTime.
    function lock() external {
        if (status != MarketStatus.OPEN) revert NotOpen();
        if (block.timestamp < lockTime && msg.sender != owner()) {
            revert TooEarlyToLock(lockTime, block.timestamp);
        }
        status = MarketStatus.LOCKED;
        emit MarketLocked(totalStaked);
    }

    /// @notice Permissionless: resolves market by pulling final ranks from EventRegistry.
    ///         Auto-locks if lock() was never called but lockTime has passed.
    ///         Registry event must be fully RESOLVED (past challenge window).
    ///         Snapshots feeAmount, netPool, winningStake, and winner set on-chain.
    function resolve() external {
        // Auto-lock if still OPEN and lockTime has passed
        if (status == MarketStatus.OPEN && block.timestamp >= lockTime) {
            status = MarketStatus.LOCKED;
            emit MarketLocked(totalStaked);
        }
        if (status != MarketStatus.LOCKED) revert NotLocked();

        // Only pull ranks after registry has fully finalized (past challenge window)
        if (!registry.isResolved(eventId)) revert EventNotResolvedYet();

        // Snapshot winner set from registry — never from caller args
        uint256 _winningStake;
        for (uint256 i = 0; i < candidateList.length; ) {
            bytes32 cId  = candidateList[i];
            uint16  rank = registry.resolvedFinalRank(eventId, cId);
            if (rank > 0 && rank <= tierThreshold) {
                isWinner[cId]  = true;
                _winningStake += candidateStake[cId];
            }
            unchecked { ++i; }
        }

        winningStake = _winningStake;

        if (_winningStake == 0) {
            noWinner  = true;
            feeAmount = 0;
            netPool   = totalStaked;
        } else {
            feeAmount = (totalStaked * feeBps) / 10_000;
            netPool   = totalStaked - feeAmount;
        }

        status = MarketStatus.RESOLVED;
        emit MarketResolved(feeAmount, netPool, winningStake, noWinner);
    }

    /// @notice Permissionless: cancels this market if the registry event is cancelled.
    ///         Sets noWinner = true so external consumers see consistent refund status.
    function cancelMarket() external nonReentrant {
        if (status == MarketStatus.CANCELLED) revert AlreadyCancelled();
        if (status == MarketStatus.RESOLVED)  revert AlreadyResolved();
        if (!registry.isCancelled(eventId))   revert EventNotCancelledYet();

        // Effects
        status    = MarketStatus.CANCELLED;
        feeAmount = 0;
        netPool   = totalStaked;  // full refund basis
        noWinner  = true;         // consistent signal for subgraphs/UIs

        emit MarketCancelled();
    }

    // -------------------------------------------------------------------------
    // Claims
    // -------------------------------------------------------------------------

    /// @notice Convenience wrapper — claims on behalf of msg.sender.
    function claim() external nonReentrant {
        _claim(msg.sender);
    }

    /// @notice Delegated claim — computes payout for `user` and transfers to `user`.
    ///         Caller can be any address (e.g. BatchClaimer). Funds NEVER go to caller.
    ///         Non-custodial: CEI enforced, claimed[user] prevents double-claims regardless of caller.
    function claimFor(address user) external nonReentrant {
        _claim(user);
    }

    /// @dev Internal claim logic shared by claim() and claimFor().
    ///      Payout is always sent to `user`; `msg.sender` is irrelevant.
    function _claim(address user) internal {
        if (status != MarketStatus.RESOLVED && status != MarketStatus.CANCELLED) {
            revert NotResolved();
        }
        if (finalized)       revert AlreadyFinalized();
        if (claimed[user])   revert AlreadyClaimed();

        uint256 deadline = registry.claimDeadline(eventId);
        if (block.timestamp > deadline) revert ClaimDeadlinePassed();

        uint256 payout = _computePayout(user);
        if (payout == 0) revert NothingToClaim();

        // Effects — set before transfer (CEI)
        claimed[user]  = true;
        totalClaimed  += payout;

        // Interaction — funds always go to user, not msg.sender
        usdc.safeTransfer(user, payout);

        emit Claimed(user, payout);
    }

    /// @notice Preview claimable amount without side effects.
    function claimable(address user) external view returns (uint256) {
        // NOTE: used by BatchClaimer.previewMany() — must remain a view function
        if (status != MarketStatus.RESOLVED && status != MarketStatus.CANCELLED) return 0;
        if (finalized)           return 0;
        if (claimed[user])       return 0;
        uint256 deadline = registry.claimDeadline(eventId);
        if (block.timestamp > deadline) return 0;
        return _computePayout(user);
    }

    // -------------------------------------------------------------------------
    // Finalization
    // -------------------------------------------------------------------------

    /// @notice Owner sweeps remaining balance (fee + forfeited unclaimed winnings/refunds)
    ///         to feeRecipient after claimDeadline. One-shot; sets finalized before transfer.
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
    // Views
    // -------------------------------------------------------------------------

    function candidateCount() external view returns (uint256) {
        return candidateList.length;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Computes payout for a user using local candidateList (no external array call).
    ///      Normal winner: userStakeOnWinners * netPool / winningStake  (mul before div)
    ///      No-winner / cancelled: sum of all stakes across all candidates (full refund)
    function _computePayout(address user) internal view returns (uint256) {
        if (noWinner || status == MarketStatus.CANCELLED) {
            return _userTotalStake(user);
        }

        uint256 userWinningStake;
        for (uint256 i = 0; i < candidateList.length; ) {
            bytes32 cId = candidateList[i];
            if (isWinner[cId]) {
                userWinningStake += userCandidateStake[user][cId];
            }
            unchecked { ++i; }
        }
        if (userWinningStake == 0) return 0;

        // Mul before div to preserve precision
        return (userWinningStake * netPool) / winningStake;
    }

    /// @dev Returns total USDC a user has staked across all candidates in this market.
    function _userTotalStake(address user) internal view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < candidateList.length; ) {
            total += userCandidateStake[user][candidateList[i]];
            unchecked { ++i; }
        }
        return total;
    }
}
