// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {console} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
/**
 *
 * @title DSCEngine
 * @author Keetha
 * The system is design to be as minimal as possible,
 * and have the tokens maintain a 1 token == $1 peg
 * This stableCoin has the properties:
 *  - Exogenous Collateral
 *  - Dollar Pegged
 *  - Algorithmically Stable
 *
 * Our DSC System should always be "overcollateralized".
 * At no point, should the value of all collateral <= the $ backed value of all DSC.
 *
 * Similar to DAI if DAI had no governance, no fees, only backed by WETH and WBTC
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for
 * mining and redeeming DSC, as well as depositing & withdrawing collateral
 * @notice This contract is VERY loosely based on the MarkerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    ///////////////////////
    ///////Errors/////////
    //////////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLenght();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__RedeemCollateralFailed();
    error DSCEngine__AddressZeroNotAllowed();
    error DSCEngine__NotEnoughAmount();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////////
    ///////Types/////////
    //////////////////

    using OracleLib for AggregatorV3Interface;
    ///////////////////////
    ///////State Variables/////////
    //////////////////
    // mapping(address => bool) private s_tokenToAllowed;//We could do this but Patrick knows we are gonna use priceFeeds so:

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_TRESHOLD = 50; //200% over
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    uint256 private constant LIQUIDATION_BONUS = 10;

    DecentralizedStableCoin private i_dsc;

    ///////////////////////
    /////Events/////////
    ///////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    ///////////////////////
    /////Modifiers/////////
    ///////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////////////
    /////Functions/////////
    ///////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedsAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedsAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLenght();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedsAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////////
    /////External Functions//////
    ////////////////////////////

    /**
     *
     * @param tokenCollateralAddress The address of token to deposit collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of Dsc to mint
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI (Check / Effects / Interactions)
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    //Health factor must be 1 after pull collateral
    //DRY: Dont repeat Yourself
    /**
     *
     * @param tokenCollateral Token to redeem collateral
     * @param amountCollateral Amount to redeem
     */
    function redeemCollateral(address tokenCollateral, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateral, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param tokenCollateral collateral address to redeem
     * @param amountCollateral amount of collateral to redeem
     * @param amountToBurn  amount of DSC to burn
     */
    function redeemCollateralForDsc(address tokenCollateral, uint256 amountCollateral, uint256 amountToBurn)
        external
        moreThanZero(amountCollateral)
    {
        burnDsc(amountToBurn);
        redeemCollateral(tokenCollateral, amountCollateral);
        //redeem already checks healthFactor
    }

    /**
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum treshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountToBurn) public moreThanZero(amountToBurn) nonReentrant {
        _burnDsc(amountToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //I don't think this would ever hit...
    }

    //if someone is almost undercollateralized, we will pay you to liquidate them
    /**
     *
     * @param collateral ERC 20 collateral To Liquidate
     * @param user User to liquidate. The one who broke health factor
     * @param debtToCover Amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate
     * @notice You  will get bonus for taking users funds
     * @notice This function working assumes the protocol will be rougly 200% overcollateralized´
     * @notice Known bug: If collateral is or is less than 100%, we wouldnt be able to incentivize liquidators
     *
     * Follows CEI
     */

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        isAllowedToken(collateral)
        nonReentrant
    {
        //Checks
        if (user == address(0)) {
            revert DSCEngine__AddressZeroNotAllowed();
        }

        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        if (s_DSCMinted[user] - debtToCover < 0) {
            revert DSCEngine__NotEnoughAmount();
        }

        //Effects
        uint256 tokenAmountFromDebtCovered = getTokenAmounFromUsd(collateral, debtToCover);
        //10% bonus
        uint256 bonusCollateral = tokenAmountFromDebtCovered * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;
        //Interactions
        _burnDsc(debtToCover, user, msg.sender);
        if (s_collateralDeposited[user][collateral] < tokenAmountFromDebtCovered + bonusCollateral) {
            _redeemCollateral(collateral, tokenAmountFromDebtCovered, user, msg.sender); // collateral is weth or wbtc, debtToCover is USD, so we cannot say gimme 50 ETH, but 0.00...ETH, thats why we have to do the conversion
        } else {
            _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender); // collateral is weth or wbtc, debtToCover is USD, so we cannot say gimme 50 ETH, but 0.00...ETH, thats why we have to do the conversion
        }
        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingHealthFactor) {
            // functions below, are low level, we need to make this one safe
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender); // if the process brokes the liquidator health factor, we revert
    }

    /////////////////////////////
    /////Private/Internal View Functions//////
    ////////////////////////////

    /**
     * @dev Low level function, the function calling it MUST be safe
     */
    function _burnDsc(uint256 amountToBurn, address onBehalfOf, address dscFrom) internal {
        s_DSCMinted[onBehalfOf] -= amountToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountToBurn);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        //total DSC minted
        //total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted != 0) {
            uint256 collateralAdjustedForTreshold =
                (collateralValueInUsd * LIQUIDATION_TRESHOLD) / LIQUIDATION_PRECISION;
            return collateralAdjustedForTreshold / totalDscMinted;
        } else {
            return type(uint256).max;
        }
    }

    /**
     * @notice follows CEI (Check / Effects / Interactions)
     * @param user The address of the user to check
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreakHealthFactor(healthFactor);
        }
    }

    /**
     * @dev  Low level function, the function calling it MUST be safe
     */
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral; //We trust on the compiler to revert if FROM doesnt have that much collateral
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__RedeemCollateralFailed();
        }
    }

    //if someone is almost undercollateralized, we will pay you to liquidate them
    // /**
    //  *
    //  * @param collateral ERC 20 collateral To Liquidate
    //  * @param user User to liquidate. The one who broke health factor
    //  * @param debtToCover Amount of DSC you want to burn to improve the users health factor
    //  * @notice You can partially liquidate
    //  * @notice You  will get bonus for taking users funds
    //  * @notice This function working assumes the protocol will be rougly 200% overcollateralized´
    //  * @notice Known bug: If collateral is or is less than 100%, we wouldnt be able to incentivize liquidators
    //  *
    //  * Follows CEI
    //  */
    // function _liquidateKeetha(address collateral, address user, uint256 debtToCover)
    //     internal
    //     moreThanZero(debtToCover)
    //     isAllowedToken(collateral)
    //     nonReentrant
    // {
    //     //Checks
    //     uint256 startingHealthFactor = _healthFactor(user);
    //     if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
    //         revert DSCEngine__HealthFactorOk();
    //     }

    //     if (user == address(0)) {
    //         revert DSCEngine__AddressZeroNotAllowed();
    //     }
    //     if (s_DSCMinted[user] - debtToCover < 0) {
    //         revert DSCEngine__NotEnoughAmount();
    //     }

    //     //Effects
    //     uint256 percentage = (debtToCover * 100 * PRECISION) / s_DSCMinted[user];
    //     uint256 collateralRedeemed = (s_collateralDeposited[user][collateral] * percentage) / 100;
    //     s_DSCMinted[user] -= debtToCover;
    //     s_collateralDeposited[user][collateral] -= collateralRedeemed;

    //     uint256 tokenAmount = getTokenAmounFromUsd(collateral, debtToCover * PRECISION);
    //     //Interactions
    //     IERC20(collateral).transferFrom(msg.sender, address(this), tokenAmount); // collateral is weth or wbtc, debtToCover is USD, so we cannot say gimme 50 ETH, but 0.00...ETH, thats why we have to do the conversion
    //     IERC20(collateral).transfer(msg.sender, collateralRedeemed);
    //     i_dsc.burn(debtToCover);
    // }

    ///////////////////////////////////////////
    /////Pure & External  View Functions//////
    ///////////////////////////////////////////

    function getTokenAmounFromUsd(address collateral, uint256 debtAmountInUsdInWei) public view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(s_priceFeeds[collateral]).staleCheckLatestRoundData();
        return (debtAmountInUsdInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface tokenContract = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = tokenContract.staleCheckLatestRoundData();
        return (amount * uint256(price) * ADDITIONAL_FEED_PRECISION) / PRECISION;
    }

    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalValueInUsd += getUsdValue(token, amount); //We can do this
        }
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getHealtFactor(address user) public view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address collateral) public view returns (address) {
        return s_priceFeeds[collateral];
    }

    function getCollateralBalanceOfUser(address user, address collateral) public view returns (uint256) {
        return s_collateralDeposited[user][collateral];
    }
}
