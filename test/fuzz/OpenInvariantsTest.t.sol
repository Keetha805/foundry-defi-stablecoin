//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;

    address weth;
    address wbtc;

    function setUp() external {
        DeployDSCEngine deployDSCE = new DeployDSCEngine();
        (dsc, dsce, config) = deployDSCE.run();
        (weth, wbtc,,,) = config.activeNetworkConfig();
        targetContract(address(dsce));
    }

    function invariant_SecondaryprotocolMustHaveMoreValueThanTotalSupply() public view {
        // get value of ALL collateral
        //compare it to all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);
        uint256 totalUsdValue = wethValue + wbtcValue;

        console.log("wethValue: ", wethValue);
        console.log("wbtcValue: ", wbtcValue);
        console.log("totalUsdValue: ", totalUsdValue);

        assert(totalSupply <= totalUsdValue);
    }
}
