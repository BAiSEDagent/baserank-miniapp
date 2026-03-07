// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/BaseRankMarketV2.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract BaseRankMarketV2Test is Test {
    BaseRankMarketV2 market;
    MockUSDC usdc;
    address owner = address(0xA);
    address feeRecipient = address(0xB);
    address alice = address(0xC);
    address bob = address(0xD);

    uint64 epochId = 20260307;
    bytes32 candidate1 = keccak256(abi.encodePacked("app:Base App"));
    bytes32 candidate2 = keccak256(abi.encodePacked("app:Planet IX"));
    bytes32 candidate3 = keccak256(abi.encodePacked("app:NewApp"));

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(owner);
        market = new BaseRankMarketV2(address(usdc), owner, feeRecipient);
        
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);
        
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(market), type(uint256).max);
    }

    function _openMarket(uint64 eid, BaseRankMarketV2.MarketType mt) internal {
        vm.prank(owner);
        market.openMarket(BaseRankMarketV2.MarketConfig({
            epochId: eid,
            marketType: mt,
            openTime: uint64(block.timestamp + 1),
            lockTime: uint64(block.timestamp + 7 days),
            resolveTime: uint64(block.timestamp + 8 days),
            feeBps: 200,
            metadataHash: bytes32(0)
        }));
    }

    // -------- Open market tests --------

    function test_openMarket_noCandiates() public {
        _openMarket(epochId, BaseRankMarketV2.MarketType.BaseApp);
        assertEq(market.marketState(epochId, BaseRankMarketV2.MarketType.BaseApp), 1);
    }

    function test_openMarket_revertDuplicate() public {
        _openMarket(epochId, BaseRankMarketV2.MarketType.BaseApp);
        vm.prank(owner);
        vm.expectRevert(BaseRankMarketV2.InvalidState.selector);
        market.openMarket(BaseRankMarketV2.MarketConfig({
            epochId: epochId,
            marketType: BaseRankMarketV2.MarketType.BaseApp,
            openTime: uint64(block.timestamp + 1),
            lockTime: uint64(block.timestamp + 7 days),
            resolveTime: uint64(block.timestamp + 8 days),
            feeBps: 200,
            metadataHash: bytes32(0)
        }));
    }

    // -------- Predict tests --------

    function test_predict_anyCandidateId() public {
        _openMarket(epochId, BaseRankMarketV2.MarketType.BaseApp);
        vm.warp(block.timestamp + 2);

        // Alice predicts on candidate1
        vm.prank(alice);
        market.predict(epochId, BaseRankMarketV2.MarketType.BaseApp, candidate1, 1e6);
        assertEq(market.poolByCandidate(epochId, BaseRankMarketV2.MarketType.BaseApp, candidate1), 1e6);
        assertEq(market.userTotalStake(epochId, BaseRankMarketV2.MarketType.BaseApp, alice), 1e6);

        // Bob predicts on a COMPLETELY NEW candidateId — no pre-registration needed
        vm.prank(bob);
        market.predict(epochId, BaseRankMarketV2.MarketType.BaseApp, candidate3, 5e6);
        assertEq(market.poolByCandidate(epochId, BaseRankMarketV2.MarketType.BaseApp, candidate3), 5e6);
    }

    function test_predict_revertZeroCandidate() public {
        _openMarket(epochId, BaseRankMarketV2.MarketType.BaseApp);
        vm.warp(block.timestamp + 2);
        vm.prank(alice);
        vm.expectRevert(BaseRankMarketV2.InvalidCandidate.selector);
        market.predict(epochId, BaseRankMarketV2.MarketType.BaseApp, bytes32(0), 1e6);
    }

    function test_predict_revertMinStake() public {
        _openMarket(epochId, BaseRankMarketV2.MarketType.BaseApp);
        vm.warp(block.timestamp + 2);
        vm.prank(alice);
        vm.expectRevert(BaseRankMarketV2.InvalidAmount.selector);
        market.predict(epochId, BaseRankMarketV2.MarketType.BaseApp, candidate1, 100); // below MIN_STAKE
    }

    function test_predict_revertBeforeOpen() public {
        _openMarket(epochId, BaseRankMarketV2.MarketType.BaseApp);
        // Don't warp — still before openTime
        vm.prank(alice);
        vm.expectRevert(BaseRankMarketV2.InvalidState.selector);
        market.predict(epochId, BaseRankMarketV2.MarketType.BaseApp, candidate1, 1e6);
    }

    function test_predict_revertAfterLock() public {
        _openMarket(epochId, BaseRankMarketV2.MarketType.BaseApp);
        vm.warp(block.timestamp + 7 days + 1); // past lockTime
        vm.prank(alice);
        vm.expectRevert(BaseRankMarketV2.InvalidState.selector);
        market.predict(epochId, BaseRankMarketV2.MarketType.BaseApp, candidate1, 1e6);
    }

    // -------- Full lifecycle test --------

    function test_fullLifecycle() public {
        _openMarket(epochId, BaseRankMarketV2.MarketType.BaseApp);
        vm.warp(block.timestamp + 2);

        // Alice bets 10 USDC on candidate1 (winner)
        vm.prank(alice);
        market.predict(epochId, BaseRankMarketV2.MarketType.BaseApp, candidate1, 10e6);

        // Bob bets 10 USDC on candidate2 (loser)
        vm.prank(bob);
        market.predict(epochId, BaseRankMarketV2.MarketType.BaseApp, candidate2, 10e6);

        // Lock
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        market.lockMarket(epochId, BaseRankMarketV2.MarketType.BaseApp);
        assertEq(market.marketState(epochId, BaseRankMarketV2.MarketType.BaseApp), 2);

        // Resolve — candidate1 wins
        vm.warp(block.timestamp + 1 days);
        bytes32[] memory winners = new bytes32[](1);
        winners[0] = candidate1;
        vm.prank(owner);
        market.resolveMarket(epochId, BaseRankMarketV2.MarketType.BaseApp, winners, bytes32(uint256(1)));
        assertEq(market.marketState(epochId, BaseRankMarketV2.MarketType.BaseApp), 3);

        // Alice claims — gets pool minus fee
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = market.claimWinnings(epochId, BaseRankMarketV2.MarketType.BaseApp);
        // Total pool = 20 USDC, fee = 2% = 0.4 USDC, distributable = 19.6 USDC
        // Alice has 100% of winning pool → gets 19.6 USDC
        assertEq(claimed, 19_600_000);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 19_600_000);

        // Bob claims — gets nothing (bet on loser)
        vm.prank(bob);
        uint256 bobClaimed = market.claimWinnings(epochId, BaseRankMarketV2.MarketType.BaseApp);
        assertEq(bobClaimed, 0);

        // Owner collects fee
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        vm.prank(owner);
        uint256 feeAmt = market.collectFee(epochId, BaseRankMarketV2.MarketType.BaseApp);
        assertEq(feeAmt, 400_000); // 0.4 USDC
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 400_000);
    }

    // -------- Refund test (no winning pool) --------

    function test_refundWhenNoWinnersHaveStake() public {
        _openMarket(epochId, BaseRankMarketV2.MarketType.BaseApp);
        vm.warp(block.timestamp + 2);

        // Alice bets on candidate1
        vm.prank(alice);
        market.predict(epochId, BaseRankMarketV2.MarketType.BaseApp, candidate1, 5e6);

        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        market.lockMarket(epochId, BaseRankMarketV2.MarketType.BaseApp);

        // Resolve with candidate3 as winner (nobody bet on it)
        vm.warp(block.timestamp + 1 days);
        bytes32[] memory winners = new bytes32[](1);
        winners[0] = candidate3;
        vm.prank(owner);
        market.resolveMarket(epochId, BaseRankMarketV2.MarketType.BaseApp, winners, bytes32(uint256(2)));

        // Alice gets refund
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 refund = market.claimWinnings(epochId, BaseRankMarketV2.MarketType.BaseApp);
        assertEq(refund, 5e6);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 5e6);

        // Fee is zero in refund mode
        vm.prank(owner);
        uint256 fee = market.collectFee(epochId, BaseRankMarketV2.MarketType.BaseApp);
        assertEq(fee, 0);
    }
}
