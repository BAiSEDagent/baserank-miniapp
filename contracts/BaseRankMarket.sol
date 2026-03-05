// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract BaseRankMarket is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant TOP10 = 1;
    uint8 public constant TOP5 = 2;
    uint8 public constant TOP1 = 3;
    uint16 public constant MAX_FEE_BPS = 500;
    uint256 public constant MIN_APPS_PER_MARKET = 15;
    uint256 public constant MAX_APPS_PER_MARKET = 50;

    enum MarketState {
        None,
        Open,
        Resolved
    }

    struct Market {
        MarketState state;
        uint64 closeTime;
        uint64 resolveTime;
        bytes32 snapshotHash;
        uint256 totalStake;
        uint256 totalWinningStake;
        uint256 feeAmount;
        uint32 appCount;
    }

    IERC20 public immutable usdc;
    address public feeRecipient;
    uint16 public feeBps;

    mapping(uint64 => mapping(uint8 => Market)) public markets;
    mapping(uint64 => mapping(uint8 => mapping(bytes32 => bool))) public isValidApp;
    mapping(uint64 => mapping(uint8 => bytes32[])) public appList;

    mapping(uint64 => mapping(uint8 => mapping(bytes32 => uint256))) public totalStakeByApp;
    mapping(uint64 => mapping(uint8 => mapping(address => mapping(bytes32 => uint256)))) public userStakeByApp;

    mapping(uint64 => mapping(uint8 => mapping(bytes32 => bool))) public isWinnerApp;
    mapping(uint64 => mapping(uint8 => bytes32[])) public winnerApps;
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public claimed;
    mapping(uint64 => mapping(uint8 => bool)) public feeCollected;

    event MarketCreated(uint64 indexed weekId, uint8 indexed tier, uint64 closeTime, uint64 resolveTime);
    event Staked(uint64 indexed weekId, uint8 indexed tier, bytes32 indexed appId, address user, uint256 amount);
    event MarketResolved(
        uint64 indexed weekId,
        uint8 indexed tier,
        bytes32 snapshotHash,
        uint256 winnerCount,
        uint256 totalWinningStake,
        uint256 feeAmount
    );
    event Claimed(uint64 indexed weekId, uint8 indexed tier, address indexed user, uint256 payout);
    event FeeCollected(uint64 indexed weekId, uint8 indexed tier, uint256 amount, address recipient);
    event FeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address recipient);

    error InvalidTier();
    error InvalidAddress();
    error InvalidFeeBps();
    error InvalidAppList();
    error DuplicateApp();
    error MarketAlreadyExists();
    error InvalidTime();
    error MarketNotOpen();
    error MarketNotResolved();
    error MarketNotReadyToResolve();
    error MarketAlreadyResolved();
    error BettingClosed();
    error InvalidApp();
    error InvalidAmount();
    error InvalidWinnerSet();
    error DuplicateWinner();
    error NoWinningStake();
    error AlreadyClaimed();
    error FeeAlreadyCollected();

    constructor(IERC20 _usdc, address _feeRecipient, uint16 _feeBps) Ownable(msg.sender) {
        if (address(_usdc) == address(0) || _feeRecipient == address(0)) revert InvalidAddress();
        if (_feeBps > MAX_FEE_BPS) revert InvalidFeeBps();
        usdc = _usdc;
        feeRecipient = _feeRecipient;
        feeBps = _feeBps;
    }

    function createMarket(
        uint64 weekId,
        uint8 tier,
        uint64 closeTime,
        uint64 resolveTime,
        bytes32[] calldata appIds
    ) external onlyOwner {
        _requireValidTier(tier);

        if (appIds.length < MIN_APPS_PER_MARKET || appIds.length > MAX_APPS_PER_MARKET) revert InvalidAppList();
        if (closeTime <= block.timestamp || resolveTime < closeTime) revert InvalidTime();

        Market storage market = markets[weekId][tier];
        if (market.state != MarketState.None) revert MarketAlreadyExists();

        uint256 len = appIds.length;
        for (uint256 i; i < len; ++i) {
            bytes32 appId = appIds[i];
            if (appId == bytes32(0)) revert InvalidAppList();
            if (isValidApp[weekId][tier][appId]) revert DuplicateApp();
            isValidApp[weekId][tier][appId] = true;
            appList[weekId][tier].push(appId);
        }

        market.state = MarketState.Open;
        market.closeTime = closeTime;
        market.resolveTime = resolveTime;
        market.appCount = uint32(len);

        emit MarketCreated(weekId, tier, closeTime, resolveTime);
    }

    function stake(uint64 weekId, uint8 tier, bytes32 appId, uint256 amount) external nonReentrant {
        _requireValidTier(tier);
        if (amount == 0) revert InvalidAmount();

        Market storage market = markets[weekId][tier];
        if (market.state != MarketState.Open) revert MarketNotOpen();
        if (block.timestamp >= market.closeTime) revert BettingClosed();
        if (!isValidApp[weekId][tier][appId]) revert InvalidApp();

        userStakeByApp[weekId][tier][msg.sender][appId] += amount;
        totalStakeByApp[weekId][tier][appId] += amount;
        market.totalStake += amount;

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(weekId, tier, appId, msg.sender, amount);
    }

    function resolveMarket(uint64 weekId, uint8 tier, bytes32[] calldata winningAppIds, bytes32 snapshotHash)
        external
        onlyOwner
    {
        _requireValidTier(tier);

        Market storage market = markets[weekId][tier];
        if (market.state == MarketState.None) revert MarketNotOpen();
        if (market.state == MarketState.Resolved) revert MarketAlreadyResolved();
        if (block.timestamp < market.resolveTime) revert MarketNotReadyToResolve();

        uint256 winnersLen = winningAppIds.length;
        uint256 maxWinners = _maxWinnersForTier(tier);
        if (winnersLen == 0 || winnersLen > maxWinners) revert InvalidWinnerSet();
        if (tier == TOP1 && winnersLen != 1) revert InvalidWinnerSet();

        uint256 winningStake;
        for (uint256 i; i < winnersLen; ++i) {
            bytes32 winner = winningAppIds[i];
            if (!isValidApp[weekId][tier][winner]) revert InvalidWinnerSet();

            for (uint256 j; j < i; ++j) {
                if (winningAppIds[j] == winner) revert DuplicateWinner();
            }

            isWinnerApp[weekId][tier][winner] = true;
            winnerApps[weekId][tier].push(winner);
            winningStake += totalStakeByApp[weekId][tier][winner];
        }

        if (winningStake == 0) revert NoWinningStake();

        uint256 fee = (market.totalStake * feeBps) / 10_000;

        market.state = MarketState.Resolved;
        market.snapshotHash = snapshotHash;
        market.totalWinningStake = winningStake;
        market.feeAmount = fee;

        emit MarketResolved(weekId, tier, snapshotHash, winnersLen, winningStake, fee);
    }

    function previewPayout(uint64 weekId, uint8 tier, address user) external view returns (uint256 payout) {
        _requireValidTier(tier);
        Market storage market = markets[weekId][tier];
        if (market.state != MarketState.Resolved) return 0;
        if (claimed[weekId][tier][user]) return 0;

        payout = _computePayout(weekId, tier, user, market);
    }

    function claimable(uint64 weekId, uint8 tier, address user) external view returns (uint256) {
        _requireValidTier(tier);
        Market storage market = markets[weekId][tier];
        if (market.state != MarketState.Resolved) return 0;
        if (claimed[weekId][tier][user]) return 0;
        return _computePayout(weekId, tier, user, market);
    }

    function claim(uint64 weekId, uint8 tier) external nonReentrant returns (uint256 payout) {
        _requireValidTier(tier);
        Market storage market = markets[weekId][tier];
        if (market.state != MarketState.Resolved) revert MarketNotResolved();
        if (claimed[weekId][tier][msg.sender]) revert AlreadyClaimed();

        claimed[weekId][tier][msg.sender] = true;
        payout = _computePayout(weekId, tier, msg.sender, market);

        if (payout > 0) {
            usdc.safeTransfer(msg.sender, payout);
        }

        emit Claimed(weekId, tier, msg.sender, payout);
    }

    function collectFee(uint64 weekId, uint8 tier) external onlyOwner nonReentrant returns (uint256 amount) {
        _requireValidTier(tier);
        Market storage market = markets[weekId][tier];
        if (market.state != MarketState.Resolved) revert MarketNotResolved();
        if (feeCollected[weekId][tier]) revert FeeAlreadyCollected();

        feeCollected[weekId][tier] = true;
        amount = market.feeAmount;
        if (amount > 0) usdc.safeTransfer(feeRecipient, amount);

        emit FeeCollected(weekId, tier, amount, feeRecipient);
    }

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFeeBps();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function _computePayout(uint64 weekId, uint8 tier, address user, Market storage market)
        internal
        view
        returns (uint256 payout)
    {
        bytes32[] storage winners = winnerApps[weekId][tier];
        uint256 len = winners.length;

        uint256 userWinningStake;
        for (uint256 i; i < len; ++i) {
            userWinningStake += userStakeByApp[weekId][tier][user][winners[i]];
        }

        if (userWinningStake == 0) return 0;

        uint256 distributable = market.totalStake - market.feeAmount;
        payout = (userWinningStake * distributable) / market.totalWinningStake;
    }

    function _requireValidTier(uint8 tier) internal pure {
        if (tier < TOP10 || tier > TOP1) revert InvalidTier();
    }

    function _maxWinnersForTier(uint8 tier) internal pure returns (uint256) {
        if (tier == TOP10) return 10;
        if (tier == TOP5) return 5;
        if (tier == TOP1) return 1;
        revert InvalidTier();
    }
}
