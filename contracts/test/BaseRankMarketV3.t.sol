// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BaseRankMarketV3} from "../src/BaseRankMarketV3.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract BaseRankMarketV3Test is Test {
    BaseRankMarketV3 public market;
    ERC20Mock public usdc;

    address owner = address(0xA1);
    address feeRecipient = address(0xFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint64 constant EPOCH = 20260318;
    uint8 constant CHAIN = 1;

    bytes32 constant APP_AERO = keccak256("chain:Aerodrome");
    bytes32 constant APP_UNI = keccak256("chain:Uniswap");
    bytes32 constant APP_BASE = keccak256("chain:Base App");
    bytes32 constant APP_DARK = keccak256("chain:DarkHorse");
    bytes32 constant APP_5TH = keccak256("chain:FifthPlace");

    uint64 openTime;
    uint64 lockTime;
    uint64 resolveTime;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        market = new BaseRankMarketV3(address(usdc), feeRecipient, owner);

        openTime = uint64(block.timestamp + 1);
        lockTime = uint64(block.timestamp + 7 days);
        resolveTime = uint64(block.timestamp + 7 days + 30 minutes);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(carol, 1_000_000e6);

        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(carol);
        usdc.approve(address(market), type(uint256).max);
    }

    function _openMarket() internal {
        vm.prank(owner);
        market.openMarket(EPOCH, CHAIN, openTime, lockTime, resolveTime, 200);
    }

    function _openAndWarp() internal {
        _openMarket();
        vm.warp(openTime + 1);
    }

    function _defaultRankings() internal pure returns (bytes32[10] memory r) {
        r[0] = APP_AERO;
        r[1] = APP_UNI;
        r[2] = APP_BASE;
        r[3] = APP_DARK;
        r[4] = APP_5TH;
        r[5] = keccak256("chain:Sixth");
        r[6] = keccak256("chain:Seventh");
        r[7] = keccak256("chain:Eighth");
        r[8] = keccak256("chain:Ninth");
        r[9] = keccak256("chain:Tenth");
    }

    // ─── Market Lifecycle ────────────────────────────────────────────────

    function test_openMarket() public {
        _openMarket();
        BaseRankMarketV3.MarketConfig memory m = market.marketDetails(EPOCH, CHAIN);
        assertEq(uint8(m.state), 1);
        assertEq(m.openTime, openTime);
        assertEq(m.lockTime, lockTime);
        assertEq(m.feeBps, 200);
    }

    function test_openMarket_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        market.openMarket(EPOCH, CHAIN, openTime, lockTime, resolveTime, 200);
    }

    function test_openMarket_revert_alreadyExists() public {
        _openMarket();
        vm.prank(owner);
        vm.expectRevert(BaseRankMarketV3.MarketAlreadyExists.selector);
        market.openMarket(EPOCH, CHAIN, openTime, lockTime, resolveTime, 200);
    }

    function test_openMarket_revert_lockTimeInPast() public {
        vm.prank(owner);
        vm.expectRevert(BaseRankMarketV3.InvalidTime.selector);
        market.openMarket(EPOCH, CHAIN, openTime, uint64(block.timestamp - 1), resolveTime, 200);
    }

    function test_openMarket_revert_feeTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(BaseRankMarketV3.InvalidFee.selector);
        market.openMarket(EPOCH, CHAIN, openTime, lockTime, resolveTime, 1001);
    }

    // ─── Predict ─────────────────────────────────────────────────────────

    function test_predict_top10() public {
        _openAndWarp();
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        assertEq(market.totalPool(EPOCH, CHAIN), 100e6);
        assertEq(market.userTotalStake(EPOCH, CHAIN, alice), 100e6);
        assertEq(market.candidateBetTypeStake(EPOCH, CHAIN, APP_AERO, 0), 100e6);

        BaseRankMarketV3.BucketState memory b = market.getBucketState(EPOCH, CHAIN, 0);
        assertEq(b.totalStaked, 100e6);
    }

    function test_predict_top5() public {
        _openAndWarp();
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_UNI, 50e6, 1);

        BaseRankMarketV3.BucketState memory b = market.getBucketState(EPOCH, CHAIN, 1);
        assertEq(b.totalStaked, 50e6);
    }

    function test_predict_top1() public {
        _openAndWarp();
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_DARK, 10e6, 2);

        BaseRankMarketV3.BucketState memory b = market.getBucketState(EPOCH, CHAIN, 2);
        assertEq(b.totalStaked, 10e6);
    }

    function test_predict_revert_belowMinStake() public {
        _openAndWarp();
        vm.prank(alice);
        vm.expectRevert(BaseRankMarketV3.StakeTooLow.selector);
        market.predict(EPOCH, CHAIN, APP_AERO, 9_999, 0);
    }

    function test_predict_revert_zeroCandidate() public {
        _openAndWarp();
        vm.prank(alice);
        vm.expectRevert(BaseRankMarketV3.InvalidCandidate.selector);
        market.predict(EPOCH, CHAIN, bytes32(0), 100e6, 0);
    }

    function test_predict_revert_invalidBetType() public {
        _openAndWarp();
        vm.prank(alice);
        vm.expectRevert(BaseRankMarketV3.InvalidBetType.selector);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 3);
    }

    function test_predict_revert_beforeOpen() public {
        _openMarket();
        vm.prank(alice);
        vm.expectRevert(BaseRankMarketV3.MarketNotOpen.selector);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
    }

    function test_predict_revert_afterLock() public {
        _openAndWarp();
        vm.warp(lockTime);
        vm.prank(alice);
        vm.expectRevert(BaseRankMarketV3.MarketNotOpen.selector);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
    }

    function test_predict_multipleBets() public {
        _openAndWarp();
        vm.startPrank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        market.predict(EPOCH, CHAIN, APP_UNI, 50e6, 1);
        market.predict(EPOCH, CHAIN, APP_DARK, 10e6, 2);
        vm.stopPrank();

        assertEq(market.getUserBetCount(alice, EPOCH, CHAIN), 3);
        assertEq(market.userTotalStake(EPOCH, CHAIN, alice), 160e6);
        assertEq(market.totalPool(EPOCH, CHAIN), 160e6);
    }

    // ─── Resolution ──────────────────────────────────────────────────────

    function test_resolveMarket() public {
        _openAndWarp();
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snapshot1"));

        BaseRankMarketV3.MarketConfig memory m = market.marketDetails(EPOCH, CHAIN);
        assertEq(uint8(m.state), 3);
    }

    function test_resolveMarket_revert_tooEarly() public {
        _openAndWarp();
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        vm.warp(resolveTime - 1);
        vm.prank(owner);
        vm.expectRevert(BaseRankMarketV3.InvalidTime.selector);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));
    }

    function test_resolveMarket_revert_emptyRankings() public {
        _openAndWarp();
        vm.warp(resolveTime);

        bytes32[10] memory empty;
        vm.prank(owner);
        vm.expectRevert(BaseRankMarketV3.InvalidRankings.selector);
        market.resolveMarket(EPOCH, CHAIN, empty, keccak256("snap"));
    }

    function test_resolveMarket_bucketRewards() public {
        _openAndWarp();

        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_UNI, 100e6, 1);
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_DARK, 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Pool = $300, fee = $6, net = $294
        // Top 10 bucket: 294 * 30% = $88.20
        // Top 5 bucket: 294 * 40% = $117.60
        // #1 bucket: 294 * 30% = $88.20
        BaseRankMarketV3.BucketState memory b10 = market.getBucketState(EPOCH, CHAIN, 0);
        BaseRankMarketV3.BucketState memory b5 = market.getBucketState(EPOCH, CHAIN, 1);
        BaseRankMarketV3.BucketState memory b1 = market.getBucketState(EPOCH, CHAIN, 2);

        assertEq(b10.reward, 88_200_000); // $88.20
        assertEq(b5.reward, 117_600_000); // $117.60
        assertEq(b1.reward, 88_200_000);  // $88.20
    }

    // ─── Payout Math (Tier Buckets) ──────────────────────────────────────

    function test_payout_isolated_buckets() public {
        _openAndWarp();

        // Alice: $100 Top 10 on Aero (winner)
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        // Bob: $100 Top 5 on Aero (winner)
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 1);

        // Carol: $100 #1 on Aero (winner — Aero is #1)
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // All winners but each gets their own bucket
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);
        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);

        // Pool = $300, fee = $6, net = $294
        // Alice gets Top 10 bucket = $88.20
        // Bob gets Top 5 bucket = $117.60
        // Carol gets #1 bucket = $88.20
        assertEq(aliceP, 88_200_000);
        assertEq(bobP, 117_600_000);
        assertEq(carolP, 88_200_000);

        console2.log("Top 10 (Alice):", aliceP);
        console2.log("Top 5 (Bob):", bobP);
        console2.log("#1 (Carol):", carolP);
    }

    function test_payout_top10_normie_vs_loser() public {
        _openAndWarp();

        // Alice: $100 Top 10 on Aero (winner)
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        // Bob: $100 Top 10 on a loser
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser"), 100e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Pool = $200, fee = $4, net = $196
        // Top 10 bucket = $58.80 (30% of $196)
        // Alice is only Top 10 winner → gets full $58.80
        // Bob lost → gets $0 from Top 10 bucket
        // But no one bet Top 5 or #1, so those buckets have $0 staked
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);

        assertEq(aliceP, 58_800_000); // $58.80
        assertEq(bobP, 0);
    }

    function test_payout_no_one_bets_num1_refund() public {
        _openAndWarp();

        // Only Top 10 bets, no Top 5 or #1
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_UNI, 100e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Pool = $200, fee = $4, net = $196
        // Top 10 bucket: $58.80 → both win (Aero + Uni in top 10), split 50/50
        // Top 5 bucket: $78.40 → zero staked → no refund needed (nobody participated)
        // #1 bucket: $58.80 → zero staked → no refund needed
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);

        // Each gets half of Top 10 bucket
        assertEq(aliceP, 29_400_000); // $29.40
        assertEq(bobP, 29_400_000);
    }

    function test_payout_bucket_refund_no_winners() public {
        _openAndWarp();

        // Alice bets #1 on a loser (nobody hits #1)
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser1"), 100e6, 2);

        // Bob bets #1 on another loser
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser2"), 50e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Pool = $150, fee = $3, net = $147
        // #1 bucket: 147 * 30% = $44.10
        // No winners in #1 → pro-rata refund
        // Alice refund: (100/150) * 44.10 = $29.40
        // Bob refund: (50/150) * 44.10 = $14.70
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);

        assertEq(aliceP, 29_400_000);
        assertEq(bobP, 14_700_000);
    }

    function test_payout_top5_loses_at_rank6() public {
        _openAndWarp();

        bytes32 sixth = keccak256("chain:Sixth");

        // Alice: Top 5 bet on Sixth (will rank #6 — loses)
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, sixth, 100e6, 1);

        // Bob: Top 10 bet on Sixth (will rank #6 — wins)
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, sixth, 100e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Alice's Top 5 bet LOSES
        // Bob's Top 10 bet WINS
        // Alice gets refund from Top 5 bucket (she's the only one in it, no winners)
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);

        assertGt(bobP, 0); // Bob wins from Top 10 bucket
        assertGt(aliceP, 0); // Alice gets refund from Top 5 bucket (no winners)
    }

    function test_payout_multi_tier_same_user() public {
        _openAndWarp();

        // Alice bets across all tiers
        vm.startPrank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0); // Top 10
        market.predict(EPOCH, CHAIN, APP_AERO, 50e6, 1);   // Top 5
        market.predict(EPOCH, CHAIN, APP_AERO, 25e6, 2);   // #1
        vm.stopPrank();

        // Bob also bets Top 10 on Aero
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Aero is #1 → all Alice's bets win
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);

        // Pool = $275, fee = $5.50, net = $269.50
        // Top 10 bucket: $80.85 → Alice 100/(100+100) = $40.425, Bob = $40.425
        // Top 5 bucket: $107.80 → Alice sole winner = $107.80
        // #1 bucket: $80.85 → Alice sole winner = $80.85

        // Alice total ≈ $40.42 + $107.80 + $80.85 = $229.07
        // Bob total ≈ $40.42
        assertGt(aliceP, bobP);
        assertApproxEqAbs(aliceP + bobP, 269_500_000, 3); // net pool minus rounding

        console2.log("Alice (multi-tier):", aliceP);
        console2.log("Bob (Top 10 only):", bobP);
    }

    // ─── Claims ──────────────────────────────────────────────────────────

    function test_claim_success() public {
        _openAndWarp();

        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim(EPOCH, CHAIN);
        uint256 balAfter = usdc.balanceOf(alice);

        assertGt(balAfter, balBefore);
    }

    function test_claim_revert_doubleClaim() public {
        _openAndWarp();
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        vm.prank(alice);
        market.claim(EPOCH, CHAIN);

        vm.prank(alice);
        vm.expectRevert(BaseRankMarketV3.NothingToClaim.selector);
        market.claim(EPOCH, CHAIN);
    }

    function test_claim_revert_notResolved() public {
        _openAndWarp();
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        vm.prank(alice);
        vm.expectRevert(BaseRankMarketV3.MarketNotResolved.selector);
        market.claim(EPOCH, CHAIN);
    }

    // ─── Fee ─────────────────────────────────────────────────────────────

    function test_fee_collected() public {
        _openAndWarp();
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 feeAfter = usdc.balanceOf(feeRecipient);
        assertEq(feeAfter - feeBefore, 2e6); // 2% of $100
    }

    function test_setFeeRecipient() public {
        address newRecipient = address(0xBEEF);
        vm.prank(owner);
        market.setFeeRecipient(newRecipient);
        assertEq(market.feeRecipient(), newRecipient);
    }

    function test_setFeeRecipient_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert(BaseRankMarketV3.ZeroAddress.selector);
        market.setFeeRecipient(address(0));
    }

    // ─── Pause ───────────────────────────────────────────────────────────

    function test_pause_blocks_predict() public {
        _openAndWarp();
        vm.prank(owner);
        market.pause();

        vm.prank(alice);
        vm.expectRevert();
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
    }

    function test_unpause_allows_predict() public {
        _openAndWarp();
        vm.prank(owner);
        market.pause();
        vm.prank(owner);
        market.unpause();

        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        assertEq(market.totalPool(EPOCH, CHAIN), 100e6);
    }

    // ─── getUserBets ─────────────────────────────────────────────────────

    function test_getUserBets_returns_all() public {
        _openAndWarp();

        vm.startPrank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        market.predict(EPOCH, CHAIN, APP_UNI, 50e6, 1);
        market.predict(EPOCH, CHAIN, APP_DARK, 10e6, 2);
        vm.stopPrank();

        BaseRankMarketV3.UserBet[] memory bets = market.getUserBets(alice, EPOCH, CHAIN);
        assertEq(bets.length, 3);
        assertEq(bets[0].amount, 100e6);
        assertEq(uint8(bets[0].betType), 0);
        assertEq(bets[1].amount, 50e6);
        assertEq(uint8(bets[1].betType), 1);
        assertEq(bets[2].amount, 10e6);
        assertEq(uint8(bets[2].betType), 2);
    }

    // ─── Degenerate: Everyone bets same app same tier ────────────────────

    function test_everyone_bets_same_app_top10() public {
        _openAndWarp();

        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // All 3 win Top 10. Pool = $300, fee = $6, net = $294
        // Top 10 bucket = $88.20, split 3 ways = $29.40 each
        // Top 5 bucket = $117.60, zero staked → nothing
        // #1 bucket = $88.20, zero staked → nothing
        // Each person staked $100, gets back $29.40 — effectively -70%
        // This is the correct behavior — all the value went to empty buckets
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        assertEq(aliceP, 29_400_000);
    }

    // ─── Bucket isolation: Top 10 parking doesn't cannibalize #1 ─────────

    function test_bucket_isolation_prevents_parking() public {
        _openAndWarp();

        // 9 normies park $100 each on Top 10 safe bets
        for (uint160 i = 1; i <= 9; i++) {
            address normie = address(i + 0x1000);
            usdc.mint(normie, 1_000_000e6);
            vm.prank(normie);
            usdc.approve(address(market), type(uint256).max);
            vm.prank(normie);
            market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        }

        // Carol bets $100 on #1 dark horse that actually hits
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Pool = $1000, fee = $20, net = $980
        // Top 10 bucket: $294 shared among 9 normies = $32.67 each (staked $100, lost ~67%)
        // #1 bucket: $294 → Carol is sole winner = $294 (staked $100, +194%)
        // Top 5 bucket: $392 → no stakers → nothing

        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);
        assertEq(carolP, 294_000_000); // $294

        // Carol's $100 #1 bet returns $294 regardless of how many normies parked on Top 10
        // This is the key property: bucket isolation prevents safe-bet parking from draining degen rewards
    }

    // ─── Edge Cases: Per-Bucket No-Winner Scenarios ──────────────────────

    function test_no_winners_top10_but_winners_top5_and_num1() public {
        _openAndWarp();

        // Alice: Top 10 on a loser
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser"), 100e6, 0);

        // Bob: Top 5 on Aero (winner — Aero is #1, in top 5)
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 1);

        // Carol: #1 on Aero (winner)
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Top 10 bucket: no winners → refund Alice
        // Top 5 bucket: Bob wins
        // #1 bucket: Carol wins
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);
        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);

        // All should get something (Alice via refund, Bob/Carol via wins)
        assertGt(aliceP, 0);
        assertGt(bobP, 0);
        assertGt(carolP, 0);
    }

    function test_no_winners_num1_but_winners_top10_top5() public {
        _openAndWarp();

        // Alice: Top 10 on Aero (winner)
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        // Bob: Top 5 on Uni (winner — Uni is #2)
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_UNI, 100e6, 1);

        // Carol: #1 on a loser
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser"), 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);
        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);

        // Alice wins from Top 10 bucket
        // Bob wins from Top 5 bucket
        // Carol gets refund from #1 bucket (sole participant, no winner)
        assertGt(aliceP, 0);
        assertGt(bobP, 0);
        assertGt(carolP, 0);
    }

    function test_no_winners_top5_only() public {
        _openAndWarp();

        // Alice: Top 10 on Aero (winner)
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        // Bob: Top 5 on Tenth (rank #10 — not in top 5, loses)
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, keccak256("chain:Tenth"), 100e6, 1);

        // Carol: #1 on Aero (winner)
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);
        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);

        assertGt(aliceP, 0); // Top 10 win
        assertGt(bobP, 0);   // Top 5 refund (no winners in bucket)
        assertGt(carolP, 0); // #1 win
    }

    function test_no_winners_anywhere() public {
        _openAndWarp();

        // Everyone bets on losers across all tiers
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, keccak256("chain:LoserA"), 100e6, 0);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, keccak256("chain:LoserB"), 100e6, 1);
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, keccak256("chain:LoserC"), 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // All buckets have zero winners → all get pro-rata refund from their bucket
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);
        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);

        // Pool = $300, fee = $6, net = $294
        // Each person's refund comes from their bucket
        // Alice: Top 10 bucket = $88.20 (sole participant)
        // Bob: Top 5 bucket = $117.60 (sole participant)
        // Carol: #1 bucket = $88.20 (sole participant)
        assertEq(aliceP, 88_200_000);
        assertEq(bobP, 117_600_000);
        assertEq(carolP, 88_200_000);
    }

    function test_single_bettor_alone_in_bucket() public {
        _openAndWarp();

        // Only Carol bets — sole participant in #1 bucket, no one else in market
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Pool = $100, fee = $2, net = $98
        // #1 bucket: $29.40 → Carol is sole winner (Aero is #1)
        // Top 10 bucket: $29.40 → zero staked → nothing
        // Top 5 bucket: $39.20 → zero staked → nothing
        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);
        assertEq(carolP, 29_400_000); // $29.40 — she gets her bucket
    }

    function test_dust_rounding_with_odd_amounts() public {
        _openAndWarp();

        // Three bettors with amounts that don't divide evenly
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 33_333_333, 0); // $33.333333
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_UNI, 33_333_333, 0);  // $33.333333
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_BASE, 33_333_334, 0); // $33.333334

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // All three win Top 10. Should not revert.
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);
        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);

        // All should get roughly equal payouts
        assertGt(aliceP, 0);
        assertGt(bobP, 0);
        assertGt(carolP, 0);

        // Total claimed should not exceed bucket reward (rounding floors)
        BaseRankMarketV3.BucketState memory b = market.getBucketState(EPOCH, CHAIN, 0);
        assertLe(aliceP + bobP + carolP, b.reward);
    }

    function test_claim_transfers_correct_usdc() public {
        _openAndWarp();

        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 2); // #1

        vm.prank(bob);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser"), 200e6, 0); // Top 10 loser

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 preview = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        market.claim(EPOCH, CHAIN);

        uint256 balAfter = usdc.balanceOf(alice);
        assertEq(balAfter - balBefore, preview); // claim matches preview exactly
    }
}
