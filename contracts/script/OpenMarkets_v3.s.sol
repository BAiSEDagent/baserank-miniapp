// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

interface IBaseRankMarket {
    enum MarketType { BaseApp, BaseChain }
    function openMarket(
        uint64 epochId,
        MarketType marketType,
        bytes32[] calldata candidateIds,
        uint64 openTime,
        uint64 lockTime,
        uint64 resolveTime,
        uint16 feeBps
    ) external;
}

contract OpenMarkets is Script {
    function run() external {
        // Epoch 20260307 — expanded candidate set (47 apps from both leaderboards)
        uint64 epochId = 20260307;
        
        // Timing: open now + 5 min, lock in 6 days, resolve in 7 days
        uint64 openTime  = uint64(block.timestamp + 5 minutes);
        uint64 lockTime   = openTime + 6 days;
        uint64 resolveTime = lockTime + 1 days;
        uint16 feeBps = 200; // 2%
        
        string[47] memory apps = [
            "Base App","Planet IX","Clash of Coins","o1.exchange","Ethos",
            "Virtuals","Avantis","Rips","PancakeSwap","Sigma",
            "Moonwell","OnChainGM","Arbase GM","Fruitling Valley","Hydrex",
            "Sport.Fun","MaestroBots","Limitless Exchange","Arbase Clicker","Scored - Neynar & all scores",
            "Crenel","BaseHub","Bracky","BETRMINT","Aerodrome",
            "Celebration Hub","Definitive Finance","Legend of Base","Arcadia Finance","PredictBase",
            "$QR","Pixotchi Mini","Base Me","Morpho","Rise of Farms",
            "Wasabi","DropCast","Symbiosis","Astroblock","Golden Pirate Base",
            "Framedl","Airdrop","Alchemy","Bankr Swap","Megapot",
            "Venice.ai","Mamo"
        ];
        
        IBaseRankMarket market = IBaseRankMarket(0xC7Db05C3c99Bb8f30477F93d7f0831567135A363);
        
        // --- BaseApp market (type 0) ---
        bytes32[] memory appCandidates = new bytes32[](47);
        for (uint i = 0; i < 47; i++) {
            appCandidates[i] = keccak256(abi.encodePacked(string(abi.encodePacked("app:", apps[i]))));
        }
        
        vm.startBroadcast();
        market.openMarket(epochId, IBaseRankMarket.MarketType.BaseApp, appCandidates, openTime, lockTime, resolveTime, feeBps);
        vm.stopBroadcast();
        
        // --- BaseChain market (type 1) ---
        bytes32[] memory chainCandidates = new bytes32[](47);
        for (uint i = 0; i < 47; i++) {
            chainCandidates[i] = keccak256(abi.encodePacked(string(abi.encodePacked("coin:", apps[i]))));
        }
        
        vm.startBroadcast();
        market.openMarket(epochId, IBaseRankMarket.MarketType.BaseChain, chainCandidates, openTime, lockTime, resolveTime, feeBps);
        vm.stopBroadcast();
    }
}
