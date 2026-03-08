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

    function test_resolveMarket_revert_duplicateRankings() public {
        _openAndWarp();
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        vm.warp(resolveTime);

        bytes32[10] memory dupes;
        dupes[0] = APP_AERO;
        dupes[1] = APP_UNI;
        dupes[2] = APP_AERO; // duplicate!
        vm.prank(owner);
        vm.expectRevert(BaseRankMarketV3.DuplicateCandidate.selector);
        market.resolveMarket(EPOCH, CHAIN, dupes, keccak256("snap"));
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

        BaseRankMarketV3.BucketState memory b10 = market.getBucketState(EPOCH, CHAIN, 0);
        BaseRankMarketV3.BucketState memory b5 = market.getBucketState(EPOCH, CHAIN, 1);
        BaseRankMarketV3.BucketState memory b1 = market.getBucketState(EPOCH, CHAIN, 2);

        // Pool = $300, fee = $6, net = $294
        assertEq(b10.reward, 88_200_000); // 30%
        assertEq(b5.reward, 117_600_000); // 40%
        assertEq(b1.reward, 88_200_000);  // 30%

        // Net staked = staked - 2% fee each
        assertEq(b10.netStaked, 98_000_000); // 100 - 2
        assertEq(b5.netStaked, 98_000_000);
        assertEq(b1.netStaked, 98_000_000);
    }

    // ─── Payout Math (Tier Buckets) ──────────────────────────────────────

    function test_payout_isolated_buckets() public {
        _openAndWarp();

        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 1);
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);
        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);

        // Each gets their bucket's reward (sole winner in each bucket)
        assertEq(aliceP, 88_200_000);  // Top 10 = 30%
        assertEq(bobP, 117_600_000);   // Top 5 = 40%
        assertEq(carolP, 88_200_000);  // #1 = 30%

        console2.log("Top 10 (Alice):", aliceP);
        console2.log("Top 5 (Bob):", bobP);
        console2.log("#1 (Carol):", carolP);
    }

    function test_payout_top10_normie_vs_loser() public {
        _openAndWarp();

        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser"), 100e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Top 10 bucket: $58.80 (30% of $196 net)
        // Alice sole winner → gets $58.80
        // Bob lost → $0
        assertEq(market.previewPayout(alice, EPOCH, CHAIN), 58_800_000);
        assertEq(market.previewPayout(bob, EPOCH, CHAIN), 0);
    }

    function test_payout_multi_tier_same_user() public {
        _openAndWarp();

        vm.startPrank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        market.predict(EPOCH, CHAIN, APP_AERO, 50e6, 1);
        market.predict(EPOCH, CHAIN, APP_AERO, 25e6, 2);
        vm.stopPrank();

        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);

        assertGt(aliceP, bobP);
        console2.log("Alice (multi-tier):", aliceP);
        console2.log("Bob (Top 10 only):", bobP);
    }

    // ─── Bucket Isolation ────────────────────────────────────────────────

    function test_bucket_isolation_prevents_parking() public {
        _openAndWarp();

        // 9 normies park $100 each on Top 10
        for (uint160 i = 1; i <= 9; i++) {
            address normie = address(i + 0x1000);
            usdc.mint(normie, 1_000_000e6);
            vm.prank(normie);
            usdc.approve(address(market), type(uint256).max);
            vm.prank(normie);
            market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        }

        // Carol bets $100 on #1
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);
        // Pool = $1000, fee = $20, net = $980
        // #1 bucket: $294 → Carol sole winner
        assertEq(carolP, 294_000_000);
    }

    // ─── No-Winner Refund (Fixed: refund from own stake, not reward) ─────

    function test_refund_from_own_stake_not_reward() public {
        _openAndWarp();

        // GPT's exploit scenario: $900 Top 10 + $100 #1, nobody hits #1
        for (uint160 i = 1; i <= 9; i++) {
            address normie = address(i + 0x1000);
            usdc.mint(normie, 1_000_000e6);
            vm.prank(normie);
            usdc.approve(address(market), type(uint256).max);
            vm.prank(normie);
            market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0); // Top 10
        }

        // Carol bets $100 #1 on a loser
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser"), 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);

        // OLD BUG: Carol would get $294 (30% of $980 net pool) on a $100 losing bet = +194% profit
        // FIXED: Carol gets her own stake minus 2% fee = $98
        assertEq(carolP, 98_000_000); // $98 — refund from own net stake
        assertLt(carolP, 100e6); // Less than staked (fee deducted)

        console2.log("Carol refund (was $294, now $98):", carolP);
    }

    function test_refund_all_in_one_bucket_no_winners() public {
        _openAndWarp();

        // GPT's nuke scenario: everyone bets #1 only, nobody wins
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser1"), 500e6, 2);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser2"), 500e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);

        // OLD BUG: $1000 pool, #1 bucket reward = $294, users only get back $294 total = -70.6%
        // FIXED: Each gets back their stake minus 2% fee
        assertEq(aliceP, 490_000_000); // $490 = $500 - 2%
        assertEq(bobP, 490_000_000);

        console2.log("Alice refund (was ~$147, now $490):", aliceP);
        console2.log("Bob refund (was ~$147, now $490):", bobP);
    }

    function test_bucket_refund_no_winners_small_bucket() public {
        _openAndWarp();

        // Alice: #1 on a loser, Bob: #1 on another loser
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser1"), 100e6, 2);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser2"), 50e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Refund from own net stake (not reward)
        // Alice: $100 - 2% = $98
        // Bob: $50 - 2% = $49
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);

        assertEq(aliceP, 98_000_000);
        assertEq(bobP, 49_000_000);
    }

    function test_no_one_bets_empty_bucket_ok() public {
        _openAndWarp();

        // Only Top 10 bets, Top 5 and #1 buckets are empty (zero staked)
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_UNI, 100e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Both win Top 10, split the Top 10 bucket
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);

        // Top 10 bucket = 30% of $196 = $58.80, split 50/50
        assertEq(aliceP, 29_400_000);
        assertEq(bobP, 29_400_000);
    }

    // ─── Mixed scenarios ─────────────────────────────────────────────────

    function test_no_winners_top10_but_winners_top5_and_num1() public {
        _openAndWarp();

        vm.prank(alice);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser"), 100e6, 0); // Top 10 loser
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 1); // Top 5 winner
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 2); // #1 winner

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);
        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);

        // Alice: refund from own stake minus fee = $98
        assertEq(aliceP, 98_000_000);
        // Bob: Top 5 bucket reward
        assertEq(bobP, 117_600_000);
        // Carol: #1 bucket reward
        assertEq(carolP, 88_200_000);
    }

    function test_no_winners_num1_but_winners_top10_top5() public {
        _openAndWarp();

        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 0); // Top 10 winner
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_UNI, 100e6, 1); // Top 5 winner
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser"), 100e6, 2); // #1 loser

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);
        // Carol gets refund from own stake: $100 - 2% = $98
        assertEq(carolP, 98_000_000);
    }

    function test_no_winners_anywhere() public {
        _openAndWarp();

        vm.prank(alice);
        market.predict(EPOCH, CHAIN, keccak256("chain:LoserA"), 100e6, 0);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, keccak256("chain:LoserB"), 100e6, 1);
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, keccak256("chain:LoserC"), 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Everyone gets refund from own bucket's net stake
        assertEq(market.previewPayout(alice, EPOCH, CHAIN), 98_000_000);
        assertEq(market.previewPayout(bob, EPOCH, CHAIN), 98_000_000);
        assertEq(market.previewPayout(carol, EPOCH, CHAIN), 98_000_000);
    }

    function test_single_bettor_alone_in_bucket() public {
        _openAndWarp();

        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 2);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Pool = $100, net = $98
        // #1 bucket reward = $29.40 (30% of $98)
        // Carol is sole winner → gets $29.40
        uint256 carolP = market.previewPayout(carol, EPOCH, CHAIN);
        assertEq(carolP, 29_400_000);
    }

    function test_top5_loses_at_rank6() public {
        _openAndWarp();

        bytes32 sixth = keccak256("chain:Sixth");
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, sixth, 100e6, 1); // Top 5 — loses (rank #6)
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, sixth, 100e6, 0); // Top 10 — wins (rank #6)

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        // Alice: Top 5 has no winners → refund from own net stake = $98
        // Bob: Top 10 has winners → gets Top 10 bucket reward
        uint256 aliceP = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 bobP = market.previewPayout(bob, EPOCH, CHAIN);

        assertEq(aliceP, 98_000_000); // refund
        assertGt(bobP, 0); // bucket reward
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
        assertGt(usdc.balanceOf(alice), balBefore);
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

    function test_claim_matches_preview() public {
        _openAndWarp();
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 100e6, 2);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser"), 200e6, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 preview = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim(EPOCH, CHAIN);
        assertEq(usdc.balanceOf(alice) - balBefore, preview);
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

        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 2e6);
    }

    function test_setFeeRecipient() public {
        vm.prank(owner);
        market.setFeeRecipient(address(0xBEEF));
        assertEq(market.feeRecipient(), address(0xBEEF));
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
        assertEq(uint8(bets[0].betType), 0);
        assertEq(uint8(bets[1].betType), 1);
        assertEq(uint8(bets[2].betType), 2);
    }

    // ─── Degenerate ──────────────────────────────────────────────────────

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

        // All win Top 10, split the bucket 3 ways
        assertEq(market.previewPayout(alice, EPOCH, CHAIN), 29_400_000);
    }

    // ─── Rounding ────────────────────────────────────────────────────────

    function test_dust_rounding() public {
        _openAndWarp();

        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 33_333_333, 0);
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, APP_UNI, 33_333_333, 0);
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_BASE, 33_333_334, 0);

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 a = market.previewPayout(alice, EPOCH, CHAIN);
        uint256 b = market.previewPayout(bob, EPOCH, CHAIN);
        uint256 c = market.previewPayout(carol, EPOCH, CHAIN);

        assertGt(a, 0);
        assertGt(b, 0);
        assertGt(c, 0);

        BaseRankMarketV3.BucketState memory bk = market.getBucketState(EPOCH, CHAIN, 0);
        assertLe(a + b + c, bk.reward); // no overpay
    }

    // ─── Solvency: total payouts never exceed contract balance ───────────

    function test_solvency_mixed_winners_and_refunds() public {
        _openAndWarp();

        // Mix of winners and losers across all buckets
        vm.prank(alice);
        market.predict(EPOCH, CHAIN, APP_AERO, 200e6, 0); // Top 10 winner
        vm.prank(bob);
        market.predict(EPOCH, CHAIN, keccak256("chain:Loser"), 300e6, 1); // Top 5 loser (refund)
        vm.prank(carol);
        market.predict(EPOCH, CHAIN, APP_AERO, 500e6, 2); // #1 winner

        vm.warp(resolveTime);
        vm.prank(owner);
        market.resolveMarket(EPOCH, CHAIN, _defaultRankings(), keccak256("snap"));

        uint256 contractBal = usdc.balanceOf(address(market));
        uint256 totalPayouts = market.previewPayout(alice, EPOCH, CHAIN)
            + market.previewPayout(bob, EPOCH, CHAIN)
            + market.previewPayout(carol, EPOCH, CHAIN);

        // Total payouts must never exceed what the contract holds
        assertLe(totalPayouts, contractBal);

        console2.log("Contract balance:", contractBal);
        console2.log("Total payouts:", totalPayouts);
        console2.log("Surplus (dust):", contractBal - totalPayouts);
    }
}
