// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {EventRegistry} from "../src/EventRegistry.sol";
import {TierMarket} from "../src/TierMarket.sol";
import {BatchClaimer} from "../src/BatchClaimer.sol";

// ─────────────────────────────────────────────
// Minimal USDC stand-in (6 decimals, no permit)
// ─────────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

// ─────────────────────────────────────────────
// Integration test suite
// ─────────────────────────────────────────────

contract IntegrationTest is Test {
    // Protocol contracts
    EventRegistry  reg;
    TierMarket     market;
    BatchClaimer   batcher;
    MockUSDC       usdc;

    // Roles
    address owner    = address(0x1);
    address resolver = address(0x2);
    address gov      = address(0x3);
    address feeDest  = address(0xFEE);

    // Users
    address alice = address(0xA);
    address bob   = address(0xB);
    address carol = address(0xC);

    // Candidates
    bytes32 cA = keccak256("appA");
    bytes32 cB = keccak256("appB");
    bytes32 cC = keccak256("appC");

    // Timing
    uint256 T0;
    uint256 lockTime;
    uint256 resolveTime;
    uint256 resolutionTimeout;
    uint256 claimWindow;

    uint256 constant EVENT_ID     = 42;
    uint256 constant MIN_STAKE    = 1e6;
    uint256 constant MAX_STAKE    = 10_000e6;
    uint16  constant FEE_BPS      = 200;   // 2%
    uint16  constant TIER         = 10;    // Top10

    // ─────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────

    function setUp() public {
        T0                = block.timestamp;
        lockTime          = T0 + 7 days;
        resolveTime       = T0 + 7 days + 2 hours; // after lockTime
        resolutionTimeout = 30 days;               // >> MIN_RESOLUTION_TIMEOUT
        claimWindow       = 30 days;               // == MIN_CLAIM_WINDOW

        // Deploy infrastructure
        usdc    = new MockUSDC();
        batcher = new BatchClaimer();

        vm.prank(owner);
        reg = new EventRegistry(owner, resolver, gov);

        // Create event with 3 candidates
        bytes32[] memory cands = new bytes32[](3);
        cands[0] = cA; cands[1] = cB; cands[2] = cC;

        EventRegistry.EventConfig memory cfg = EventRegistry.EventConfig({
            eventId:           EVENT_ID,
            lockTime:          lockTime,
            resolveTime:       resolveTime,
            claimWindow:       claimWindow,
            resolutionTimeout: resolutionTimeout,
            candidateIds:      cands
        });

        vm.prank(owner);
        reg.createEvent(cfg);

        // Deploy TierMarket wired to real EventRegistry
        vm.prank(owner);
        market = new TierMarket(
            owner,
            address(usdc),
            address(reg),
            EVENT_ID,
            TIER,
            FEE_BPS,
            feeDest,
            lockTime,
            MIN_STAKE,
            MAX_STAKE
        );

        // Fund + approve users
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob,   10_000e6);
        usdc.mint(carol, 10_000e6);

        vm.prank(alice); usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(market), type(uint256).max);
        vm.prank(carol); usdc.approve(address(market), type(uint256).max);
    }

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────

    function _stake() internal {
        vm.prank(alice); market.predict(cA, 100e6);
        vm.prank(bob);   market.predict(cB, 80e6);
        vm.prank(carol); market.predict(cC, 20e6);
    }

    function _lockMarket() internal {
        vm.warp(lockTime);
        market.lock();
    }

    function _submitAndFinalizeResolution(bytes32[] memory ranked) internal {
        vm.warp(resolveTime);
        vm.prank(resolver);
        reg.submitResolution(EVENT_ID, ranked, bytes32("snapshot"));

        vm.warp(resolveTime + reg.MIN_CHALLENGE_PERIOD() + 1);
        reg.finalizeResolution(EVENT_ID);
    }

    function _resolveMarket() internal {
        market.resolve();
    }

    function _claimDeadline() internal view returns (uint256) {
        return reg.claimDeadline(EVENT_ID);
    }

    // ─────────────────────────────────────────────
    // 1. Full happy path: stake → resolve → BatchClaimer claimFor → funds at user
    // ─────────────────────────────────────────────

    function test_integration_fullHappyPath() public {
        _stake();
        _lockMarket();

        // cA ranks #1, cB ranks #2 → both win Top10; cC unranked → loses
        bytes32[] memory ranked = new bytes32[](2);
        ranked[0] = cA; ranked[1] = cB;
        _submitAndFinalizeResolution(ranked);
        _resolveMarket();

        // Verify accounting
        assertEq(market.totalStaked(), 200e6);
        assertEq(market.feeAmount(),    4e6);    // 2% of 200
        assertEq(market.netPool(),     196e6);
        assertEq(market.winningStake(),180e6);   // cA+cB

        // BatchClaimer claims for alice and bob
        address[] memory markets = new address[](1);
        markets[0] = address(market);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        batcher.claimMany(markets);
        uint256 alicePayout = usdc.balanceOf(alice) - aliceBefore;

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        batcher.claimMany(markets);
        uint256 bobPayout = usdc.balanceOf(bob) - bobBefore;

        // Funds arrived at users, not BatchClaimer
        assertEq(usdc.balanceOf(address(batcher)), 0);
        assertGt(alicePayout, 0);
        assertGt(bobPayout, 0);

        // carol staked on loser — nothing to claim
        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        batcher.claimMany(markets); // emits ClaimFailed silently
        assertEq(usdc.balanceOf(carol), carolBefore); // no change

        // Payout math: alice 100*196/180 = 108.888..., bob 80*196/180 = 87.111...
        uint256 expectedAlice = (uint256(100e6) * market.netPool()) / market.winningStake();
        uint256 expectedBob   = (uint256(80e6)  * market.netPool()) / market.winningStake();
        assertEq(alicePayout, expectedAlice);
        assertEq(bobPayout,   expectedBob);
    }

    // ─────────────────────────────────────────────
    // 2. Cancelled event → market cancel → BatchClaimer refund
    // ─────────────────────────────────────────────

    function test_integration_cancelledEvent_batchRefund() public {
        _stake(); // alice 100, bob 80, carol 20

        // Governance cancels after resolution submitted
        vm.warp(resolveTime);
        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = cA;
        vm.prank(resolver);
        reg.submitResolution(EVENT_ID, ranked, bytes32("snapshot"));

        vm.prank(gov);
        reg.challengeResolution(EVENT_ID, "bad data");

        assertTrue(reg.isCancelled(EVENT_ID));

        // Anyone can cancel the TierMarket
        market.cancelMarket();
        assertEq(uint8(market.status()), uint8(TierMarket.MarketStatus.CANCELLED));
        assertTrue(market.noWinner());
        assertEq(market.feeAmount(), 0);

        address[] memory markets = new address[](1);
        markets[0] = address(market);

        // All users get full refund via BatchClaimer
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        batcher.claimMany(markets);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        batcher.claimMany(markets);
        assertEq(usdc.balanceOf(bob) - bobBefore, 80e6);

        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        batcher.claimMany(markets);
        assertEq(usdc.balanceOf(carol) - carolBefore, 20e6);

        // BatchClaimer holds nothing
        assertEq(usdc.balanceOf(address(batcher)), 0);
    }

    // ─────────────────────────────────────────────
    // 3. Claim after deadline fails through BatchClaimer path
    // ─────────────────────────────────────────────

    function test_integration_claimAfterDeadline_batchFails() public {
        _stake();
        _lockMarket();

        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = cA;
        _submitAndFinalizeResolution(ranked);
        _resolveMarket();

        // Warp past claim deadline
        vm.warp(_claimDeadline() + 1);

        address[] memory markets = new address[](1);
        markets[0] = address(market);

        // BatchClaimer should emit ClaimFailed, not revert
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        batcher.claimMany(markets); // best-effort: captures the ClaimDeadlinePassed revert

        // Alice received nothing (deadline passed)
        assertEq(usdc.balanceOf(alice), aliceBefore);
    }

    // ─────────────────────────────────────────────
    // 4. Finalize after deadline sweeps remaining funds
    // ─────────────────────────────────────────────

    function test_integration_finalize_sweepsRemaining() public {
        _stake();
        _lockMarket();

        bytes32[] memory ranked = new bytes32[](2);
        ranked[0] = cA; ranked[1] = cB;
        _submitAndFinalizeResolution(ranked);
        _resolveMarket();

        // Only alice claims; bob and carol don't
        address[] memory markets = new address[](1);
        markets[0] = address(market);
        vm.prank(alice);
        batcher.claimMany(markets);

        // Fast-forward past claim deadline
        vm.warp(_claimDeadline() + 1);

        uint256 feeBefore = usdc.balanceOf(feeDest);
        vm.prank(owner);
        market.finalizeMarket();

        assertTrue(market.finalized());
        assertEq(usdc.balanceOf(address(market)), 0); // market drained
        assertGt(usdc.balanceOf(feeDest) - feeBefore, 0); // feeDest received remainder

        // Total distributed = alice's claim + finalize sweep = totalStaked
        uint256 alicePayout = (100e6 * market.netPool()) / market.winningStake();
        assertApproxEqAbs(
            alicePayout + (usdc.balanceOf(feeDest) - feeBefore),
            200e6,
            2  // dust tolerance
        );
    }

    // ─────────────────────────────────────────────
    // 5. Multi-market batch: 2 markets, partial success
    // ─────────────────────────────────────────────

    function test_integration_multiMarket_partialBatch() public {
        // Deploy a second market (Top5) for same event
        vm.prank(owner);
        TierMarket market2 = new TierMarket(
            owner,
            address(usdc),
            address(reg),
            EVENT_ID,
            5, // Top5
            FEE_BPS,
            feeDest,
            lockTime,
            MIN_STAKE,
            MAX_STAKE
        );

        vm.prank(alice); usdc.approve(address(market2), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(market2), type(uint256).max);

        // Stake in both markets
        vm.prank(alice); market.predict(cA,  100e6);
        vm.prank(alice); market2.predict(cA, 50e6);
        vm.prank(bob);   market.predict(cB,  80e6);
        vm.prank(bob);   market2.predict(cC, 60e6); // cC will rank 6 → loses in Top5

        _lockMarket();
        vm.warp(lockTime); market2.lock();

        // cA=rank1, cB=rank2, cC=UNRANKED (rank 0)
        // → alice wins Top10 (cA ≤10) and Top5 (cA ≤5)
        // → bob wins Top10 (cB rank2 ≤10) but LOSES Top5 (cC unranked)
        bytes32[] memory ranked = new bytes32[](2);
        ranked[0] = cA; ranked[1] = cB; // cC intentionally omitted → rank 0
        _submitAndFinalizeResolution(ranked);

        market.resolve();
        market2.resolve();

        address[] memory markets = new address[](2);
        markets[0] = address(market);
        markets[1] = address(market2);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        batcher.claimMany(markets); // both succeed (cA wins Top10 and Top5)
        assertGt(usdc.balanceOf(alice) - aliceBefore, 0);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        batcher.claimMany(markets); // market succeeds (cB rank2 ≤10), market2 emits ClaimFailed (cC unranked)

        uint256 bobPayout = usdc.balanceOf(bob) - bobBefore;
        // bob only gets market1 payout — market2 was a ClaimFailed (best-effort, no revert)
        uint256 expectedFromMarket1 = (uint256(80e6) * market.netPool()) / market.winningStake();
        assertEq(bobPayout, expectedFromMarket1);
        // Confirm bob got nothing from market2 (cC unranked → NothingToClaim → ClaimFailed)
        assertEq(market2.claimable(bob), 0);
    }

    // ─────────────────────────────────────────────
    // 6. No-winner full refund through BatchClaimer
    // ─────────────────────────────────────────────

    function test_integration_noWinner_batchRefund() public {
        // Deploy a Top1 market BEFORE warping (lockTime must be in the future)
        vm.prank(owner);
        TierMarket top1Market = new TierMarket(
            owner,
            address(usdc),
            address(reg),
            EVENT_ID,
            1, // Top1 — only rank==1 wins
            FEE_BPS,
            feeDest,
            lockTime,
            MIN_STAKE,
            MAX_STAKE
        );
        vm.prank(alice); usdc.approve(address(top1Market), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(top1Market), type(uint256).max);
        vm.prank(carol); usdc.approve(address(top1Market), type(uint256).max);

        // Stake: nobody picks cA (the eventual #1)
        vm.prank(alice); top1Market.predict(cB, 100e6);
        vm.prank(bob);   top1Market.predict(cC, 80e6);

        vm.warp(lockTime); top1Market.lock();

        // cA ranks #1 but nobody staked on it → winningStake == 0 → no-winner
        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = cA; // rank 1 = cA
        _submitAndFinalizeResolution(ranked);

        top1Market.resolve();
        assertTrue(top1Market.noWinner());
        assertEq(top1Market.feeAmount(), 0);

        address[] memory markets = new address[](1);
        markets[0] = address(top1Market);

        // Full refunds via BatchClaimer
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        batcher.claimMany(markets);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        batcher.claimMany(markets);
        assertEq(usdc.balanceOf(bob) - bobBefore, 80e6);

        assertEq(usdc.balanceOf(address(batcher)), 0);
    }

    // ─────────────────────────────────────────────
    // 7. denylist enforcement end-to-end
    // ─────────────────────────────────────────────

    function test_integration_denylist_blocksStaking() public {
        // Owner adds resolver to denylist
        vm.prank(owner);
        reg.setDenylist(resolver, true);

        // Resolver tries to stake
        usdc.mint(resolver, 1000e6);
        vm.prank(resolver);
        usdc.approve(address(market), type(uint256).max);

        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(TierMarket.DeniedAddress.selector, resolver));
        market.predict(cA, 100e6);
    }

    // ─────────────────────────────────────────────
    // 8. previewMany with real TierMarket
    // ─────────────────────────────────────────────

    function test_integration_previewMany_realMarket() public {
        _stake();
        _lockMarket();

        bytes32[] memory ranked = new bytes32[](2);
        ranked[0] = cA; ranked[1] = cB;
        _submitAndFinalizeResolution(ranked);
        _resolveMarket();

        address[] memory markets = new address[](1);
        markets[0] = address(market);

        // previewMany returns correct claimable for alice
        uint256[] memory amounts = batcher.previewMany(markets, alice);
        uint256 expected = (100e6 * market.netPool()) / market.winningStake();
        assertEq(amounts[0], expected);

        // carol staked on loser → 0
        uint256[] memory carolAmounts = batcher.previewMany(markets, carol);
        assertEq(carolAmounts[0], 0);
    }

    // ─────────────────────────────────────────────
    // 10. G-1: Resolution timeout → cancelEvent → cancelMarket → refunds via BatchClaimer
    // ─────────────────────────────────────────────

    function test_integration_timeoutCancel_batchRefund() public {
        _stake(); // alice 100, bob 80, carol 20

        // Nobody submits a resolution — skip past resolutionTimeout
        // resolutionTimeout = 30 days; resolveTime = lockTime + 2h
        vm.warp(resolveTime + resolutionTimeout + 1);
        reg.cancelEvent(EVENT_ID);
        assertTrue(reg.isCancelled(EVENT_ID));

        market.cancelMarket();
        assertEq(uint8(market.status()), uint8(TierMarket.MarketStatus.CANCELLED));
        assertTrue(market.noWinner());
        assertEq(market.feeAmount(), 0);

        address[] memory markets = new address[](1);
        markets[0] = address(market);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        batcher.claimMany(markets);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        batcher.claimMany(markets);
        assertEq(usdc.balanceOf(bob) - bobBefore, 80e6);

        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        batcher.claimMany(markets);
        assertEq(usdc.balanceOf(carol) - carolBefore, 20e6);

        assertEq(usdc.balanceOf(address(batcher)), 0);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    // ─────────────────────────────────────────────
    // 11. G-2: Auto-lock path — resolve() called without prior lock()
    // ─────────────────────────────────────────────

    function test_integration_autoLock_resolve() public {
        _stake();
        // Do NOT call lock() — let resolve() auto-lock

        bytes32[] memory ranked = new bytes32[](2);
        ranked[0] = cA; ranked[1] = cB;
        _submitAndFinalizeResolution(ranked);

        // resolve() should auto-lock before resolving
        assertEq(uint8(market.status()), uint8(TierMarket.MarketStatus.OPEN));
        market.resolve(); // triggers auto-lock then resolution
        assertEq(uint8(market.status()), uint8(TierMarket.MarketStatus.RESOLVED));

        // Claims work normally after auto-lock resolve
        address[] memory markets = new address[](1);
        markets[0] = address(market);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        batcher.claimMany(markets);
        assertGt(usdc.balanceOf(alice) - aliceBefore, 0);
    }

    // ─────────────────────────────────────────────
    // 9. Balance conservation end-to-end
    // ─────────────────────────────────────────────

    function test_integration_balance_conservation() public {
        _stake();
        _lockMarket();

        bytes32[] memory ranked = new bytes32[](2);
        ranked[0] = cA; ranked[1] = cB;
        _submitAndFinalizeResolution(ranked);
        _resolveMarket();

        address[] memory markets = new address[](1);
        markets[0] = address(market);

        vm.prank(alice); batcher.claimMany(markets);
        vm.prank(bob);   batcher.claimMany(markets);
        // carol can't claim (loser), skip

        vm.warp(_claimDeadline() + 1);
        uint256 feeBefore = usdc.balanceOf(feeDest);
        vm.prank(owner);
        market.finalizeMarket();

        // totalStaked == totalClaimed + swept to feeDest ± dust
        assertApproxEqAbs(
            market.totalClaimed() + (usdc.balanceOf(feeDest) - feeBefore),
            market.totalStaked(),
            2 // dust tolerance
        );
        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(usdc.balanceOf(address(batcher)), 0);
    }
}
