// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EventRegistry} from "../src/EventRegistry.sol";

contract EventRegistryTest is Test {
    EventRegistry reg;

    address owner    = address(0x1);
    address resolver = address(0x2);
    address gov      = address(0x3);
    address stranger = address(0x4);

    uint256 constant EVENT_ID = 1;
    uint256 constant CLAIM_WINDOW = 30 days;

    // Timing helpers (relative to block.timestamp set in setUp)
    uint256 T0; // test start
    uint256 lockTime;
    uint256 resolveTime;
    uint256 resolutionTimeout;

    bytes32[] candidates;
    bytes32 cA = keccak256("appA");
    bytes32 cB = keccak256("appB");
    bytes32 cC = keccak256("appC");

    function setUp() public {
        T0 = block.timestamp;
        lockTime          = T0 + 7 days;
        resolveTime       = T0 + 7 days + 1 hours;
        resolutionTimeout = 30 days; // >> MIN_RESOLUTION_TIMEOUT (25h)

        candidates.push(cA);
        candidates.push(cB);
        candidates.push(cC);

        vm.prank(owner);
        reg = new EventRegistry(owner, resolver, gov);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _cfg() internal view returns (EventRegistry.EventConfig memory) {
        return EventRegistry.EventConfig({
            eventId:           EVENT_ID,
            lockTime:          lockTime,
            resolveTime:       resolveTime,
            claimWindow:       CLAIM_WINDOW,
            resolutionTimeout: resolutionTimeout,
            candidateIds:      candidates
        });
    }

    function _createEvent() internal {
        vm.prank(owner);
        reg.createEvent(_cfg());
    }

    function _submitResolution() internal {
        vm.warp(resolveTime);
        bytes32[] memory ranked = new bytes32[](2);
        ranked[0] = cA;
        ranked[1] = cB;
        vm.prank(resolver);
        reg.submitResolution(EVENT_ID, ranked, bytes32("snapshot"));
    }

    function _finalizeResolution() internal {
        vm.warp(resolveTime + reg.MIN_CHALLENGE_PERIOD() + 1);
        reg.finalizeResolution(EVENT_ID);
    }

    // -------------------------------------------------------------------------
    // createEvent
    // -------------------------------------------------------------------------

    function test_createEvent_success() public {
        _createEvent();
        assertEq(uint8(reg.getStatus(EVENT_ID)), uint8(EventRegistry.EventStatus.CREATED));
        assertEq(reg.candidates(EVENT_ID).length, 3);
        assertEq(reg.eventCount(), 1);
    }

    function test_createEvent_revert_duplicate() public {
        _createEvent();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EventRegistry.EventAlreadyExists.selector, EVENT_ID));
        reg.createEvent(_cfg());
    }

    function test_createEvent_revert_emptyList() public {
        EventRegistry.EventConfig memory cfg = _cfg();
        cfg.candidateIds = new bytes32[](0);
        vm.prank(owner);
        vm.expectRevert(EventRegistry.EmptyCandidateList.selector);
        reg.createEvent(cfg);
    }

    function test_createEvent_revert_lockTimeInPast() public {
        EventRegistry.EventConfig memory cfg = _cfg();
        cfg.lockTime = T0 - 1;
        vm.prank(owner);
        vm.expectRevert(EventRegistry.LockTimeInPast.selector);
        reg.createEvent(cfg);
    }

    function test_createEvent_revert_resolveBeforeLock() public {
        EventRegistry.EventConfig memory cfg = _cfg();
        cfg.resolveTime = cfg.lockTime - 1;
        vm.prank(owner);
        vm.expectRevert(EventRegistry.ResolveBeforeLock.selector);
        reg.createEvent(cfg);
    }

    function test_createEvent_revert_claimWindowTooShort() public {
        EventRegistry.EventConfig memory cfg = _cfg();
        cfg.claimWindow = 1 days;
        vm.expectRevert(abi.encodeWithSelector(
            EventRegistry.ClaimWindowTooShort.selector,
            1 days,
            reg.MIN_CLAIM_WINDOW()
        ));
        vm.prank(owner);
        reg.createEvent(cfg);
    }

    function test_createEvent_revert_duplicateCandidate() public {
        EventRegistry.EventConfig memory cfg = _cfg();
        cfg.candidateIds = new bytes32[](2);
        cfg.candidateIds[0] = cA;
        cfg.candidateIds[1] = cA; // duplicate
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EventRegistry.DuplicateCandidate.selector, cA));
        reg.createEvent(cfg);
    }

    function test_createEvent_revert_zeroCandidateId() public {
        EventRegistry.EventConfig memory cfg = _cfg();
        cfg.candidateIds = new bytes32[](1);
        cfg.candidateIds[0] = bytes32(0);
        vm.prank(owner);
        vm.expectRevert(EventRegistry.ZeroCandidateId.selector);
        reg.createEvent(cfg);
    }

    function test_createEvent_revert_timeoutTooShortForResolution() public {
        EventRegistry.EventConfig memory cfg = _cfg();
        // resolveTime + MIN_CHALLENGE_PERIOD = T0+7d+1h + 24h = T0+7d+25h
        // lockTime + resolutionTimeout must be > that
        // Set resolutionTimeout so lockTime+timeout <= resolveTime+challengePeriod
        cfg.resolutionTimeout = reg.MIN_RESOLUTION_TIMEOUT(); // just barely passes MIN check
        // lockTime + MIN_RESOLUTION_TIMEOUT = T0+7d+25h
        // resolveTime + MIN_CHALLENGE_PERIOD = T0+7d+1h+24h = T0+7d+25h  => equal, should revert
        vm.prank(owner);
        vm.expectRevert(); // TimeoutTooShortForResolution
        reg.createEvent(cfg);
    }

    // -------------------------------------------------------------------------
    // submitResolution
    // -------------------------------------------------------------------------

    function test_submitResolution_success() public {
        _createEvent();
        _submitResolution();
        assertEq(uint8(reg.getStatus(EVENT_ID)), uint8(EventRegistry.EventStatus.RESOLVE_SUBMITTED));
        assertEq(reg.finalRank(EVENT_ID, cA), 1);
        assertEq(reg.finalRank(EVENT_ID, cB), 2);
        assertEq(reg.finalRank(EVENT_ID, cC), 0); // unranked
    }

    function test_submitResolution_resolutionHash_computed_onchain() public {
        _createEvent();
        vm.warp(resolveTime);
        bytes32[] memory ranked = new bytes32[](2);
        ranked[0] = cA;
        ranked[1] = cB;
        vm.prank(resolver);
        reg.submitResolution(EVENT_ID, ranked, bytes32("any_snapshot"));

        bytes32 expected = keccak256(abi.encodePacked(ranked));
        (,,,,,,,bytes32 storedHash,,) = reg.getEventMeta(EVENT_ID);
        assertEq(storedHash, expected);
    }

    function test_submitResolution_revert_notResolver() public {
        _createEvent();
        vm.warp(resolveTime);
        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = cA;
        vm.prank(stranger);
        vm.expectRevert(EventRegistry.Unauthorized.selector);
        reg.submitResolution(EVENT_ID, ranked, bytes32(0));
    }

    function test_submitResolution_revert_tooEarly() public {
        _createEvent();
        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = cA;
        vm.prank(resolver);
        vm.expectRevert(); // TooEarlyToResolve
        reg.submitResolution(EVENT_ID, ranked, bytes32(0));
    }

    function test_submitResolution_revert_emptyList() public {
        _createEvent();
        vm.warp(resolveTime);
        bytes32[] memory ranked = new bytes32[](0);
        vm.prank(resolver);
        vm.expectRevert(EventRegistry.EmptyRankedList.selector);
        reg.submitResolution(EVENT_ID, ranked, bytes32(0));
    }

    function test_submitResolution_revert_duplicateRanked() public {
        _createEvent();
        vm.warp(resolveTime);
        bytes32[] memory ranked = new bytes32[](2);
        ranked[0] = cA;
        ranked[1] = cA; // duplicate
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(EventRegistry.DuplicateCandidate.selector, cA));
        reg.submitResolution(EVENT_ID, ranked, bytes32(0));
    }

    function test_submitResolution_revert_nonCandidate() public {
        _createEvent();
        vm.warp(resolveTime);
        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = keccak256("unknown");
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(EventRegistry.NotACandidate.selector, ranked[0]));
        reg.submitResolution(EVENT_ID, ranked, bytes32(0));
    }

    function test_submitResolution_revert_tooManyRanks() public {
        _createEvent();
        vm.warp(resolveTime);
        // 4 ranks for 3 candidates
        bytes32[] memory ranked = new bytes32[](4);
        ranked[0] = cA; ranked[1] = cB; ranked[2] = cC; ranked[3] = keccak256("x");
        vm.prank(resolver);
        vm.expectRevert(); // TooManyRanks
        reg.submitResolution(EVENT_ID, ranked, bytes32(0));
    }

    // -------------------------------------------------------------------------
    // challengeResolution
    // -------------------------------------------------------------------------

    function test_challengeResolution_success() public {
        _createEvent();
        _submitResolution();
        vm.prank(gov);
        reg.challengeResolution(EVENT_ID, "bad data");
        assertEq(uint8(reg.getStatus(EVENT_ID)), uint8(EventRegistry.EventStatus.CANCELLED));
        assertTrue(reg.isCancelled(EVENT_ID));
    }

    function test_challengeResolution_revert_afterWindow() public {
        _createEvent();
        _submitResolution();
        vm.warp(resolveTime + reg.MIN_CHALLENGE_PERIOD() + 1);
        vm.prank(gov);
        vm.expectRevert(); // ChallengePeriodExpired
        reg.challengeResolution(EVENT_ID, "too late");
    }

    function test_challengeResolution_revert_notGovernance() public {
        _createEvent();
        _submitResolution();
        vm.prank(stranger);
        vm.expectRevert(EventRegistry.Unauthorized.selector);
        reg.challengeResolution(EVENT_ID, "...");
    }

    // -------------------------------------------------------------------------
    // finalizeResolution
    // -------------------------------------------------------------------------

    function test_finalizeResolution_success() public {
        _createEvent();
        _submitResolution();
        _finalizeResolution();
        assertTrue(reg.isResolved(EVENT_ID));
        assertEq(reg.resolvedFinalRank(EVENT_ID, cA), 1);
    }

    function test_finalizeResolution_revert_duringChallengeWindow() public {
        _createEvent();
        _submitResolution();
        // Still inside window
        vm.warp(resolveTime + reg.MIN_CHALLENGE_PERIOD() - 1);
        vm.expectRevert(); // ChallengePeriodActive
        reg.finalizeResolution(EVENT_ID);
    }

    function test_finalizeResolution_revert_afterChallenge() public {
        _createEvent();
        _submitResolution();
        vm.prank(gov);
        reg.challengeResolution(EVENT_ID, "veto");
        // Status is now CANCELLED
        vm.warp(resolveTime + reg.MIN_CHALLENGE_PERIOD() + 1);
        vm.expectRevert(); // InvalidStatus
        reg.finalizeResolution(EVENT_ID);
    }

    // -------------------------------------------------------------------------
    // cancelEvent
    // -------------------------------------------------------------------------

    function test_cancelEvent_success_afterTimeout() public {
        _createEvent();
        vm.warp(lockTime + resolutionTimeout + 1);
        reg.cancelEvent(EVENT_ID);
        assertTrue(reg.isCancelled(EVENT_ID));
    }

    function test_cancelEvent_revert_duringTimeout() public {
        _createEvent();
        vm.warp(lockTime + resolutionTimeout - 1);
        vm.expectRevert(); // ResolutionTimeoutNotReached
        reg.cancelEvent(EVENT_ID);
    }

    function test_cancelEvent_revert_whileResolveSubmitted() public {
        _createEvent();
        _submitResolution();
        // Even if timeout has passed, RESOLVE_SUBMITTED blocks cancel
        vm.warp(lockTime + resolutionTimeout + 1);
        vm.expectRevert(EventRegistry.ResolutionInProgress.selector);
        reg.cancelEvent(EVENT_ID);
    }

    function test_cancelEvent_revert_alreadyResolved() public {
        _createEvent();
        _submitResolution();
        _finalizeResolution();
        vm.expectRevert(); // EventAlreadyTerminal
        reg.cancelEvent(EVENT_ID);
    }

    function test_cancelEvent_revert_alreadyCancelled() public {
        _createEvent();
        vm.warp(lockTime + resolutionTimeout + 1);
        reg.cancelEvent(EVENT_ID);
        vm.expectRevert(); // EventAlreadyTerminal
        reg.cancelEvent(EVENT_ID);
    }

    // -------------------------------------------------------------------------
    // Resolver/governance snapshots
    // -------------------------------------------------------------------------

    function test_globalResolverChange_doesNotAffectLiveEvent() public {
        _createEvent();

        // Owner swaps resolver globally
        vm.prank(owner);
        reg.setResolver(address(0x99));

        // Old resolver (snapshotted at creation) still works for this event
        vm.warp(resolveTime);
        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = cA;
        vm.prank(resolver); // original resolver
        reg.submitResolution(EVENT_ID, ranked, bytes32(0));
        assertEq(uint8(reg.getStatus(EVENT_ID)), uint8(EventRegistry.EventStatus.RESOLVE_SUBMITTED));
    }

    function test_globalGovernanceChange_doesNotAffectLiveEvent() public {
        _createEvent();
        _submitResolution();

        // Owner swaps governance globally
        vm.prank(owner);
        reg.setGovernance(address(0x99));

        // Old governance (snapshotted at creation) still works for this event
        vm.prank(gov); // original governance
        reg.challengeResolution(EVENT_ID, "veto");
        assertTrue(reg.isCancelled(EVENT_ID));
    }

    // -------------------------------------------------------------------------
    // Claim timing views
    // -------------------------------------------------------------------------

    function test_claimsOpenAt_resolved() public {
        _createEvent();
        _submitResolution();
        uint256 warpTo = resolveTime + reg.MIN_CHALLENGE_PERIOD() + 1;
        vm.warp(warpTo);
        reg.finalizeResolution(EVENT_ID);
        assertEq(reg.claimsOpenAt(EVENT_ID), warpTo);
    }

    function test_claimsOpenAt_cancelled() public {
        _createEvent();
        uint256 cancelAt = lockTime + resolutionTimeout + 1;
        vm.warp(cancelAt);
        reg.cancelEvent(EVENT_ID);
        assertEq(reg.claimsOpenAt(EVENT_ID), cancelAt);
    }

    function test_claimDeadline_resolved() public {
        _createEvent();
        _submitResolution();
        uint256 warpTo = resolveTime + reg.MIN_CHALLENGE_PERIOD() + 1;
        vm.warp(warpTo);
        reg.finalizeResolution(EVENT_ID);
        assertEq(reg.claimDeadline(EVENT_ID), warpTo + CLAIM_WINDOW);
    }

    // -------------------------------------------------------------------------
    // resolvedFinalRank guarded view
    // -------------------------------------------------------------------------

    function test_resolvedFinalRank_revert_notResolved() public {
        _createEvent();
        vm.expectRevert(); // InvalidStatus
        reg.resolvedFinalRank(EVENT_ID, cA);
    }

    function test_resolvedFinalRank_success_afterResolve() public {
        _createEvent();
        _submitResolution();
        _finalizeResolution();
        assertEq(reg.resolvedFinalRank(EVENT_ID, cA), 1);
        assertEq(reg.resolvedFinalRank(EVENT_ID, cC), 0); // unranked
    }

    // -------------------------------------------------------------------------
    // getEventTiming
    // -------------------------------------------------------------------------

    function test_getEventTiming() public {
        _createEvent();
        (
            uint256 lt,
            uint256 rt,
            uint256 timeout,
            uint256 cw,
            address evResolver,
            address evGov
        ) = reg.getEventTiming(EVENT_ID);
        assertEq(lt,         lockTime);
        assertEq(rt,         resolveTime);
        assertEq(timeout,    resolutionTimeout);
        assertEq(cw,         CLAIM_WINDOW);
        assertEq(evResolver, resolver);
        assertEq(evGov,      gov);
    }

    // -------------------------------------------------------------------------
    // Access control
    // -------------------------------------------------------------------------

    function test_createEvent_revert_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        reg.createEvent(_cfg());
    }

    function test_setResolver_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(EventRegistry.ZeroAddress.selector);
        reg.setResolver(address(0));
    }

    function test_setGovernance_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(EventRegistry.ZeroAddress.selector);
        reg.setGovernance(address(0));
    }

    function test_setDenylist_success() public {
        vm.prank(owner);
        reg.setDenylist(resolver, true);
        assertTrue(reg.denylist(resolver));
        vm.prank(owner);
        reg.setDenylist(resolver, false);
        assertFalse(reg.denylist(resolver));
    }

    function test_setDenylist_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(EventRegistry.ZeroAddress.selector);
        reg.setDenylist(address(0), true);
    }

    // -------------------------------------------------------------------------
    // G-1: Inverse snapshot — new role holders cannot act on old events
    // -------------------------------------------------------------------------

    function test_newResolver_cannotSubmitForSnapshotEvent() public {
        _createEvent();
        vm.prank(owner);
        reg.setResolver(address(0x99));

        vm.warp(resolveTime);
        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = cA;
        vm.prank(address(0x99)); // new global resolver — should be rejected
        vm.expectRevert(EventRegistry.Unauthorized.selector);
        reg.submitResolution(EVENT_ID, ranked, bytes32(0));
    }

    function test_newGovernance_cannotChallengeSnapshotEvent() public {
        _createEvent();
        _submitResolution();
        vm.prank(owner);
        reg.setGovernance(address(0x99));

        vm.prank(address(0x99)); // new global governance — should be rejected
        vm.expectRevert(EventRegistry.Unauthorized.selector);
        reg.challengeResolution(EVENT_ID, "veto");
    }

    // -------------------------------------------------------------------------
    // G-2: Double-submit reverts (state transition is one-way)
    // -------------------------------------------------------------------------

    function test_submitResolution_revert_alreadySubmitted() public {
        _createEvent();
        _submitResolution();

        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = cC;
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(
            EventRegistry.InvalidStatus.selector,
            EventRegistry.EventStatus.RESOLVE_SUBMITTED,
            EventRegistry.EventStatus.CREATED
        ));
        reg.submitResolution(EVENT_ID, ranked, bytes32(0));
    }

    // -------------------------------------------------------------------------
    // G-3: claimDeadline for CANCELLED events
    // -------------------------------------------------------------------------

    function test_claimDeadline_cancelled() public {
        _createEvent();
        uint256 cancelAt = lockTime + resolutionTimeout + 1;
        vm.warp(cancelAt);
        reg.cancelEvent(EVENT_ID);
        assertEq(reg.claimDeadline(EVENT_ID), cancelAt + CLAIM_WINDOW);
    }

    // -------------------------------------------------------------------------
    // G-4: snapshotHash is persisted separately from computed resolutionHash
    // -------------------------------------------------------------------------

    function test_submitResolution_snapshotHash_stored() public {
        _createEvent();
        vm.warp(resolveTime);
        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = cA;
        bytes32 snapshot = bytes32("my_snapshot");
        vm.prank(resolver);
        reg.submitResolution(EVENT_ID, ranked, snapshot);

        (,,,,,,,, bytes32 storedSnapshot,) = reg.getEventMeta(EVENT_ID);
        assertEq(storedSnapshot, snapshot);

        // Also verify resolutionHash is the on-chain computed value, not snapshotHash
        bytes32 expectedResolutionHash = keccak256(abi.encodePacked(ranked));
        (,,,,,,, bytes32 storedResolutionHash,,) = reg.getEventMeta(EVENT_ID);
        assertEq(storedResolutionHash, expectedResolutionHash);
        assertTrue(storedResolutionHash != snapshot); // they must differ
    }
}
