// SPDX-License-Identifier: MIT
// Handler is going to narrow down the way we call function

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";


contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    constructor( DSCEngine _dsce , DecentralizedStableCoin _dsc){
        dsce = _dsce;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getPriceFeedAddresses(address(weth)));
    }
    
    //  //This breaks our invariant test suits!!!
    function mintDsc(uint256 amount , uint256 addressSeed   ) public {
        if(usersWithCollateralDeposited.length == 0){
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
    
        (uint256 totalDscMinted, uint256 totalcollateralValueInUsd) = dsce.getAccountInformation(sender);

        int256 maxDscToMint = (int256(totalcollateralValueInUsd)/2) - (int256(totalDscMinted));
        if (maxDscToMint < 0) {
            return;
        }
        amount = bound(amount, 0 , uint256(maxDscToMint));
        if (amount == 0){
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();

        timesMintIsCalled++;
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral =  _getCollateralFromSeed(collateralSeed );
        amountCollateral = bound(amountCollateral, 1 , MAX_DEPOSIT_SIZE );

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depoositCollateral( address(collateral), amountCollateral);
        vm.stopPrank();

        //Beware of double push ie repeating an address
        // uint256 i;
        // for(i = 1; i < usersWithCollateralDeposited.length ; i++){
        //       if(usersWithCollateralDeposited[i] == msg.sender){
        //         return;
        //       }
        //       usersWithCollateralDeposited.push(msg.sender);
        // }
        usersWithCollateralDeposited.push(msg.sender);
        
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral =  _getCollateralFromSeed(collateralSeed );
        uint256 maxCollateralToRedeem = dsce.getAmountCollateralDeposited(address(collateral),msg.sender);
        amountCollateral = bound(amountCollateral, 0 , maxCollateralToRedeem );
        if(amountCollateral == 0){
            return;
        }
        vm.prank(msg.sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }
    
    //This breaks our invariant test suits!!!
    function updateCollateralPrice(uint96 newPrice)  public {
        int256 newPriceInt = int256(uint256(newPrice));
        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }

    // Helper Function
    function _getCollateralFromSeed(uint256 collateralSeed ) private view returns(ERC20Mock){
        if (collateralSeed % 2 == 0) {
            return weth;
        } 
        return wbtc;
    }


}