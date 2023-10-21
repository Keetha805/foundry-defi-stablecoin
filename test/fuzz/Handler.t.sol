//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

//Its also very important to include contracts that our contract interacts with:
//Price feeds
//weth token
//wbtc token
//We are gonna go with price feed, as ppl can manipulate it, and that would totally affect us

import {MockV3Aggregator} from "../mocks/MockV3Aggregator.t.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    MockV3Aggregator wethPriceFeed;
    MockV3Aggregator wbtcPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    uint256 public mintedTimes = 0;
    address[] public users;

    constructor(DSCEngine _dsceEngine, DecentralizedStableCoin _dsc) {
        dsce = _dsceEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        wethPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
        wbtcPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(wbtc)));
    }

    //If prices fall, our protocol fails
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     wethPriceFeed.updateAnswer(newPriceInt);
    // }

    //redeemCollateral

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        users.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxAmountCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));
        if (maxAmountCollateralToRedeem == 0) {
            return;
        }
        amountCollateral = bound(amountCollateral, 0, maxAmountCollateralToRedeem);
        dsce.redeemCollateral(address(collateral), maxAmountCollateralToRedeem);
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (users.length == 0) {
            return;
        }
        address sender = users[addressSeed % users.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
        uint256 MAX_AMOUNT_TO_MINT = (collateralValueInUsd / 2) - (totalDscMinted);
        amount = bound(amount, 0, uint256(MAX_AMOUNT_TO_MINT));
        if (amount == 0) {
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        mintedTimes++;
    }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
