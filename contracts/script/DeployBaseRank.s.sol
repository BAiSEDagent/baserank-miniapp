// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {BaseRankMarket} from "../src/BaseRankMarket.sol";

contract DeployBaseRank is Script {
    function run() external returns (BaseRankMarket deployed) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("MARKET_OWNER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address usdc = vm.envAddress("USDC_ADDRESS");

        vm.startBroadcast(pk);
        deployed = new BaseRankMarket(usdc, owner, feeRecipient);
        vm.stopBroadcast();
    }
}
