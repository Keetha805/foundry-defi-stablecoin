//SPDX-License-Identifier : MIT

pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    // tokenAddresses, priceFeedsAddresses, dscAddress
    struct NetworkConfig {
        address weth;
        address wbtc;
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 10000e8;
    uint256 public DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaNetworkConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilNetworkConfig();
        }
    }

    function getSepoliaNetworkConfig() public view returns (NetworkConfig memory) {
        NetworkConfig memory networkConfig = NetworkConfig({
            weth: 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9,
            wbtc: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599,
            wethUsdPriceFeed: 0xD4a33860578De61DBAbDc8BFdb98FD742fA7028e,
            wbtcUsdPriceFeed: 0xA39434A63A52E749F02807ae27335515BA4b07F7,
            deployerKey: uint256(uint160(vm.envUint("PRIVATE_KEY")))
        });
        return networkConfig;
    }

    function getOrCreateAnvilNetworkConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.weth != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();

        ERC20Mock weth = new ERC20Mock();
        ERC20Mock wbtc = new ERC20Mock();
        MockV3Aggregator wethPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        MockV3Aggregator wbtcPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);
        vm.stopBroadcast();

        NetworkConfig memory networkConfig = NetworkConfig({
            weth: address(weth),
            wbtc: address(wbtc),
            wethUsdPriceFeed: address(wethPriceFeed),
            wbtcUsdPriceFeed: address(wbtcPriceFeed),
            deployerKey: DEFAULT_ANVIL_KEY
        });
        return networkConfig;
    }
}
