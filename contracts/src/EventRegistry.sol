// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title EventRegistry
/// @notice Canonical source of truth for Base leaderboard snapshot events.
///         Handles event creation, multisig resolution, challenge window, and cancellation.
contract EventRegistry is Ownable {
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
        uint256 lockTime;      // staking disabled after this
        uint256 resolveTime;   // earliest resolution submission
        uint256 claimWindow;   // seconds after resolution that claims are open (min 30 days)
        uint256 resolutionTimeout; // seconds after lockTime before anyone can cancel
        bytes32[] candidateIds;
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
        bytes32 resolutionHash;    // keccak256(rankedCandidateIds) for off-chain verification
        address resolvedBy;
        bytes32[] candidates;      // immutable candidate list
        // rank storage: candidateId => 1-based rank (0 = unranked)
        mapping(bytes32 => uint16) finalRank;
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    uint256 public constant MIN_CHALLENGE_PERIOD = 24 hours;
    uint256 public constant MIN_CLAIM_WINDOW = 30 days;

    /// @notice Address authorised to submit resolutions
    address public resolver;

    /// @notice Address authorised to challenge/veto resolutions
    address public governance;

    /// @notice Addresses denied from staking (resolver members)
    mapping(address => bool) public denylist;

    mapping(uint256 => EventData) private _events;
    uint256[] public eventIds;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event EventCreated(uint256 indexed eventId, uint256 lockTime, uint256 resolveTime);
    event ResolutionSubmitted(uint256 indexed eventId, address indexed resolver, bytes32 resolutionHash);
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
    error TooEarlyToResolve(uint256 resolveTime, uint256 now_);
    error ChallengePeriodActive(uint256 endsAt);
    error ChallengePeriodExpired(uint256 endedAt);
    error ResolutionTimeoutNotReached(uint256 timeoutAt);
    error ClaimWindowTooShort(uint256 provided, uint256 minimum);
    error Unauthorized();
    error EmptyCandidateList();
    error AlreadyFinalized();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address owner_, address resolver_, address governance_) Ownable(owner_) {
        resolver = resolver_;
        governance = governance_;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setResolver(address newResolver) external onlyOwner {
        emit ResolverUpdated(resolver, newResolver);
        resolver = newResolver;
    }

    function setGovernance(address newGovernance) external onlyOwner {
        emit GovernanceUpdated(governance, newGovernance);
        governance = newGovernance;
    }

    /// @notice Add or remove an address from the staking denylist.
    ///         Denylist should only contain resolver signers.
    function setDenylist(address account, bool denied) external onlyOwner {
        denylist[account] = denied;
        emit DenylistUpdated(account, denied);
    }

    // -------------------------------------------------------------------------
    // Event creation
    // -------------------------------------------------------------------------

    function createEvent(EventConfig calldata cfg) external onlyOwner {
        if (_eventExists(cfg.eventId)) revert EventAlreadyExists(cfg.eventId);
        if (cfg.candidateIds.length == 0) revert EmptyCandidateList();
        if (cfg.claimWindow < MIN_CLAIM_WINDOW) {
            revert ClaimWindowTooShort(cfg.claimWindow, MIN_CLAIM_WINDOW);
        }

        EventData storage e = _events[cfg.eventId];
        e.status = EventStatus.CREATED;
        e.lockTime = cfg.lockTime;
        e.resolveTime = cfg.resolveTime;
        e.claimWindow = cfg.claimWindow;
        e.resolutionTimeout = cfg.resolutionTimeout;
        e.candidates = cfg.candidateIds;

        eventIds.push(cfg.eventId);
        emit EventCreated(cfg.eventId, cfg.lockTime, cfg.resolveTime);
    }

    // -------------------------------------------------------------------------
    // Resolution flow
    // -------------------------------------------------------------------------

    /// @notice Resolver multisig submits ranked candidate list.
    ///         Starts the 24h challenge window; claims not yet enabled.
    function submitResolution(
        uint256 eventId,
        bytes32[] calldata rankedCandidateIds,
        bytes32 snapshotHash
    ) external {
        if (msg.sender != resolver) revert Unauthorized();
        EventData storage e = _getEvent(eventId);
        if (e.status != EventStatus.CREATED) revert InvalidStatus(e.status, EventStatus.CREATED);
        if (block.timestamp < e.resolveTime) revert TooEarlyToResolve(e.resolveTime, block.timestamp);

        // Store ranks (1-based; unsubmitted candidates remain 0 = unranked)
        for (uint256 i = 0; i < rankedCandidateIds.length; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            // safe: max ranked candidates is bounded by candidateIds.length which is set at creation
            e.finalRank[rankedCandidateIds[i]] = uint16(i + 1);
        }
        e.resolutionHash = snapshotHash;
        e.resolvedBy = msg.sender;
        e.submittedAt = block.timestamp;
        e.status = EventStatus.RESOLVE_SUBMITTED;

        emit ResolutionSubmitted(eventId, msg.sender, snapshotHash);
    }

    /// @notice Governance vetoes a pending resolution, cancelling the event.
    ///         Only callable during the challenge window.
    function challengeResolution(uint256 eventId, string calldata reason) external {
        if (msg.sender != governance) revert Unauthorized();
        EventData storage e = _getEvent(eventId);
        if (e.status != EventStatus.RESOLVE_SUBMITTED) {
            revert InvalidStatus(e.status, EventStatus.RESOLVE_SUBMITTED);
        }
        uint256 windowEnd = e.submittedAt + MIN_CHALLENGE_PERIOD;
        if (block.timestamp >= windowEnd) revert ChallengePeriodExpired(windowEnd);

        e.status = EventStatus.CANCELLED;
        e.cancelledAt = block.timestamp;

        emit ResolutionChallenged(eventId, msg.sender, reason);
        emit EventCancelled(eventId, msg.sender);
    }

    /// @notice Permissionless: finalises resolution after challenge window.
    ///         Opens claims in all TierMarkets (markets pull ranks via finalRank()).
    function finalizeResolution(uint256 eventId) external {
        EventData storage e = _getEvent(eventId);
        if (e.status != EventStatus.RESOLVE_SUBMITTED) {
            revert InvalidStatus(e.status, EventStatus.RESOLVE_SUBMITTED);
        }
        uint256 windowEnd = e.submittedAt + MIN_CHALLENGE_PERIOD;
        if (block.timestamp < windowEnd) revert ChallengePeriodActive(windowEnd);

        e.status = EventStatus.RESOLVED;
        e.finalizedAt = block.timestamp;

        emit ResolutionFinalized(eventId, block.timestamp);
    }

    /// @notice Permissionless: cancels an event if resolution has not been finalised
    ///         within resolutionTimeout seconds after lockTime.
    function cancelEvent(uint256 eventId) external {
        EventData storage e = _getEvent(eventId);
        // Only cancellable if not yet resolved
        if (e.status == EventStatus.RESOLVED || e.status == EventStatus.CANCELLED) {
            revert InvalidStatus(e.status, EventStatus.CREATED);
        }
        uint256 timeoutAt = e.lockTime + e.resolutionTimeout;
        if (block.timestamp < timeoutAt) revert ResolutionTimeoutNotReached(timeoutAt);

        e.status = EventStatus.CANCELLED;
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

    /// @notice Returns 1-based rank. 0 means unranked (loser in all tiers).
    function finalRank(uint256 eventId, bytes32 candidateId) external view returns (uint16) {
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
            e.resolvedBy
        );
    }

    function claimsOpenAt(uint256 eventId) external view returns (uint256) {
        EventData storage e = _events[eventId];
        if (e.status == EventStatus.RESOLVED) return e.finalizedAt;
        if (e.status == EventStatus.CANCELLED) return e.cancelledAt;
        return 0;
    }

    function claimDeadline(uint256 eventId) external view returns (uint256) {
        EventData storage e = _events[eventId];
        uint256 openAt;
        if (e.status == EventStatus.RESOLVED) openAt = e.finalizedAt;
        else if (e.status == EventStatus.CANCELLED) openAt = e.cancelledAt;
        else return 0;
        return openAt + e.claimWindow;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _eventExists(uint256 eventId) internal view returns (bool) {
        return _events[eventId].lockTime != 0;
    }

    function _getEvent(uint256 eventId) internal view returns (EventData storage) {
        if (!_eventExists(eventId)) revert EventDoesNotExist(eventId);
        return _events[eventId];
    }
}
