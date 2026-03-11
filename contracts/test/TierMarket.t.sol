// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {TierMarket} from "../src/TierMarket.sol";

// ─────────────────────────────────────────────
// Mock helpers
// ─────────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract MockRegistry {
    bool public _resolved;
    bool public _cancelled;
    mapping(bytes32 => uint16) public ranks;
    mapping(address => bool)   public denylist;
    bytes32[] public cands;
    uint256 public _claimDeadline;

    function setResolved(bool v) external { _resolved = v; }
    function setCancelled(bool v) external { _cancelled = v; }
    function setRank(bytes32 cId, uint16 rank) external { ranks[cId] = rank; }
    function setDenylist(address a, bool v) external { denylist[a] = v; }
    function setCandidates(bytes32[] calldata c) external { cands = c; }
    function setClaimDeadline(uint256 d) external { _claimDeadline = d; }

    function isResolved(uint256) external view returns (bool)  { return _resolved; }
    function isCancelled(uint256) external view returns (bool) { return _cancelled; }
    function resolvedFinalRank(uint256, bytes32 cId) external view returns (uint16) { return ranks[cId]; }
    function claimDeadline(uint256) external view returns (uint256) { return _claimDeadline; }
    function candidates(uint256) external view returns (bytes32[] memory) { return cands; }
}

// ─────────────────────────────────────────────
// Test suite
// ─────────────────────────────────────────────

contract TierMarketTest is Test {
    MockUSDC    usdc;
    MockRegistry reg;
    TierMarket  market;

    address owner     = address(0x1);
    address alice     = address(0xA);
    address bob       = address(0xB);
    address carol     = address(0xC);
    address resolver  = address(0x2);
    address feeDest   = address(0xFEE);

    bytes32 cA = keccak256("appA");
    bytes32 cB = keccak256("appB");
    bytes32 cC = keccak256("appC");

    uint256 constant MIN_STAKE  = 1e6;   // 1 USDC
    uint256 constant MAX_STAKE  = 1000e6; // 1000 USDC per user per candidate
    uint16  constant TIER       = 10;
    uint16  constant FEE_BPS    = 200;   // 2%

    uint256 T0;
    uint256 lockTime;
    uint256 claimDeadline;

    function setUp() public {
        T0        = block.timestamp;
        lockTime  = T0 + 7 days;
        claimDeadline = T0 + 7 days + 60 days; // after lock + claim window

        usdc = new MockUSDC();
        reg  = new MockRegistry();

        bytes32[] memory cands = new bytes32[](3);
        cands[0] = cA; cands[1] = cB; cands[2] = cC;
        reg.setCandidates(cands);
        reg.setClaimDeadline(claimDeadline);

        vm.prank(owner);
        market = new TierMarket(
            owner,
            address(usdc),
            address(reg),
            1,          // eventId
            TIER,       // tierThreshold = 10
            FEE_BPS,    // feeBps = 2%
            feeDest,
            lockTime,
            MIN_STAKE,
            MAX_STAKE
        );

        // Fund users
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob,   10_000e6);
        usdc.mint(carol, 10_000e6);

        vm.prank(alice); usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(market), type(uint256).max);
        vm.prank(carol); usdc.approve(address(market), type(uint256).max);
    }

    // ─────────────────────────────────────────────
    // Constructor validation
    // ─────────────────────────────────────────────

    function test_constructor_revert_invalidTierThreshold() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TierMarket.InvalidTierThreshold.selector, uint16(7)));
        new TierMarket(owner, address(usdc), address(reg), 1, 7, FEE_BPS, feeDest, lockTime, MIN_STAKE, MAX_STAKE);
    }

    function test_constructor_revert_zeroTierThreshold() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TierMarket.InvalidTierThreshold.selector, uint16(0)));
        new TierMarket(owner, address(usdc), address(reg), 1, 0, FEE_BPS, feeDest, lockTime, MIN_STAKE, MAX_STAKE);
    }

    function test_constructor_revert_emptyCandidateSet() public {
        MockRegistry emptyReg = new MockRegistry();
        // no candidates set → empty array
        vm.prank(owner);
        vm.expectRevert(TierMarket.EmptyCandidateSet.selector);
        new TierMarket(owner, address(usdc), address(emptyReg), 1, TIER, FEE_BPS, feeDest, lockTime, MIN_STAKE, MAX_STAKE);
    }

    function test_constructor_revert_zeroMinStake() public {
        vm.prank(owner);
        vm.expectRevert(TierMarket.ZeroMinStake.selector);
        new TierMarket(owner, address(usdc), address(reg), 1, TIER, FEE_BPS, feeDest, lockTime, 0, MAX_STAKE);
    }

    function test_constructor_validTierThresholds() public {
        // 1, 5, 10 must all succeed
        for (uint16 t = 0; t < 3; t++) {
            uint16[3] memory valid = [uint16(1), uint16(5), uint16(10)];
            new TierMarket(owner, address(usdc), address(reg), 1, valid[t], FEE_BPS, feeDest, lockTime, MIN_STAKE, MAX_STAKE);
        }
    }

    // ─────────────────────────────────────────────
    // predict()
    // ─────────────────────────────────────────────

    function test_predict_success() public {
        vm.prank(alice);
        market.predict(cA, 100e6);
        assertEq(market.candidateStake(cA), 100e6);
        assertEq(market.userCandidateStake(alice, cA), 100e6);
        assertEq(market.totalStaked(), 100e6);
    }

    function test_predict_revert_notACandidate() public {
        bytes32 unknown = keccak256("ghost");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TierMarket.NotACandidate.selector, unknown));
        market.predict(unknown, 100e6);
    }

    function test_predict_revert_belowMinStake() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TierMarket.BelowMinStake.selector, MIN_STAKE - 1, MIN_STAKE));
        market.predict(cA, MIN_STAKE - 1);
    }

    function test_predict_revert_maxStakeExceeded() public {
        vm.prank(alice);
        vm.expectRevert(); // MaxStakeExceeded
        market.predict(cA, MAX_STAKE + 1);
    }

    function test_predict_revert_deniedAddress() public {
        reg.setDenylist(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TierMarket.DeniedAddress.selector, alice));
        market.predict(cA, 100e6);
    }

    function test_predict_revert_afterLockTime() public {
        vm.warp(lockTime);
        vm.prank(alice);
        vm.expectRevert(TierMarket.StakingWindowClosed.selector);
        market.predict(cA, 100e6);
    }

    function test_predict_revert_registryCancelled() public {
        reg.setCancelled(true);
        vm.prank(alice);
        vm.expectRevert(TierMarket.EventCancelled.selector);
        market.predict(cA, 100e6);
    }

    function test_predict_revert_afterLock() public {
        vm.warp(lockTime);
        market.lock();
        vm.prank(alice);
        vm.expectRevert(TierMarket.NotOpen.selector);
        market.predict(cA, 100e6);
    }

    // ─────────────────────────────────────────────
    // lock()
    // ─────────────────────────────────────────────

    function test_lock_permissionless_afterLockTime() public {
        vm.warp(lockTime);
        market.lock();
        assertEq(uint8(market.status()), uint8(TierMarket.MarketStatus.LOCKED));
    }

    function test_lock_owner_early() public {
        vm.prank(owner);
        market.lock();
        assertEq(uint8(market.status()), uint8(TierMarket.MarketStatus.LOCKED));
    }

    function test_lock_revert_tooEarlyNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TierMarket.TooEarlyToLock.selector, lockTime, block.timestamp));
        market.lock();
    }

    function test_lock_revert_alreadyLocked() public {
        vm.warp(lockTime);
        market.lock();
        vm.expectRevert(TierMarket.NotOpen.selector);
        market.lock();
    }

    // ─────────────────────────────────────────────
    // resolve() — normal winner/loser payout
    // ─────────────────────────────────────────────

    function _stakeAndLock() internal {
        vm.prank(alice); market.predict(cA, 100e6);
        vm.prank(bob);   market.predict(cB, 80e6);
        vm.prank(carol); market.predict(cC, 20e6);
        vm.warp(lockTime);
        market.lock();
    }

    function test_resolve_normalPayout() public {
        _stakeAndLock();
        // cA and cB win (rank <=10), cC loses (rank 0 = unranked)
        reg.setRank(cA, 1);
        reg.setRank(cB, 2);
        reg.setResolved(true);
        market.resolve();

        assertEq(uint8(market.status()), uint8(TierMarket.MarketStatus.RESOLVED));
        assertEq(market.winningStake(), 180e6);  // cA+cB
        assertEq(market.feeAmount(),    4e6);     // 2% of 200e6
        assertEq(market.netPool(),      196e6);
        assertFalse(market.noWinner());
    }

    function test_resolve_autoLock() public {
        vm.prank(alice); market.predict(cA, 100e6);
        // Never call lock() — warp past lockTime and resolve directly
        vm.warp(lockTime + 1);
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();
        assertEq(uint8(market.status()), uint8(TierMarket.MarketStatus.RESOLVED));
    }

    function test_resolve_revert_registryNotResolved() public {
        _stakeAndLock();
        vm.expectRevert(TierMarket.EventNotResolvedYet.selector);
        market.resolve();
    }

    function test_resolve_revert_notLocked() public {
        // Still OPEN and before lockTime
        reg.setResolved(true);
        vm.expectRevert(TierMarket.NotLocked.selector);
        market.resolve();
    }

    // ─────────────────────────────────────────────
    // No-winner full refund
    // ─────────────────────────────────────────────

    function test_resolve_noWinner_fullRefund() public {
        _stakeAndLock();
        // No ranks set → all candidates unranked → winningStake == 0
        reg.setResolved(true);
        market.resolve();

        assertTrue(market.noWinner());
        assertEq(market.feeAmount(), 0);
        assertEq(market.netPool(),   200e6); // full totalStaked

        // Alice should get full refund
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        assertEq(usdc.balanceOf(alice) - before, 100e6);
    }

    // ─────────────────────────────────────────────
    // Everyone-wins (soft payout)
    // ─────────────────────────────────────────────

    function test_resolve_everyoneWins_softPayout() public {
        _stakeAndLock();
        // All candidates ranked within tier
        reg.setRank(cA, 1); reg.setRank(cB, 2); reg.setRank(cC, 3);
        reg.setResolved(true);
        market.resolve();

        // winningStake == totalStaked → payout ≈ stake * (1 - fee)
        assertEq(market.winningStake(), 200e6);
        assertFalse(market.noWinner());

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        // alice: 100 * 196 / 200 = 98 USDC
        assertEq(usdc.balanceOf(alice) - before, 98e6);
    }

    // ─────────────────────────────────────────────
    // claim() after deadline reverts
    // ─────────────────────────────────────────────

    function test_claim_revert_afterDeadline() public {
        _stakeAndLock();
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();

        vm.warp(claimDeadline + 1);
        vm.prank(alice);
        vm.expectRevert(TierMarket.ClaimDeadlinePassed.selector);
        market.claim();
    }

    function test_claim_revert_alreadyClaimed() public {
        _stakeAndLock();
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();

        vm.prank(alice);
        market.claim();
        vm.prank(alice);
        vm.expectRevert(TierMarket.AlreadyClaimed.selector);
        market.claim();
    }

    function test_claim_revert_nothingToClaim() public {
        _stakeAndLock();
        // cA wins, bob (staked on cB) loses
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();

        vm.prank(bob);
        vm.expectRevert(TierMarket.NothingToClaim.selector);
        market.claim();
    }

    // ─────────────────────────────────────────────
    // finalizeMarket()
    // ─────────────────────────────────────────────

    function test_finalizeMarket_revert_beforeDeadline() public {
        _stakeAndLock();
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(
            TierMarket.FinalizeBeforeDeadline.selector,
            claimDeadline,
            block.timestamp
        ));
        market.finalizeMarket();
    }

    function test_finalizeMarket_sweeps_remaining() public {
        _stakeAndLock();
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();

        // Alice claims; bob and carol don't (cB/cC lost)
        vm.prank(alice);
        market.claim();

        vm.warp(claimDeadline + 1);
        vm.prank(owner);
        market.finalizeMarket();

        assertTrue(market.finalized());
        // feeRecipient got fee + unclaimed (carol/bob stakes on losers + dust)
        assertGt(usdc.balanceOf(feeDest), 0);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function test_finalizeMarket_revert_twice() public {
        _stakeAndLock();
        reg.setResolved(true);
        market.resolve();
        vm.warp(claimDeadline + 1);
        vm.prank(owner);
        market.finalizeMarket();
        vm.prank(owner);
        vm.expectRevert(TierMarket.AlreadyFinalized.selector);
        market.finalizeMarket();
    }

    function test_claim_revert_afterFinalize() public {
        _stakeAndLock();
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();
        vm.warp(claimDeadline + 1);
        vm.prank(owner);
        market.finalizeMarket();

        vm.prank(alice);
        vm.expectRevert(TierMarket.AlreadyFinalized.selector);
        market.claim();
    }

    // ─────────────────────────────────────────────
    // cancelMarket()
    // ─────────────────────────────────────────────

    function test_cancelMarket_refundsAllUsers() public {
        vm.prank(alice); market.predict(cA, 100e6);
        vm.prank(bob);   market.predict(cB, 50e6);

        reg.setCancelled(true);
        market.cancelMarket();

        assertEq(uint8(market.status()), uint8(TierMarket.MarketStatus.CANCELLED));
        assertTrue(market.noWinner());
        assertEq(market.feeAmount(), 0);
        assertEq(market.netPool(), 150e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6); // full refund

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        market.claim();
        assertEq(usdc.balanceOf(bob) - bobBefore, 50e6); // full refund
    }

    function test_cancelMarket_revert_registryNotCancelled() public {
        vm.expectRevert(TierMarket.EventNotCancelledYet.selector);
        market.cancelMarket();
    }

    function test_cancelMarket_revert_alreadyCancelled() public {
        reg.setCancelled(true);
        market.cancelMarket();
        vm.expectRevert(TierMarket.AlreadyCancelled.selector);
        market.cancelMarket();
    }

    function test_cancelMarket_revert_alreadyResolved() public {
        _stakeAndLock();
        reg.setResolved(true);
        market.resolve();
        reg.setCancelled(true); // shouldn't matter — already resolved
        vm.expectRevert(TierMarket.AlreadyResolved.selector);
        market.cancelMarket();
    }

    // ─────────────────────────────────────────────
    // Market balance conservation
    // ─────────────────────────────────────────────

    function test_balance_conservation_normal() public {
        _stakeAndLock();
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();

        uint256 balanceBefore = usdc.balanceOf(address(market));
        assertEq(balanceBefore, 200e6);

        // Alice claims (winner)
        vm.prank(alice);
        market.claim();

        // No-one else claims
        vm.warp(claimDeadline + 1);
        vm.prank(owner);
        market.finalizeMarket();

        // Market is drained
        assertEq(usdc.balanceOf(address(market)), 0);
        // Total distributed = alice's claim + feeDest sweep = totalStaked
        assertEq(
            usdc.balanceOf(feeDest) + market.totalClaimed(),
            200e6
        );
    }

    function test_balance_conservation_noWinner() public {
        _stakeAndLock();
        reg.setResolved(true);
        market.resolve();

        uint256 total = 200e6;

        vm.prank(alice); market.claim();
        vm.prank(bob);   market.claim();
        vm.prank(carol); market.claim();

        assertEq(market.totalClaimed(), total); // all funds returned
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    // ─────────────────────────────────────────────
    // claimable() view
    // ─────────────────────────────────────────────

    function test_claimable_before_resolve_returns_zero() public {
        vm.prank(alice); market.predict(cA, 100e6);
        assertEq(market.claimable(alice), 0);
    }

    function test_claimable_after_resolve() public {
        _stakeAndLock();
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();
        // alice staked 100 on cA (winner); winningStake=100, netPool=196
        assertEq(market.claimable(alice), 196e6);
    }

    // ─────────────────────────────────────────────
    // Partial claim progression (spec example 11.4)
    // ─────────────────────────────────────────────

    // ─────────────────────────────────────────────
    // G-1: Missing constructor revert tests
    // ─────────────────────────────────────────────

    function test_constructor_revert_zeroAddress_usdc() public {
        vm.prank(owner);
        vm.expectRevert(TierMarket.ZeroAddress.selector);
        new TierMarket(owner, address(0), address(reg), 1, TIER, FEE_BPS, feeDest, lockTime, MIN_STAKE, MAX_STAKE);
    }

    function test_constructor_revert_feeBpsTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TierMarket.FeeBpsTooHigh.selector, uint16(1001), uint16(1000)));
        new TierMarket(owner, address(usdc), address(reg), 1, TIER, 1001, feeDest, lockTime, MIN_STAKE, MAX_STAKE);
    }

    function test_constructor_revert_lockTimeInPast() public {
        vm.prank(owner);
        vm.expectRevert(TierMarket.LockTimeInPast.selector);
        new TierMarket(owner, address(usdc), address(reg), 1, TIER, FEE_BPS, feeDest, block.timestamp, MIN_STAKE, MAX_STAKE);
    }

    // ─────────────────────────────────────────────
    // G-2: Double-resolve reverts (one-shot invariant)
    // ─────────────────────────────────────────────

    function test_resolve_revert_alreadyResolved() public {
        _stakeAndLock();
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();
        vm.expectRevert(TierMarket.NotLocked.selector);
        market.resolve();
    }

    // ─────────────────────────────────────────────
    // G-3: finalizeMarket access control
    // ─────────────────────────────────────────────

    function test_finalizeMarket_revert_notOwner() public {
        _stakeAndLock();
        reg.setResolved(true);
        market.resolve();
        vm.warp(claimDeadline + 1);
        vm.prank(alice);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        market.finalizeMarket();
    }

    // ─────────────────────────────────────────────
    // G-4: Multi-winner exact payout precision + dust bound
    // ─────────────────────────────────────────────

    function test_multiWinner_exact_payouts() public {
        _stakeAndLock();
        // cA(100) + cB(80) win, cC(20) loses
        // totalStaked=200, fee=4, netPool=196, winningStake=180
        reg.setRank(cA, 1);
        reg.setRank(cB, 5);
        reg.setResolved(true);
        market.resolve();

        assertEq(market.netPool(), 196e6);
        assertEq(market.winningStake(), 180e6);

        // alice: 100 * 196_000000 / 180_000000 = 108_888888 (truncated)
        uint256 alicePayout = (uint256(100e6) * uint256(196e6)) / uint256(180e6);
        // bob:   80  * 196_000000 / 180_000000 = 87_111111 (truncated)
        uint256 bobPayout   = (uint256(80e6)  * uint256(196e6)) / uint256(180e6);

        assertEq(market.claimable(alice), alicePayout);
        assertEq(market.claimable(bob),   bobPayout);
        assertEq(market.claimable(carol), 0); // loser

        vm.prank(alice); market.claim();
        vm.prank(bob);   market.claim();

        assertEq(market.totalClaimed(), alicePayout + bobPayout);

        // Dust = netPool - totalClaimed; must be < winnerCount (rounding bound)
        uint256 dust = 196e6 - market.totalClaimed();
        assertLt(dust, 2); // at most 1 wei dust for 2 winners
    }

    // ─────────────────────────────────────────────
    // G-5: claimable() returns zero after state changes
    // ─────────────────────────────────────────────

    function test_claimable_zero_afterClaim() public {
        _stakeAndLock();
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();
        vm.prank(alice);
        market.claim();
        assertEq(market.claimable(alice), 0);
    }

    function test_claimable_cancelledMarket_fullRefund() public {
        vm.prank(alice); market.predict(cA, 100e6);
        reg.setCancelled(true);
        market.cancelMarket();
        assertEq(market.claimable(alice), 100e6);
    }

    function test_claimable_zero_afterDeadline() public {
        _stakeAndLock();
        reg.setRank(cA, 1);
        reg.setResolved(true);
        market.resolve();
        vm.warp(claimDeadline + 1);
        assertEq(market.claimable(alice), 0);
    }

    // ─────────────────────────────────────────────
    // Partial claim progression (spec example 11.4)
    // ─────────────────────────────────────────────

    function test_partial_claim_progression() public {
        _stakeAndLock();
        reg.setRank(cA, 1);
        reg.setRank(cB, 2);
        reg.setResolved(true);
        market.resolve();

        uint256 alicePayout = market.claimable(alice);
        uint256 bobPayout   = market.claimable(bob);

        vm.prank(alice);
        market.claim();
        assertEq(market.totalClaimed(), alicePayout);
        assertTrue(market.claimed(alice));

        // Bob can still claim after alice
        vm.prank(bob);
        market.claim();
        assertEq(market.totalClaimed(), alicePayout + bobPayout);
    }
}
