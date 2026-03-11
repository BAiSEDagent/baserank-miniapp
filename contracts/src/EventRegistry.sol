// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title EventRegistry
/// @notice Canonical source of truth for Base leaderboard snapshot events.
///         Handles event creation, multisig resolution, challenge window, and cancellation.
///
/// @dev Security properties:
///  - Existence sentinel: candidates.length > 0 (not lockTime != 0)
///  - Time ordering enforced at creation: lockTime > now, resolveTime > lockTime
///  - resolutionTimeout enforced >= MIN_CHALLENGE_PERIOD + 1h buffer at creation
///  - cancelEvent() blocked in RESOLVE_SUBMITTED state to prevent race with finalize
///  - resolutionHash is computed on-chain from rankedCandidateIds (not caller-supplied)
///  - submitted ranks validated against canonical candidate set; duplicates rejected
///  - empty ranked list rejected
///  - rank data remains in storage after challenge-cancellation; callers MUST check isResolved()
///  - denylist stored here, enforced in TierMarket.predict()
contract EventRegistry is Ownable2Step {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum EventStatus {
        CREATED,
        RESOLVE_SUBMITTED,
        RESOLVED,
        CANCELLED
    }

    struct EventConfig {
        uint256 eventId;
        uint256 lockTime;          // staking disabled after this
        uint256 resolveTime;       // earliest resolution submission (must be > lockTime)
        uint256 claimWindow;       // seconds after resolution that claims are open (>= 30 days)
        uint256 resolutionTimeout; // seconds after lockTime before timeout-cancel is allowed
        bytes32[] candidateIds;    // immutable candidate set; no duplicates allowed
    }

    struct EventData {
        EventStatus status;
        uint256 lockTime;
        uint256 resolveTime;
        uint256 claimWindow;
        uint256 resolutionTimeout;
        uint256 submittedAt;       // when submitResolution was called
        uint256 finalizedAt;       // when finalizeResolution was called
        uint256 cancelledAt;
        bytes32 resolutionHash;    // keccak256(abi.encodePacked(rankedCandidateIds))
        bytes32 snapshotHash;      // off-chain provenance hash supplied by resolver
        address resolvedBy;
        // Snapshot global roles at event creation so mid-flight changes have no effect
        address resolver;
        address governance;
        bytes32[] candidates;      // immutable candidate list
        mapping(bytes32 => bool)   isCandidate;  // O(1) membership check
        mapping(bytes32 => uint16) finalRank;    // 1-based; 0 = unranked/loser
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    uint256 public constant MIN_CHALLENGE_PERIOD  = 24 hours;
    uint256 public constant MIN_CLAIM_WINDOW       = 30 days;
    /// @dev resolutionTimeout must cover at least the challenge period + 1h so that
    ///      finalizeResolution() is callable before timeout-cancel fires.
    uint256 public constant MIN_RESOLUTION_TIMEOUT = MIN_CHALLENGE_PERIOD + 1 hours;

    address public resolver;
    address public governance;

    /// @notice Addresses barred from predict() — should contain resolver signers only.
    ///         Enforced in TierMarket, stored here as the single source of truth.
    mapping(address => bool) public denylist;

    mapping(uint256 => EventData) private _events;
    uint256[] public eventIds;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event EventCreated(uint256 indexed eventId, uint256 lockTime, uint256 resolveTime, bytes32[] candidateIds);
    event ResolutionSubmitted(uint256 indexed eventId, address indexed by, bytes32 resolutionHash, bytes32 snapshotHash);
    event ResolutionChallenged(uint256 indexed eventId, address indexed challenger, string reason);
    event ResolutionFinalized(uint256 indexed eventId, uint256 finalizedAt);
    event EventCancelled(uint256 indexed eventId, address indexed triggeredBy);
    event ResolverUpdated(address indexed oldResolver, address indexed newResolver);
    event GovernanceUpdated(address indexed oldGovernance, address indexed newGovernance);
    event DenylistUpdated(address indexed account, bool denied);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error EventAlreadyExists(uint256 eventId);
    error EventDoesNotExist(uint256 eventId);
    error InvalidStatus(EventStatus current, EventStatus required);
    error EventAlreadyTerminal(EventStatus current);
    error TooEarlyToResolve(uint256 resolveTime, uint256 blockTime);
    error ChallengePeriodActive(uint256 endsAt);
    error ChallengePeriodExpired(uint256 endedAt);
    error ResolutionTimeoutNotReached(uint256 timeoutAt);
    error ResolutionInProgress();
    error ClaimWindowTooShort(uint256 provided, uint256 minimum);
    error ResolutionTimeoutTooShort(uint256 provided, uint256 minimum);
    error LockTimeInPast();
    error ResolveBeforeLock();
    error ZeroTimeout();
    error Unauthorized();
    error EmptyCandidateList();
    error EmptyRankedList();
    error DuplicateCandidate(bytes32 candidateId);
    error NotACandidate(bytes32 candidateId);
    error TooManyRanks(uint256 provided, uint256 maximum);
    error ZeroAddress();
    error TimeoutTooShortForResolution(uint256 timeoutAt, uint256 requiredAfter);
    error ZeroCandidateId();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address owner_, address resolver_, address governance_) Ownable(owner_) {
        if (resolver_ == address(0) || governance_ == address(0)) revert ZeroAddress();
        resolver   = resolver_;
        governance = governance_;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setResolver(address newResolver) external onlyOwner {
        if (newResolver == address(0)) revert ZeroAddress();
        emit ResolverUpdated(resolver, newResolver);
        resolver = newResolver;
    }

    function setGovernance(address newGovernance) external onlyOwner {
        if (newGovernance == address(0)) revert ZeroAddress();
        emit GovernanceUpdated(governance, newGovernance);
        governance = newGovernance;
    }

    /// @notice Add or remove an address from the staking denylist.
    ///         Keep this narrow: only add resolver signers.
    function setDenylist(address account, bool denied) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();  // [N-3/INFO] consistent zero-address guard
        denylist[account] = denied;
        emit DenylistUpdated(account, denied);
    }

    // -------------------------------------------------------------------------
    // Event creation
    // -------------------------------------------------------------------------

    function createEvent(EventConfig calldata cfg) external onlyOwner {
        if (_eventExists(cfg.eventId)) revert EventAlreadyExists(cfg.eventId);
        if (cfg.candidateIds.length == 0) revert EmptyCandidateList();
        // Time ordering
        if (cfg.lockTime <= block.timestamp) revert LockTimeInPast();
        if (cfg.resolveTime <= cfg.lockTime)  revert ResolveBeforeLock();
        if (cfg.resolutionTimeout == 0)       revert ZeroTimeout();
        // Claim window
        if (cfg.claimWindow < MIN_CLAIM_WINDOW) {
            revert ClaimWindowTooShort(cfg.claimWindow, MIN_CLAIM_WINDOW);
        }
        // Timeout must be long enough that finalizeResolution() can always fire before timeout-cancel
        if (cfg.resolutionTimeout < MIN_RESOLUTION_TIMEOUT) {
            revert ResolutionTimeoutTooShort(cfg.resolutionTimeout, MIN_RESOLUTION_TIMEOUT);
        }
        // [N-1] Ensure the resolver always has a window to submit AND the challenge period
        //       can complete before the timeout-cancel becomes actionable.
        //       Without this, an event with a far resolveTime but short resolutionTimeout
        //       can be cancelled before the resolver is even allowed to submit.
        if (cfg.lockTime + cfg.resolutionTimeout <= cfg.resolveTime + MIN_CHALLENGE_PERIOD) {
            revert TimeoutTooShortForResolution(
                cfg.lockTime + cfg.resolutionTimeout,
                cfg.resolveTime + MIN_CHALLENGE_PERIOD
            );
        }

        EventData storage e = _events[cfg.eventId];
        e.status            = EventStatus.CREATED;
        e.lockTime          = cfg.lockTime;
        e.resolveTime       = cfg.resolveTime;
        e.claimWindow       = cfg.claimWindow;
        e.resolutionTimeout = cfg.resolutionTimeout;
        // Snapshot roles so mid-flight global changes cannot affect a live event
        e.resolver          = resolver;
        e.governance        = governance;

        // Store candidate list + build O(1) membership map; reject duplicates
        for (uint256 i = 0; i < cfg.candidateIds.length; ) {
            bytes32 cId = cfg.candidateIds[i];
            if (cId == bytes32(0)) revert ZeroCandidateId();       // [N-3/LOW] reject zero IDs
            if (e.isCandidate[cId]) revert DuplicateCandidate(cId);
            e.isCandidate[cId] = true;
            e.candidates.push(cId);
            unchecked { ++i; }
        }

        eventIds.push(cfg.eventId);
        emit EventCreated(cfg.eventId, cfg.lockTime, cfg.resolveTime, cfg.candidateIds);
    }

    // -------------------------------------------------------------------------
    // Resolution flow
    // -------------------------------------------------------------------------

    /// @notice Resolver multisig submits the ranked candidate list.
    ///         resolutionHash is computed on-chain from the submitted array.
    ///         Starts the 24h challenge window; claims are NOT enabled yet.
    function submitResolution(
        uint256 eventId,
        bytes32[] calldata rankedCandidateIds,
        bytes32 snapshotHash  // off-chain provenance (separate from computed resolutionHash)
    ) external {
        EventData storage e = _getEvent(eventId);
        // Use per-event snapshotted resolver — global resolver changes do not affect live events
        if (msg.sender != e.resolver) revert Unauthorized();
        if (e.status != EventStatus.CREATED) revert InvalidStatus(e.status, EventStatus.CREATED);
        if (block.timestamp < e.resolveTime)  revert TooEarlyToResolve(e.resolveTime, block.timestamp);

        // Validate list
        if (rankedCandidateIds.length == 0) revert EmptyRankedList();
        if (rankedCandidateIds.length > e.candidates.length) {
            revert TooManyRanks(rankedCandidateIds.length, e.candidates.length);
        }
        if (rankedCandidateIds.length > type(uint16).max) {
            revert TooManyRanks(rankedCandidateIds.length, type(uint16).max);
        }

        for (uint256 i = 0; i < rankedCandidateIds.length; ) {
            bytes32 cId = rankedCandidateIds[i];
            if (!e.isCandidate[cId])   revert NotACandidate(cId);
            if (e.finalRank[cId] != 0) revert DuplicateCandidate(cId);
            // forge-lint: disable-next-line(unsafe-typecast)
            // safe: length <= e.candidates.length and <= type(uint16).max, checked above
            e.finalRank[cId] = uint16(i + 1);
            unchecked { ++i; }
        }

        // Compute binding hash from submitted data (not caller-supplied)
        e.resolutionHash = keccak256(abi.encodePacked(rankedCandidateIds));
        e.snapshotHash   = snapshotHash;
        e.resolvedBy     = msg.sender;
        e.submittedAt    = block.timestamp;
        e.status         = EventStatus.RESOLVE_SUBMITTED;

        emit ResolutionSubmitted(eventId, msg.sender, e.resolutionHash, snapshotHash);
    }

    /// @notice Governance vetoes a pending resolution, cancelling the event.
    ///         Only callable during the challenge window.
    ///         NOTE: rank data remains in storage; TierMarkets MUST check isResolved() before trusting ranks.
    function challengeResolution(uint256 eventId, string calldata reason) external {
        EventData storage e = _getEvent(eventId);
        // Use per-event snapshotted governance — global governance changes do not affect live events
        if (msg.sender != e.governance) revert Unauthorized();
        if (e.status != EventStatus.RESOLVE_SUBMITTED) {
            revert InvalidStatus(e.status, EventStatus.RESOLVE_SUBMITTED);
        }
        uint256 windowEnd = e.submittedAt + MIN_CHALLENGE_PERIOD;
        if (block.timestamp >= windowEnd) revert ChallengePeriodExpired(windowEnd);

        e.status      = EventStatus.CANCELLED;
        e.cancelledAt = block.timestamp;

        emit ResolutionChallenged(eventId, msg.sender, reason);
        emit EventCancelled(eventId, msg.sender);
    }

    /// @notice Permissionless: finalises resolution after challenge window expires.
    ///         After this call, TierMarkets may resolve and claims open.
    function finalizeResolution(uint256 eventId) external {
        EventData storage e = _getEvent(eventId);
        if (e.status != EventStatus.RESOLVE_SUBMITTED) {
            revert InvalidStatus(e.status, EventStatus.RESOLVE_SUBMITTED);
        }
        uint256 windowEnd = e.submittedAt + MIN_CHALLENGE_PERIOD;
        if (block.timestamp < windowEnd) revert ChallengePeriodActive(windowEnd);

        e.status      = EventStatus.RESOLVED;
        e.finalizedAt = block.timestamp;

        emit ResolutionFinalized(eventId, block.timestamp);
    }

    /// @notice Permissionless: cancels an event if no valid resolution was finalised
    ///         within resolutionTimeout after lockTime.
    ///         Blocked during RESOLVE_SUBMITTED to prevent racing with finalizeResolution().
    function cancelEvent(uint256 eventId) external {
        EventData storage e = _getEvent(eventId);
        if (e.status == EventStatus.RESOLVED || e.status == EventStatus.CANCELLED) {
            revert EventAlreadyTerminal(e.status);
        }
        // Do not allow timeout-cancel while a valid resolution is in its challenge window
        if (e.status == EventStatus.RESOLVE_SUBMITTED) revert ResolutionInProgress();

        uint256 timeoutAt = e.lockTime + e.resolutionTimeout;
        if (block.timestamp < timeoutAt) revert ResolutionTimeoutNotReached(timeoutAt);

        e.status      = EventStatus.CANCELLED;
        e.cancelledAt = block.timestamp;

        emit EventCancelled(eventId, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function isResolved(uint256 eventId) external view returns (bool) {
        return _events[eventId].status == EventStatus.RESOLVED;
    }

    function isCancelled(uint256 eventId) external view returns (bool) {
        return _events[eventId].status == EventStatus.CANCELLED;
    }

    function getStatus(uint256 eventId) external view returns (EventStatus) {
        return _events[eventId].status;
    }

    /// @notice Returns 1-based rank. 0 means unranked.
    /// @dev ONLY valid when isResolved(eventId) == true. Callers MUST check status.
    function finalRank(uint256 eventId, bytes32 candidateId) external view returns (uint16) {
        return _events[eventId].finalRank[candidateId];
    }

    /// @notice Guarded rank view — reverts unless the event is RESOLVED.
    function resolvedFinalRank(uint256 eventId, bytes32 candidateId) external view returns (uint16) {
        if (_events[eventId].status != EventStatus.RESOLVED) {
            revert InvalidStatus(_events[eventId].status, EventStatus.RESOLVED);
        }
        return _events[eventId].finalRank[candidateId];
    }

    function candidates(uint256 eventId) external view returns (bytes32[] memory) {
        return _events[eventId].candidates;
    }

    function getEventMeta(uint256 eventId)
        external
        view
        returns (
            EventStatus status,
            uint256 lockTime,
            uint256 resolveTime,
            uint256 claimWindow,
            uint256 submittedAt,
            uint256 finalizedAt,
            uint256 cancelledAt,
            bytes32 resolutionHash,
            bytes32 snapshotHash,
            address resolvedBy
        )
    {
        EventData storage e = _events[eventId];
        return (
            e.status,
            e.lockTime,
            e.resolveTime,
            e.claimWindow,
            e.submittedAt,
            e.finalizedAt,
            e.cancelledAt,
            e.resolutionHash,
            e.snapshotHash,
            e.resolvedBy
        );
    }

    /// @notice Timestamp when claims open. Returns 0 if not yet resolvable.
    ///         For CANCELLED events, claimsOpenAt = cancelledAt (refunds available immediately).
    function claimsOpenAt(uint256 eventId) external view returns (uint256) {
        EventData storage e = _events[eventId];
        if (e.status == EventStatus.RESOLVED)  return e.finalizedAt;
        if (e.status == EventStatus.CANCELLED) return e.cancelledAt;
        return 0;
    }

    /// @notice Timestamp after which no claims/refunds can be made.
    function claimDeadline(uint256 eventId) external view returns (uint256) {
        EventData storage e = _events[eventId];
        uint256 openAt;
        if (e.status == EventStatus.RESOLVED)       openAt = e.finalizedAt;
        else if (e.status == EventStatus.CANCELLED) openAt = e.cancelledAt;
        else return 0;
        return openAt + e.claimWindow;
    }

    function eventCount() external view returns (uint256) {
        return eventIds.length;
    }

    /// @notice Returns all timing parameters needed for countdown/cancel UX.
    function getEventTiming(uint256 eventId)
        external
        view
        returns (
            uint256 lockTime,
            uint256 resolveTime,
            uint256 resolutionTimeout,
            uint256 claimWindow,
            address eventResolver,
            address eventGovernance
        )
    {
        EventData storage e = _events[eventId];
        return (e.lockTime, e.resolveTime, e.resolutionTimeout, e.claimWindow, e.resolver, e.governance);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Existence check uses candidates.length > 0 (not lockTime != 0).
    function _eventExists(uint256 eventId) internal view returns (bool) {
        return _events[eventId].candidates.length > 0;
    }

    function _getEvent(uint256 eventId) internal view returns (EventData storage) {
        if (!_eventExists(eventId)) revert EventDoesNotExist(eventId);
        return _events[eventId];
    }
}
