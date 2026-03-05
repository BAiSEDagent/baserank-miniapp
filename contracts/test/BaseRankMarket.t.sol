// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {BaseRankMarket, IBaseRankMarket} from "../src/BaseRankMarket.sol";

contract MockUSDC is ERC20, ERC20Permit {
    constructor() ERC20("Mock USDC", "mUSDC") ERC20Permit("Mock USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BaseRankMarketTest is Test {
    MockUSDC usdc;
    BaseRankMarket market;

    uint256 ownerPk = 0xA11CE;
    uint256 userPk = 0xB0B;
    uint256 attackerPk = 0xC0FFEE;

    address owner;
    address user;
    address attacker;

    bytes32 c1 = keccak256("candidate-1");
    bytes32 c2 = keccak256("candidate-2");

    function setUp() external {
        owner = vm.addr(ownerPk);
        user = vm.addr(userPk);
        attacker = vm.addr(attackerPk);

        usdc = new MockUSDC();
        market = new BaseRankMarket(address(usdc), owner, owner);

        usdc.mint(user, 1_000_000e6);
        usdc.mint(attacker, 1_000_000e6);
    }

    function _candidateSet() internal view returns (bytes32[] memory ids) {
        ids = new bytes32[](15);
        ids[0] = c1;
        ids[1] = c2;
        for (uint256 i = 2; i < 15; ++i) {
            ids[i] = keccak256(abi.encodePacked("candidate", i));
        }
    }

    function _open() internal {
        IBaseRankMarket.MarketConfig memory cfg;
        cfg.epochId = 1;
        cfg.marketType = IBaseRankMarket.MarketType.BaseApp;
        cfg.openTime = uint64(block.timestamp + 60);
        cfg.lockTime = uint64(block.timestamp + 1 days);
        cfg.resolveTime = uint64(block.timestamp + 2 days);
        cfg.feeBps = 100;
        cfg.metadataHash = keccak256("meta");
        cfg.candidateIds = _candidateSet();

        vm.prank(owner);
        market.openMarket(cfg);

        vm.warp(block.timestamp + 120);
    }

    function _resolveSingleWinner(bytes32 winner) internal {
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        market.lockMarket(1, IBaseRankMarket.MarketType.BaseApp);

        bytes32[] memory winners = new bytes32[](1);
        winners[0] = winner;

        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        market.resolveMarket(1, IBaseRankMarket.MarketType.BaseApp, winners, keccak256("snapshot"));
    }

    function testOnlyOwnerLifecycle() external {
        _open();
        vm.prank(attacker);
        vm.expectRevert();
        market.lockMarket(1, IBaseRankMarket.MarketType.BaseApp);
    }

    function testPredictApproveFlow() external {
        _open();

        vm.startPrank(user);
        usdc.approve(address(market), 100e6);
        market.predict(1, IBaseRankMarket.MarketType.BaseApp, c1, 100e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(market)), 100e6);
    }

    function testPredictWithPermit() external {
        _open();

        uint256 amount = 120e6;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(market),
                amount,
                usdc.nonces(user),
                deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        IBaseRankMarket.PermitParams memory p =
            IBaseRankMarket.PermitParams({value: amount, deadline: deadline, v: v, r: r, s: s});

        vm.prank(user);
        market.predictWithPermit(1, IBaseRankMarket.MarketType.BaseApp, c1, amount, p);

        assertEq(usdc.balanceOf(address(market)), amount);
    }

    function testPayoutMathWithFee() external {
        _open();

        vm.startPrank(user);
        usdc.approve(address(market), 100e6);
        market.predict(1, IBaseRankMarket.MarketType.BaseApp, c1, 100e6);
        vm.stopPrank();

        vm.startPrank(attacker);
        usdc.approve(address(market), 300e6);
        market.predict(1, IBaseRankMarket.MarketType.BaseApp, c2, 300e6);
        vm.stopPrank();

        _resolveSingleWinner(c1);

        uint256 beforeBal = usdc.balanceOf(user);
        vm.prank(user);
        uint256 claimed = market.claimWinnings(1, IBaseRankMarket.MarketType.BaseApp);
        uint256 afterBal = usdc.balanceOf(user);

        assertEq(claimed, 396e6);
        assertEq(afterBal - beforeBal, 396e6);
    }

    function testNoWinnerRefundPath() external {
        _open();

        vm.startPrank(user);
        usdc.approve(address(market), 50e6);
        market.predict(1, IBaseRankMarket.MarketType.BaseApp, c1, 50e6);
        vm.stopPrank();

        _resolveSingleWinner(c2);

        vm.prank(user);
        uint256 refund = market.claimWinnings(1, IBaseRankMarket.MarketType.BaseApp);
        assertEq(refund, 50e6);
    }

    function testPauseBlocksPredictAndClaim() external {
        _open();

        vm.prank(owner);
        market.pause();

        vm.startPrank(user);
        usdc.approve(address(market), 1e6);
        vm.expectRevert();
        market.predict(1, IBaseRankMarket.MarketType.BaseApp, c1, 1e6);
        vm.stopPrank();

        vm.prank(owner);
        market.unpause();

        vm.startPrank(user);
        market.predict(1, IBaseRankMarket.MarketType.BaseApp, c1, 1e6);
        vm.stopPrank();

        _resolveSingleWinner(c1);

        vm.prank(owner);
        market.pause();

        vm.prank(user);
        vm.expectRevert();
        market.claimWinnings(1, IBaseRankMarket.MarketType.BaseApp);
    }

    function testFeeCollectionOnce() external {
        _open();

        vm.startPrank(user);
        usdc.approve(address(market), 100e6);
        market.predict(1, IBaseRankMarket.MarketType.BaseApp, c1, 100e6);
        vm.stopPrank();

        vm.startPrank(attacker);
        usdc.approve(address(market), 300e6);
        market.predict(1, IBaseRankMarket.MarketType.BaseApp, c2, 300e6);
        vm.stopPrank();

        _resolveSingleWinner(c1);

        uint256 ownerBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        uint256 fee = market.collectFee(1, IBaseRankMarket.MarketType.BaseApp);
        uint256 ownerAfter = usdc.balanceOf(owner);

        assertEq(fee, 4e6);
        assertEq(ownerAfter - ownerBefore, 4e6);

        vm.prank(owner);
        vm.expectRevert();
        market.collectFee(1, IBaseRankMarket.MarketType.BaseApp);
    }

    function testFuzzConservation(uint96 userAmt, uint96 attackerAmt) external {
        _open();

        uint256 a = bound(uint256(userAmt), 1e6, 100_000e6);
        uint256 b = bound(uint256(attackerAmt), 1e6, 100_000e6);

        vm.startPrank(user);
        usdc.approve(address(market), a);
        market.predict(1, IBaseRankMarket.MarketType.BaseApp, c1, a);
        vm.stopPrank();

        vm.startPrank(attacker);
        usdc.approve(address(market), b);
        market.predict(1, IBaseRankMarket.MarketType.BaseApp, c2, b);
        vm.stopPrank();

        _resolveSingleWinner(c1);

        vm.prank(owner);
        uint256 fee = market.collectFee(1, IBaseRankMarket.MarketType.BaseApp);

        vm.prank(user);
        uint256 userClaim = market.claimWinnings(1, IBaseRankMarket.MarketType.BaseApp);

        vm.prank(attacker);
        uint256 loserClaim = market.claimWinnings(1, IBaseRankMarket.MarketType.BaseApp);

        uint256 pool = a + b;
        assertEq(fee + userClaim + loserClaim, pool);
    }

    function testOpenMarketRevertsIfOpenTimeInPast() external {
        IBaseRankMarket.MarketConfig memory cfg;
        cfg.epochId = 7;
        cfg.marketType = IBaseRankMarket.MarketType.BaseApp;
        cfg.openTime = uint64(block.timestamp - 1);
        cfg.lockTime = uint64(block.timestamp + 1 days);
        cfg.resolveTime = uint64(block.timestamp + 2 days);
        cfg.feeBps = 100;
        cfg.metadataHash = keccak256("meta");
        cfg.candidateIds = _candidateSet();

        vm.prank(owner);
        vm.expectRevert();
        market.openMarket(cfg);
    }

    function testOpenMarketRevertsIfLockTimeNowOrPast() external {
        IBaseRankMarket.MarketConfig memory cfg;
        cfg.epochId = 8;
        cfg.marketType = IBaseRankMarket.MarketType.BaseApp;
        cfg.openTime = uint64(block.timestamp);
        cfg.lockTime = uint64(block.timestamp);
        cfg.resolveTime = uint64(block.timestamp + 1 days);
        cfg.feeBps = 100;
        cfg.metadataHash = keccak256("meta");
        cfg.candidateIds = _candidateSet();

        vm.prank(owner);
        vm.expectRevert();
        market.openMarket(cfg);
    }

    function testOpenMarketRevertsIfCandidatesGtMax() external {
        bytes32[] memory ids = new bytes32[](51);
        for (uint256 i; i < 51; ++i) {
            ids[i] = keccak256(abi.encodePacked("x", i));
        }

        IBaseRankMarket.MarketConfig memory cfg;
        cfg.epochId = 9;
        cfg.marketType = IBaseRankMarket.MarketType.BaseApp;
        cfg.openTime = uint64(block.timestamp + 60);
        cfg.lockTime = uint64(block.timestamp + 1 days);
        cfg.resolveTime = uint64(block.timestamp + 2 days);
        cfg.feeBps = 100;
        cfg.metadataHash = keccak256("meta");
        cfg.candidateIds = ids;

        vm.prank(owner);
        vm.expectRevert();
        market.openMarket(cfg);
    }

    function testOpenMarketRevertsIfCandidatesLtMin() external {
        bytes32[] memory ids = new bytes32[](14);
        for (uint256 i; i < 14; ++i) {
            ids[i] = keccak256(abi.encodePacked("x", i));
        }

        IBaseRankMarket.MarketConfig memory cfg;
        cfg.epochId = 10;
        cfg.marketType = IBaseRankMarket.MarketType.BaseApp;
        cfg.openTime = uint64(block.timestamp + 60);
        cfg.lockTime = uint64(block.timestamp + 1 days);
        cfg.resolveTime = uint64(block.timestamp + 2 days);
        cfg.feeBps = 100;
        cfg.metadataHash = keccak256("meta");
        cfg.candidateIds = ids;

        vm.prank(owner);
        vm.expectRevert();
        market.openMarket(cfg);
    }
}
