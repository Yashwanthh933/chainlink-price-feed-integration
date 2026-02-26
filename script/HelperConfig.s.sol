// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

/// @title HelperConfig
/// @author Yashh
/// @notice Deployment configuration script that provides the correct Chainlink price feed
///         address for each supported network
/// @dev Follows the HelperConfig pattern to keep deployment scripts network-agnostic.
///      The deployer never hardcodes a price feed address — it always asks HelperConfig.
///
///      Supported networks:
///        Anvil (31337)          → deploys a MockV3Aggregator ($2000 ETH, 8 dec)
///        Sepolia (11155111)     → Chainlink ETH/USD testnet feed
///        Arbitrum Sepolia (421614) → Chainlink ETH/USD Arbitrum testnet feed
///        Mainnet (1)            → Chainlink ETH/USD mainnet feed
///
///      Adding a new network:
///        1. Add an else-if branch in the constructor for the new chainid
///        2. Add an internal getter function returning the NetworkConfig with the feed address
contract HelperConfig is Script {

    /// @notice Thrown when the contract is deployed on an unsupported chain
    error HelperConfig_InvalidChainId();

    /// @notice Holds the Chainlink price feed address for the active network
    struct NetworkConfig {
        address priceFeed;
    }

    /// @notice The resolved config for the network this script is running on
    /// @dev Set once in the constructor and read by deployment scripts
    NetworkConfig public activeNetworkConfig;

    /// @notice Resolves the correct price feed config based on block.chainid
    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 421614) {
            activeNetworkConfig = getArbitrumSepConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getMainnetConfig();
        } else if (block.chainid == 31337) {
            activeNetworkConfig = getAnvilEthConfig();
        } else {
            revert HelperConfig_InvalidChainId();
        }
    }

    /// @notice Returns the Chainlink ETH/USD feed config for Sepolia testnet
    /// @return NetworkConfig with Sepolia ETH/USD feed address
    function getSepoliaEthConfig() internal pure returns (NetworkConfig memory) {
        return NetworkConfig({priceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306});
    }

    /// @notice Returns the Chainlink ETH/USD feed config for Arbitrum Sepolia testnet
    /// @return NetworkConfig with Arbitrum Sepolia ETH/USD feed address
    function getArbitrumSepConfig() internal pure returns (NetworkConfig memory) {
        return NetworkConfig({priceFeed: 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165});
    }

    /// @notice Returns the Chainlink ETH/USD feed config for Ethereum mainnet
    /// @return NetworkConfig with mainnet ETH/USD feed address
    function getMainnetConfig() internal pure returns (NetworkConfig memory) {
        return NetworkConfig({priceFeed: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419});
    }

    /// @notice Deploys a MockV3Aggregator for local Anvil testing and returns its config
    /// @dev Returns the existing config if already deployed (prevents re-deployment across
    ///      multiple HelperConfig instantiations in the same test run).
    ///      Mock is initialized at $2000 ETH price with 8 decimal precision.
    /// @return NetworkConfig with the deployed mock feed address
    function getAnvilEthConfig() internal returns (NetworkConfig memory) {
        // return existing config if mock was already deployed
        if (activeNetworkConfig.priceFeed != address(0)) {
            return activeNetworkConfig;
        }
        vm.startBroadcast();
        MockV3Aggregator mockPriceFeed = new MockV3Aggregator(8, 2000e8);
        vm.stopBroadcast();
        return NetworkConfig({priceFeed: address(mockPriceFeed)});
    }
}
