////Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
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

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "src/libraries/OracleLib.sol";


/**
 * @title DSCEngine
 * @author Frank Eze
 *
 * The system is designed to be as minimal as  possible, and have the tokens maitain a 1 token == $1 peg
 * This stablecoin has the properties:
 * - Exogenouse Collateral
 * - Dollar Pegged
 * - Algorimically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC sytem should always be "overcollaterized" , At no point , should the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and redeaming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the makerDAO DSC (DAI) system
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    //  Errors   //
    ///////////////
    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine_NotAllowedToken();
    error DSCEngine__TransferedFailed();
    error DSCEngine__BreaksHealthFactor();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    //////////////
    //  Type   //
    /////////////
    using OracleLib for AggregatorV3Interface;

    /////////////////////////
    //  State Variables   //
    ////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% Overcollaterized ( you must have double the value)
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1 ether ;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means 10% bonus
    mapping(address token => address priceFeed) s_priceFeed; //tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    ////////////////
    //  Events    //
    ////////////////
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );
    event DscMinted(
        address indexed User ,
        uint amount
    );
    event DscBurned(
        address indexed BurnedFor,
        address indexed BurnedFrom,
        uint indexed amount
    );

    ////////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    ////////////////
    // Functions //
    ///////////////
    constructor(
        address[] memory tokenAdresses,
        address[] memory priceFeedsAdresses,
        address dscAddress
    ) {
        if (tokenAdresses.length != priceFeedsAdresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAdresses.length; i++) {
            s_priceFeed[tokenAdresses[i]] = priceFeedsAdresses[i];
            s_collateralTokens.push(tokenAdresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////////////
    // Public & External Functions //
    /////////////////////////////////
    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit
     * @param amountCollateral  The amount of collateral to deposit
     * @param amountDscToMint  The amount of Decentralized stable coin to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depoositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI pattern
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of the collateral to deposit
     */
    function depoositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferedFailed();
        }
    }
    /**
     * 
     * @param tokenCollateralAddress  The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn 
     * @notice This function burns DSC and redeems the underlying collateral in one transaction
     */
    function redeemCollateralForDsc(  address tokenCollateralAddress, uint256 amountCollateral , uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress,amountCollateral);
        //redeemCollateral already check factor
    }

    // in order to redeem collateral:
    //1. health factor must be over 1 After collateral pulled
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(msg.sender , msg.sender, tokenCollateralAddress ,amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Follows CEI
     * @param amountDscToMint The amount of decentralize stablecoin to mint
     * @notice They must have more collateral value than the minimum threshold
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        emit DscMinted(
            msg.sender,
            amountDscToMint
        );
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(msg.sender , msg.sender , amount);
        _revertIfHealthFactorIsBroken(msg.sender);// i dont think this would ever hit...
    }
    
    /**
     * 
     * @param collateral The ERC20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor , their _healthFactor should be
     * below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate a user .
     * @notice You will get liquidation bonus for taking the users funds
     * @notice This function working  assumes the protocol will be roughly 200% overcollaterize * in other for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we  woudn't be be able to incentive the liquidators
     * Follows CEI: Checks , Effect  and Interaction
     */ 
    function liquidate(address collateral, address user , uint256 debtToCover)
          external
          moreThanZero(debtToCover)
          nonReentrant
    { 
        // need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOk();
        }
        // We want to burn their DSC "debt"
        // And take their collateral
        // Bad User : $140 ETH , $100 DSC 
        // debtToCover = $100
        // $100 of DSC == ?? ETH? how much worth of ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator 110 of weth for 100  DSC
        // We should implement a feature to liquidate  in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = ( tokenAmountFromDebtCovered * LIQUIDATION_BONUS )/ 100 ;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral ;

        _redeemCollateral(user , msg.sender, collateral ,totalCollateralToRedeem );
        //burn DSC
        _burnDsc(user, msg.sender,debtToCover);

        //We need to ensure the Health Factor  is okay after liquidation
        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor){
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);

    }


    ///////////////////////////////////////
    // Private & Internal view Functions //
    ///////////////////////////////////////
    /**
     * @dev Low-level internal function, do not call unless the function calling it is checking
     * for  health factors being broken
     * @param amountDscToBurn  the amount of DSC to burn
     * @param onBehalfOf the owner(user) of the  dsc
     * @param dscFrom   the  person burning the dsc
     */
    function _burnDsc(address onBehalfOf , address dscFrom, uint256 amountDscToBurn) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn ;
        emit DscBurned(
            onBehalfOf,
            dscFrom,
            amountDscToBurn
        );
        bool success = i_dsc.transferFrom(dscFrom , address(this), amountDscToBurn);
        // This condition is hypothetically unreachable
        if (!success){
            revert DSCEngine__TransferedFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }
    

    function _redeemCollateral(address from , address to , address tokenCollateralAddress , uint256 amountCollateral ) private  {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success){
            revert DSCEngine__TransferedFailed();
        }
    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 totalcollateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        totalcollateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1. then they can get liquidated
     * @param user This is the particular user address
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (
            uint256 totalDscMinted,
            uint256 totalcollateralValueInUsd
        ) = _getAccountInformation(user);

        if(totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (totalcollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        // if healthFactor is less than one (< 1 ) , you get liquidated
        /* Example1: $1OOO ETH for 100 DSC
         * 1000 * 50   = 50,000 / 100 = (500 / 100)  > 1
         *
         * Example2: $1OO ETH for 100 DSC
         * 100 * 50   = 5,000 / 100 = (50 / 100)  < 1
         *
         * Example3: $150 ETH for 100 DSC
         * 150 * 50   = 7500 / 100 = (75 / 100)  < 1
         *
         * Example3: $200 ETH for 100 DSC
         * 200 * 50   = 10,000 / 100 = (100 / 100)  = 1
         */
    }

    // 1. check health factor (do they have enough collateral ?
    // 2. Revert if they dont
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor();
        }
    }

    ///////////////////////////////////////
    // Public & External view Functions //
    //////////////////////////////////////
    function getTokenAmountFromUsd(address token , uint256 usdAmountInWei) public view  returns(uint256){
        // price of ETH (token)
        // $2000/ETH : $1000 =  0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price ,,,) = priceFeed.staleCheckLatestRoundData();
        // ( 100 * e18 )/(2000,00000000 * e10) = 0.005ETH
        return  (usdAmountInWei * PRECISION)/ (uint256(price) * ADDITIONAL_FEED_PRECISION );
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalcollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalcollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalcollateralValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeed[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // 1. ETH = $1000
        // The returned value from Chainlink will be $1000 * 1e8
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user) external view returns (uint256 totalDscMinted, uint256 totalcollateralValueInUsd) {
       (totalDscMinted , totalcollateralValueInUsd ) =  _getAccountInformation(user);
    }

    function getHealthFactor(address user) external view returns (uint256){
        return _healthFactor(user);
    }

    function getRevertIfHealthFactorIsBroken(address user) external view {
         _revertIfHealthFactorIsBroken(user) ;
    }

    function getDscMinted(address user) public view returns(uint) {
        return s_DSCMinted[user];
    }

    function getAmountCollateralDeposited(address token , address user) public view returns(uint amount ){
        amount = s_collateralDeposited[user][token];
        return amount;
    }

    function getPriceFeedAddressForToken(address tokenAddress) public view returns (address){
        return   s_priceFeed[tokenAddress];
    }

    function getEachCollateralTokens(uint index)public view returns (address){
        return s_collateralTokens[index];
    }

    function getCollateralTokens()public view returns (address[] memory){
        return s_collateralTokens;
    }

    function getPriceFeedAddresses(address tokenAddress)public view returns (address){
        return s_priceFeed[tokenAddress];
    }
}