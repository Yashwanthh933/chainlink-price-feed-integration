//SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {TeaShop} from "../src/TeaShop.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract DeployTeaShop is Script {
    TeaShop private teaShop;

    function run() public returns (TeaShop) {
        HelperConfig helperConfig = new HelperConfig();
        address priceFeed = helperConfig.activeNetworkConfig();
        vm.startBroadcast();
        teaShop = new TeaShop(priceFeed);
        vm.stopBroadcast();
        return teaShop;
    }
}
