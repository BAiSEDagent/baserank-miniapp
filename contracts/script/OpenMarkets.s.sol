// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {BaseRankMarket, IBaseRankMarket} from "../src/BaseRankMarket.sol";

contract OpenMarkets is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address market = vm.envAddress("MARKET_ADDRESS");

        // Candidate IDs: keccak256(abi.encodePacked("app:<name>"))
        bytes32[] memory appCandidates = new bytes32[](10);
        appCandidates[0] = keccak256(abi.encodePacked("app:Planet IX"));
        appCandidates[1] = keccak256(abi.encodePacked("app:Clash of Coins"));
        appCandidates[2] = keccak256(abi.encodePacked("app:Rips"));
        appCandidates[3] = keccak256(abi.encodePacked("app:Arbase GM"));
        appCandidates[4] = keccak256(abi.encodePacked("app:Avantis"));
        appCandidates[5] = keccak256(abi.encodePacked("app:Arbase Clicker"));
        appCandidates[6] = keccak256(abi.encodePacked("app:Aerodrome"));
        appCandidates[7] = keccak256(abi.encodePacked("app:Legend of Base"));
        appCandidates[8] = keccak256(abi.encodePacked("app:$QR"));
        appCandidates[9] = keccak256(abi.encodePacked("app:Pixotchi Mini"));

        // coin market uses same candidates prefixed with "coin:"
        bytes32[] memory coinCandidates = new bytes32[](10);
        coinCandidates[0] = keccak256(abi.encodePacked("coin:Planet IX"));
        coinCandidates[1] = keccak256(abi.encodePacked("coin:Clash of Coins"));
        coinCandidates[2] = keccak256(abi.encodePacked("coin:Rips"));
        coinCandidates[3] = keccak256(abi.encodePacked("coin:Arbase GM"));
        coinCandidates[4] = keccak256(abi.encodePacked("coin:Avantis"));
        coinCandidates[5] = keccak256(abi.encodePacked("coin:Arbase Clicker"));
        coinCandidates[6] = keccak256(abi.encodePacked("coin:Aerodrome"));
        coinCandidates[7] = keccak256(abi.encodePacked("coin:Legend of Base"));
        coinCandidates[8] = keccak256(abi.encodePacked("coin:$QR"));
        coinCandidates[9] = keccak256(abi.encodePacked("coin:Pixotchi Mini"));

        uint64 epochId = 20260306;
        uint64 openTime = uint64(block.timestamp);
        uint64 lockTime = uint64(block.timestamp + 6 days);
        uint64 resolveTime = uint64(block.timestamp + 7 days);
        uint16 feeBps = 200; // 2%

        vm.startBroadcast(pk);

        IBaseRankMarket(market).openMarket(IBaseRankMarket.MarketConfig({
            epochId: epochId,
            marketType: IBaseRankMarket.MarketType.BaseApp,
            openTime: openTime,
            lockTime: lockTime,
            resolveTime: resolveTime,
            feeBps: feeBps,
            candidateIds: appCandidates,
            metadataHash: bytes32(0)
        }));

        IBaseRankMarket(market).openMarket(IBaseRankMarket.MarketConfig({
            epochId: epochId,
            marketType: IBaseRankMarket.MarketType.BaseChain,
            openTime: openTime,
            lockTime: lockTime,
            resolveTime: resolveTime,
            feeBps: feeBps,
            candidateIds: coinCandidates,
            metadataHash: bytes32(0)
        }));

        vm.stopBroadcast();
    }
}
