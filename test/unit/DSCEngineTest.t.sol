//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.t.sol";

contract DSCEngineTest is Test {
    HelperConfig config;
    DeployDSCEngine deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;

    address weth;
    address wbtc;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    uint256 deployerKey;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 1 ether;
    uint256 public constant AMOUNT_DSC = 1000 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    int256 public constant NEW_ETH_USD_PRICE_FEED = 1000e8;

    modifier approvedWeth() {
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        _;
    }

    modifier approvedDsc() {
        vm.prank(USER);
        dsc.approve(address(dsce), AMOUNT_DSC);
        _;
    }

    modifier depositedCollateral() {
        vm.prank(USER);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        _;
    }

    modifier mint() {
        vm.prank(USER);
        dsce.mintDsc(AMOUNT_DSC);
        _;
    }

    function setUp() public {
        DeployDSCEngine deploy = new DeployDSCEngine();
        (dsc, dsce, config) = deploy.run();
        (weth, wbtc, wethUsdPriceFeed, wbtcUsdPriceFeed, deployerKey) = config.activeNetworkConfig();
        vm.prank(USER);
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        vm.prank(LIQUIDATOR);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
    }

    //////////////////////////
    /////Constructor Tests//////
    //////////////////////////
    address[] tokenAddresses;
    address[] priceFeedsAddresses;

    function testRevertsIfTokenLengthsDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        priceFeedsAddresses.push(wethUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLenght.selector);
        new DSCEngine(tokenAddresses, priceFeedsAddresses, address(dsc));
    }

    //////////////////////////
    /////Price Tests//////
    //////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;

        uint256 ethPrice = uint256(config.ETH_USD_PRICE()) * 1e10; // total: 1e18
        uint256 expectedEthUsdValue = (ethAmount * ethPrice) / 1e18; // we should hardcode this tho
        uint256 returnedEthUsdValue = dsce.getUsdValue(weth, ethAmount);

        assertEq(returnedEthUsdValue, expectedEthUsdValue);
    }

    function testGetTokenAmountCorrectly() public {
        // 2000$ / ETH, 100$  => 100/2000 = 0.05 ETH
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;

        uint256 actualWeth = dsce.getTokenAmounFromUsd(weth, usdAmount);

        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////
    /////depositCollateral Tests//////
    ///////////////////////

    function testRevertIfCollateralZero() public {
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
    }

    function testRevertIfTokenNotAllowed() public {
        ERC20Mock random = new ERC20Mock();

        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(random), AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralAndGetAccountInfo() public approvedWeth depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 expectedDepositAmount = dsce.getTokenAmounFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(collateralValueInUsd, expectedCollateralValueUsd);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    function testEmitsEvent() public approvedWeth {
        vm.startPrank(USER);
        vm.expectEmit(true, true, true, false);
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertIfTransferFails() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
    }

    ///////////////////////
    /////mintDsc Tests//////
    ///////////////////////

    function testCanMintDsc() public approvedWeth depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(AMOUNT_DSC);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedCollateral = dsce.getTokenAmounFromUsd(weth, collateralValueInUsd);
        assertEq(AMOUNT_DSC, totalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedCollateral);
    }

    function testMintRevertsAmountZero() public {
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        vm.prank(USER);
        dsce.mintDsc(0);
    }

    function testMintRevertsIfItBrokesHealthFactor() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 0));
        dsce.mintDsc(AMOUNT_DSC);
    }

    ///////////////////////
    /////depositCollateralAndMintDsc Tests//////
    ///////////////////////

    function testDepositAndMintCorrectly() public approvedWeth {
        (uint256 startingDscMinted, uint256 startingCollateralInUsd) = dsce.getAccountInformation(USER);
        vm.prank(USER);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC);
        (uint256 endingDscMinted, uint256 endingCollateralInUsd) = dsce.getAccountInformation(USER);

        uint256 endingWethAmount = dsce.getTokenAmounFromUsd(weth, endingCollateralInUsd);

        assertEq(startingDscMinted, 0);
        assertEq(startingCollateralInUsd, 0);

        assertEq(endingDscMinted, AMOUNT_DSC);
        assertEq(endingWethAmount, AMOUNT_COLLATERAL);
    }

    function testDepositAndMintFailsIfBrokenHealthFactor() public approvedWeth {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 0)); // This would be 0.5 but solidity doesnt handle decimals
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC * 2);
    }

    ///////////////////////
    /////redeemCollateral Tests//////
    ///////////////////////

    function testRevertsIfRedeemedCollateralIsZero() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.redeemCollateral(weth, 0);
    }

    function testRevertsIfRedeemedTokenIsntAllowed() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.redeemCollateral(address(ranToken), AMOUNT_COLLATERAL);
    }

    function testCanRedeemCollateral() public approvedWeth depositedCollateral {
        uint256 startingBalance = ERC20Mock(weth).balanceOf(USER);
        vm.prank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 endingBalance = ERC20Mock(weth).balanceOf(USER);

        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, 0);
        assertEq(endingBalance, startingBalance + AMOUNT_COLLATERAL);
    }

    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    function testRedeemCollateralEmitsEvent() public approvedWeth depositedCollateral {
        vm.prank(USER);
        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
    }

    function testRedeemRevertsIfItBreaksHealthFactor() public approvedWeth depositedCollateral mint {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 0));
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
    }

    ///////////////////////
    /////burnDsc Tests//////
    ///////////////////////

    function testRevertsIfBurnIsZero() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.burnDsc(0);
    }

    function testRevertsIfExceededBurnAmount() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(AMOUNT_DSC);
    }

    function testCanBurnCorrectly() public approvedWeth depositedCollateral mint approvedDsc {
        (uint256 startingMinted,) = dsce.getAccountInformation(USER);

        vm.prank(USER);
        dsce.burnDsc(startingMinted);

        (uint256 endingMinted, uint256 endingUsd) = dsce.getAccountInformation(USER);
        uint256 endingToken = dsce.getTokenAmounFromUsd(weth, endingUsd);

        assertEq(endingMinted, 0);
        assertEq(endingToken, AMOUNT_COLLATERAL);
    }

    ///////////////////////
    /////redeeemCollateralForDsc Tests//////
    ///////////////////////

    function testRedeemCollateralForDscCorrectly() public approvedWeth approvedDsc {
        vm.startPrank(USER);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC);
        uint256 startingBalance = ERC20Mock(weth).balanceOf(USER);
        (uint256 startingDsc,) = dsce.getAccountInformation(USER);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC);
        vm.stopPrank();

        (uint256 endingDsc, uint256 endingUsd) = dsce.getAccountInformation(USER);
        uint256 endingBalance = ERC20Mock(weth).balanceOf(USER);

        assert(startingDsc > endingDsc);
        assertEq(endingUsd, 0);
        assertEq(endingDsc, 0);
        assertEq(endingBalance, startingBalance + AMOUNT_COLLATERAL);
    }

    function testRedeeemCollateralForDscRevertsIfBrokeHealthFactor() public approvedWeth approvedDsc {
        vm.startPrank(USER);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 0)); // This would be 0.5 but solidity doesnt handle decimals
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC / 2);
        vm.stopPrank();
    }

    ///////////////////////
    /////liquidate Tests//////
    ///////////////////////

    function testLiquidateRevertsIfZero() public {
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.liquidate(weth, USER, 0);
    }

    function testLiquidateRevertsIfNotAllowed() public {
        ERC20Mock randomToken = new ERC20Mock();
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.liquidate(address(randomToken), USER, AMOUNT_DSC);
    }

    function testLiquidateRevertsIfUserIsInvalid() public approvedWeth depositedCollateral mint {
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__AddressZeroNotAllowed.selector);
        dsce.liquidate(weth, address(0), AMOUNT_DSC);
    }

    function testLiquidateRevertsIfNotBrokenHealtFactor() public approvedWeth depositedCollateral mint {
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, AMOUNT_DSC);
    }

    function testLiquidateRevertsIfTooMuchDebt() public approvedWeth depositedCollateral mint {
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(NEW_ETH_USD_PRICE_FEED);
        vm.prank(LIQUIDATOR);
        vm.expectRevert();
        dsce.liquidate(weth, USER, AMOUNT_DSC * 2);
    }

    function testLiquidateRevertsIfLiquidatorHealthFactorBrokes()
        public
        approvedWeth
        approvedDsc
        depositedCollateral
        mint
    {
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsc.approve(address(dsce), AMOUNT_DSC);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(AMOUNT_DSC);

        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(NEW_ETH_USD_PRICE_FEED);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 0));
        dsce.liquidate(weth, USER, AMOUNT_DSC);

        vm.stopPrank();
    }

    // function testCanLiquidateCorrectly() public approvedWeth depositedCollateral mint {
    //     vm.startPrank(LIQUIDATOR);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL * 2);
    //     dsc.approve(address(dsce), AMOUNT_DSC);
    //     dsce.depositCollateral(weth, AMOUNT_COLLATERAL * 2);
    //     dsce.mintDsc(AMOUNT_DSC);

    //     MockV3Aggregator(wethUsdPriceFeed).updateAnswer(NEW_ETH_USD_PRICE_FEED);

    //     (uint256 startingDscMintedUser,) = dsce.getAccountInformation(USER);

    //     dsce.liquidate(weth, USER, startingDscMintedUser);

    //     vm.stopPrank();

    //     (uint256 endingDscMintedLiq,) = dsce.getAccountInformation(LIQUIDATOR);
    //     (uint256 endingDscMintedUser, uint256 endingCollateralUser) = dsce.getAccountInformation(USER);

    //     assertEq(endingDscMintedUser, 0);
    //     assertEq(endingDscMintedLiq, 0);
    //     assertEq(endingCollateralUser, 0);
    // }
}
