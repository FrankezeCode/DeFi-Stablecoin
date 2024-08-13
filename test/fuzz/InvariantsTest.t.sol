// SPDX-License-Identifier: MIT

// Have our invariant aka properties that will always hold 

//what are our invariants ?
// 1. The  total of DSC should be less than the total value of collateral
// 2. Getter view function should never revert <- evergreen invariant

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Handler} from "test/fuzz/Handler.t.sol";

contract InvariantsTest is StdInvariant , Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    Handler handler;


    address weth;
    address wbtc;

    function setUp() external {
       deployer = new DeployDSC();
       (dsc , dsce , config) = deployer.run();
       (,, weth, wbtc, ) = config.activeNetworkConfig();
    //    targetContract(address(dsce));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
       // hey , dont call redeemcollateral , unless there is collateral to redeem
    }

    function invariant_protocolMustHaveMoreCollateralValueThanTotalSupplyOfDsc() public view{
        //get the value of all the collateral in the protocol
        //compare it to all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("wethvalue:", wethValue );
        console.log("wbtc value:",wbtcValue );
        console.log("totalSupply:",totalSupply);
        console.log("times Mint Is Called:",handler.timesMintIsCalled());

        assert((wethValue + wbtcValue ) >= totalSupply);
    }
}