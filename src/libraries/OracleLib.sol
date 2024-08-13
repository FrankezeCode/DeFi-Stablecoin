// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.18;
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title Oracle Library
 * @author Frank Eze
 * @notice This library is used to check the chainlink Oracle for stale data,
 * if a price is stale , the function will revert, and render the DSCEngine unusable - this is by design
 * We want the DSCEngine to freeze if prices become stale.
 * 
 * so if the Chainlink network explodes and you have a lot of money locked in the protocol....too bad.
 */
library  OracleLib{
   error OracleLib_StalePrice();

   uint256 private constant TIMEOUT = 3 hours; // same as 3 * 60 * 60
   
   function staleCheckLatestRoundData(AggregatorV3Interface priceFeed) public view returns (uint80 , int256 , uint256 , uint256 , uint80 ) 
   {
     (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();

     uint256 secondsSincePriceFeedWasUpdated = block.timestamp - updatedAt ;
     if(secondsSincePriceFeedWasUpdated > TIMEOUT) revert OracleLib_StalePrice();
     return   (roundId, answer, startedAt,  updatedAt,  answeredInRound );
   }
}