// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BaseRankMarketV2} from "../src/BaseRankMarketV2.sol";

contract DeployV2 is Script {
    function run() external returns (BaseRankMarketV2 deployed) {
        // Base Mainnet USDC
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        // Safe multisig as owner
        address owner = 0xd9E4841b85ba0D6b2dC71fD12478190279e0172a;
        // Fee recipient = Safe
        address feeRecipient = 0xd9E4841b85ba0D6b2dC71fD12478190279e0172a;

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(pk);
        deployed = new BaseRankMarketV2(usdc, owner, feeRecipient);
        vm.stopBroadcast();

        console.log("BaseRankMarketV2 deployed at:", address(deployed));
    }
}
