// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {BaseRankMarket, IBaseRankMarket} from "../src/BaseRankMarket.sol";

/// @notice Opens BaseApp and BaseChain markets for a given epoch.
/// @dev Requires execution from the contract owner (Safe multisig).
///      candidateIds must be 15–50 per contract invariant (MIN_CANDIDATES=15, MAX_CANDIDATES=50).
///      openTime must be strictly in the future at execution block time.
contract OpenMarkets is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address market = vm.envAddress("MARKET_ADDRESS");

        // 20 candidates from live leaderboard — satisfies MIN_CANDIDATES=15, MAX_CANDIDATES=50
        bytes32[] memory appCandidates = new bytes32[](20);
        appCandidates[0]  = keccak256(abi.encodePacked("app:Planet IX"));
        appCandidates[1]  = keccak256(abi.encodePacked("app:Clash of Coins"));
        appCandidates[2]  = keccak256(abi.encodePacked("app:Rips"));
        appCandidates[3]  = keccak256(abi.encodePacked("app:Arbase GM"));
        appCandidates[4]  = keccak256(abi.encodePacked("app:Avantis"));
        appCandidates[5]  = keccak256(abi.encodePacked("app:Arbase Clicker"));
        appCandidates[6]  = keccak256(abi.encodePacked("app:Aerodrome"));
        appCandidates[7]  = keccak256(abi.encodePacked("app:Legend of Base"));
        appCandidates[8]  = keccak256(abi.encodePacked("app:$QR"));
        appCandidates[9]  = keccak256(abi.encodePacked("app:Pixotchi Mini"));
        appCandidates[10] = keccak256(abi.encodePacked("app:BETRMINT"));
        appCandidates[11] = keccak256(abi.encodePacked("app:Base Me"));
        appCandidates[12] = keccak256(abi.encodePacked("app:Hydrex"));
        appCandidates[13] = keccak256(abi.encodePacked("app:Morpho"));
        appCandidates[14] = keccak256(abi.encodePacked("app:Rise of Farms"));
        appCandidates[15] = keccak256(abi.encodePacked("app:Wasabi"));
        appCandidates[16] = keccak256(abi.encodePacked("app:BaseHub"));
        appCandidates[17] = keccak256(abi.encodePacked("app:Moonwell"));
        appCandidates[18] = keccak256(abi.encodePacked("app:DropCast"));
        appCandidates[19] = keccak256(abi.encodePacked("app:Virtuals"));

        bytes32[] memory coinCandidates = new bytes32[](20);
        coinCandidates[0]  = keccak256(abi.encodePacked("coin:Planet IX"));
        coinCandidates[1]  = keccak256(abi.encodePacked("coin:Clash of Coins"));
        coinCandidates[2]  = keccak256(abi.encodePacked("coin:Rips"));
        coinCandidates[3]  = keccak256(abi.encodePacked("coin:Arbase GM"));
        coinCandidates[4]  = keccak256(abi.encodePacked("coin:Avantis"));
        coinCandidates[5]  = keccak256(abi.encodePacked("coin:Arbase Clicker"));
        coinCandidates[6]  = keccak256(abi.encodePacked("coin:Aerodrome"));
        coinCandidates[7]  = keccak256(abi.encodePacked("coin:Legend of Base"));
        coinCandidates[8]  = keccak256(abi.encodePacked("coin:$QR"));
        coinCandidates[9]  = keccak256(abi.encodePacked("coin:Pixotchi Mini"));
        coinCandidates[10] = keccak256(abi.encodePacked("coin:BETRMINT"));
        coinCandidates[11] = keccak256(abi.encodePacked("coin:Base Me"));
        coinCandidates[12] = keccak256(abi.encodePacked("coin:Hydrex"));
        coinCandidates[13] = keccak256(abi.encodePacked("coin:Morpho"));
        coinCandidates[14] = keccak256(abi.encodePacked("coin:Rise of Farms"));
        coinCandidates[15] = keccak256(abi.encodePacked("coin:Wasabi"));
        coinCandidates[16] = keccak256(abi.encodePacked("coin:BaseHub"));
        coinCandidates[17] = keccak256(abi.encodePacked("coin:Moonwell"));
        coinCandidates[18] = keccak256(abi.encodePacked("coin:DropCast"));
        coinCandidates[19] = keccak256(abi.encodePacked("coin:Virtuals"));

        uint64 epochId = 20260306;
        // +30 min buffer: guarantees openTime > block.timestamp even under network congestion
        uint64 openTime    = uint64(block.timestamp + 30 minutes);
        uint64 lockTime    = uint64(openTime + 6 days);
        uint64 resolveTime = uint64(lockTime + 1 days);
        uint16 feeBps      = 200; // 2%

        vm.startBroadcast(pk);

        IBaseRankMarket(market).openMarket(IBaseRankMarket.MarketConfig({
            epochId:       epochId,
            marketType:    IBaseRankMarket.MarketType.BaseApp,
            openTime:      openTime,
            lockTime:      lockTime,
            resolveTime:   resolveTime,
            feeBps:        feeBps,
            candidateIds:  appCandidates,
            metadataHash:  bytes32(0)
        }));

        IBaseRankMarket(market).openMarket(IBaseRankMarket.MarketConfig({
            epochId:       epochId,
            marketType:    IBaseRankMarket.MarketType.BaseChain,
            openTime:      openTime,
            lockTime:      lockTime,
            resolveTime:   resolveTime,
            feeBps:        feeBps,
            candidateIds:  coinCandidates,
            metadataHash:  bytes32(0)
        }));

        vm.stopBroadcast();
    }
}
