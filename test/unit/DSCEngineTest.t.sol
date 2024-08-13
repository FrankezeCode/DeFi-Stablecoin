// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 2 ether ;
    uint256 public constant AMOUNT_COLLATERAL_FOR_LIQUIDATOR = 5 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant WETH_PRICE = 2000;
    uint256 public appropriate_DSC_to_mint = 50 * 1e18;// In this case ( 1 DSC represent $1 and 50 DSC = $50,) while 1e18 represent decimal places . 

    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event DscMinted(
        address indexed User ,
        uint amount
    );

    function setUp() public {
        deployer = new DeployDSC();
        (dsc , dsce , config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);

    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[]  public tokenAddresses;
    address[] public priceFeedAddresses;
    function testGetEachCollateralTokenAddress() public view {
        uint256 index = 0;
        address expectedAddress = weth;
        address actualAddress = dsce.getEachCollateralTokens(index);
        assertEq( expectedAddress,  actualAddress );

    }
    function testGetCollateralTokenAddress() public  {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        address[] memory actualAddresses = dsce.getCollateralTokens();
        assertEq( tokenAddresses,  actualAddresses );

    }

    function testGetPriceFeedAddress() public view {
        address expectedPriceAddress = ethUsdPriceFeed;
        address actualPriceAddress = dsce.getPriceFeedAddresses(weth);
        assertEq( expectedPriceAddress,  actualPriceAddress );
    }
    
     ///////////////
    // Modifiers  //
    ////////////////
    modifier depositedCollateral {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depoositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralandMintedDsc {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depoositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(appropriate_DSC_to_mint);
        vm.stopPrank();
        _;
    }


    //////////////////////
    // Price Feed Tests //
    //////////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18; 
        //15e18 * 2000/ETH = 30,000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth , ethAmount);
        assertEq(expectedUsd , actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2000/Eth , $100
        uint256 expectedWeth = 0.05 ether;
        uint actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount );
        assertEq(expectedWeth, actualWeth);
    }

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public  {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testPriceUpdate() public  {
         int256 plumetedEthPrice  = 30e8;
         address newethUsdPriceFeed =  dsce.getPriceFeedAddressForToken(weth);
         MockV3Aggregator(newethUsdPriceFeed).updateAnswer(plumetedEthPrice );
        (, int256 price ,,,) =  MockV3Aggregator(newethUsdPriceFeed).latestRoundData();

         assertEq(plumetedEthPrice, price);
    }

    function testgetAccountCollateralValue() public  depositedCollateral{
         uint256 expectedCollateralValue = 4000 * 1e18;
         vm.prank(USER);
         uint256 actualCollateralValue = dsce.getAccountCollateralValue(USER);
         assertEq(expectedCollateralValue,actualCollateralValue);
    }



    /////////////////////////
    // Health Factor Tests //
    /////////////////////////
    function testHealthFactorIsWorking () public {
       vm.startPrank(USER);
       ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
       uint256 amountDscToMint = 100;
       dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL , amountDscToMint );
       uint256 actualHealthFactor = dsce.getHealthFactor(USER);
       vm.stopPrank();
       assert(actualHealthFactor > 1);
    }

    function testRevertIfHealthFactorIsBroken() public {
       vm.startPrank(USER);
       ERC20Mock(weth).approve(address(dsce),  AMOUNT_COLLATERAL);
       uint256 amountDscToMint = 200000e18;
       vm.expectRevert();
       dsce.depositCollateralAndMintDsc(weth,  AMOUNT_COLLATERAL , amountDscToMint );
       vm.stopPrank();
    }
    //DSCEngine__BreaksHealthFactor(uint256 healthFactor);

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////
    function testRevertIfCollateralIsZero() public {
       vm.startPrank(USER);
       ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

       vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
       dsce.depoositCollateral(weth, 0);
       vm.stopPrank();

    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("PAT" , "PAT" , USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        dsce.depoositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }
    

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        uint256 expectedDscMinted  = 0;
        uint256 expectedCollateralValueInUsd = AMOUNT_COLLATERAL * WETH_PRICE ;
        uint256 expectedDepositedAmount =  AMOUNT_COLLATERAL;
        (uint256 actualDscMinted  , uint256 actualCollateralValueInUsd ) = dsce.getAccountInformation(USER);
        uint256 actualDepositAmount = dsce.getTokenAmountFromUsd(weth ,  actualCollateralValueInUsd );
        assertEq(actualDscMinted , expectedDscMinted );
        assertEq(actualCollateralValueInUsd  , expectedCollateralValueInUsd );
        assertEq(actualDepositAmount ,expectedDepositedAmount );
    }

     function testSuccessfulDepositCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        
        vm.expectEmit(true, true, true, true , address(dsce));
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dsce.depoositCollateral(weth, AMOUNT_COLLATERAL);  
        vm.stopPrank();
    
        uint256 depositedAmount = dsce.getAccountCollateralValue(USER);
        assertEq(depositedAmount, AMOUNT_COLLATERAL * 2000); // Assuming WETH price is 2000 USD
    }

    /////////////////////
    // MintDsc Tests   //
    /////////////////////
    function testSuccessfulMintDSC() public depositedCollateral{
        vm.startPrank(USER);
        uint256 amountDscMinted = 200 ether;
        vm.expectEmit(true, true, true, true);
        emit DscMinted(USER, amountDscMinted);
        dsce.mintDsc(amountDscMinted);
       
    
        uint256 dscMinted = dsce.getDscMinted(USER);
        assertEq(dscMinted, amountDscMinted ); 
        vm.stopPrank();
    }

    /////////////////////////////
    // RedeemCollateral Tests  //
    /////////////////////////////
   function testSuccessfulRedeemCollateral() public depositedCollateralandMintedDsc {
       vm.startPrank(USER);
       uint256 redeemAmount = 0.5 ether;
       uint256 startingAmount = dsce.getAmountCollateralDeposited(weth,USER);
       dsce.redeemCollateral(weth ,  redeemAmount );
       uint256  expectedEndingAmount = startingAmount - redeemAmount ;
       uint256  actualEndingAmount = dsce.getAmountCollateralDeposited(weth,USER);
       vm.stopPrank();
       assertEq(expectedEndingAmount  ,  actualEndingAmount);
   }

   function testRevertIfUserHealthFactorIsBrokenAfterRedeem() public depositedCollateralandMintedDsc {
       vm.startPrank(USER);
       uint256 inappropriate_redeemAmount = 2 ether;
       vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
       dsce.redeemCollateral(weth , inappropriate_redeemAmount);
   }

    /////////////////////
    // BurnDsc Tests  //
    ////////////////////
    function testSuccessfulBurnDsc() public depositedCollateralandMintedDsc {
       vm.startPrank(USER);
       uint256 burnAmount = 50e18 ;
       uint256 startingAmount = dsce.getDscMinted(USER);
       dsc.approve(address(dsce), burnAmount);
       dsce.burnDsc(burnAmount);
       uint256  expectedEndingAmount = startingAmount - burnAmount ;
       uint256  actualEndingAmount = dsce.getDscMinted(USER);
       vm.stopPrank();
       assertEq(expectedEndingAmount  ,  actualEndingAmount);
    }

    ////////////////////////////
    // liquidate User Tests  //
    ///////////////////////////
    function testSuccessfulLiquidateUser() public depositedCollateralandMintedDsc {
       int256 plummetedEthPrice  = 49e8;

       setUpLiquidator(LIQUIDATOR);
       // Setup the health factor to be below threshold.
       // This is done by plumeting the price of ETH

       address newethUsdPriceFeed =  dsce.getPriceFeedAddressForToken(weth);
       MockV3Aggregator(newethUsdPriceFeed).updateAnswer(plummetedEthPrice );
       
       vm.prank(LIQUIDATOR);
       dsce.liquidate(weth, USER, appropriate_DSC_to_mint);
       uint256 expected_amount_of_DSC_minted_by_liquidatee = 0;
       uint256 actual_amount_of_DSC_minted_by_liquidatee = dsce.getDscMinted(USER);
       assertEq(expected_amount_of_DSC_minted_by_liquidatee, actual_amount_of_DSC_minted_by_liquidatee );
       vm.stopPrank();
    }

    function testUserHealthFactorImprovedAfterLiquidation() public depositedCollateralandMintedDsc {
       int256 plummetedEthPrice  = 49e8;
       uint256 startingUserHealthFactor = dsce.getHealthFactor(USER);
       setUpLiquidator(LIQUIDATOR);
       // Setup the health factor to be below threshold.
       // This is done by plumeting the price of ETH

       address newethUsdPriceFeed =  dsce.getPriceFeedAddressForToken(weth);
       MockV3Aggregator(newethUsdPriceFeed).updateAnswer(plummetedEthPrice );
       
       vm.prank(LIQUIDATOR);
       dsce.liquidate(weth, USER, appropriate_DSC_to_mint);
       uint256 endingUserHealthFactor = dsce.getHealthFactor(USER);
       assert(endingUserHealthFactor > startingUserHealthFactor);
       vm.stopPrank();
    }

    function testRevertIfUserHealthFactorNotImprovedAfterLiquidation() public depositedCollateralandMintedDsc {
       int256 plummetedEthPrice  = 49e8;
       uint256 dsc_to_mint = 10;

       setUpLiquidator(LIQUIDATOR);
       // Setup the health factor to be below threshold.
       // This is done by plumeting the price of ETH

       address newethUsdPriceFeed =  dsce.getPriceFeedAddressForToken(weth);
       MockV3Aggregator(newethUsdPriceFeed).updateAnswer(plummetedEthPrice );
       
       vm.prank(LIQUIDATOR);
       vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
       dsce.liquidate(weth, USER, dsc_to_mint);
       vm.stopPrank();
    }

    function testRevertIfUSerHealthFactorIsOk() public depositedCollateralandMintedDsc {
       int256 plummetedEthPrice  = 50e8;

       setUpLiquidator(LIQUIDATOR);
       // Setup the health factor to be below threshold.
       // This is done by plumeting the price of ETH

       address newethUsdPriceFeed =  dsce.getPriceFeedAddressForToken(weth);
       MockV3Aggregator(newethUsdPriceFeed).updateAnswer(plummetedEthPrice );
       
       vm.prank(LIQUIDATOR);
       vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
       dsce.liquidate(weth, USER, appropriate_DSC_to_mint);
       vm.stopPrank();
    }

     function testRevertIfLiquidatorHealthFactorIsBrokenAfterLiquidation() public depositedCollateralandMintedDsc {
       int256 plummetedEthPrice  = 49e8;
       uint256 AMOUNT_COLLATERAL_FOR_LIQUIDATOR_FOR_TEST = 1 ether;

       //Set Up liuidator
       ERC20Mock(weth).mint(LIQUIDATOR , STARTING_ERC20_BALANCE);
       vm.startPrank(LIQUIDATOR);
       ERC20Mock(weth).approve(address(dsce),  AMOUNT_COLLATERAL_FOR_LIQUIDATOR_FOR_TEST );
       dsce.depositCollateralAndMintDsc(weth,  AMOUNT_COLLATERAL_FOR_LIQUIDATOR_FOR_TEST, appropriate_DSC_to_mint);
       dsc.approve(address(dsce), appropriate_DSC_to_mint);
       vm.stopPrank();

       // Setup the health factor to be below threshold.
       // This is done by plumeting the price of ETH
       address newethUsdPriceFeed =  dsce.getPriceFeedAddressForToken(weth);
       MockV3Aggregator(newethUsdPriceFeed).updateAnswer(plummetedEthPrice );
       
       vm.prank(LIQUIDATOR);
       vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
       dsce.liquidate(weth, USER, appropriate_DSC_to_mint);
       vm.stopPrank();
    }





     /////////////////////
     // Helper Function //
    //////////////////////
    function setUpLiquidator(address liquidator) private {
       ERC20Mock(weth).mint(liquidator, STARTING_ERC20_BALANCE);
       vm.startPrank(liquidator);
       ERC20Mock(weth).approve(address(dsce),  AMOUNT_COLLATERAL_FOR_LIQUIDATOR );
       dsce.depositCollateralAndMintDsc(weth,  AMOUNT_COLLATERAL_FOR_LIQUIDATOR , appropriate_DSC_to_mint);
       dsc.approve(address(dsce), appropriate_DSC_to_mint);
       vm.stopPrank();
    }

}