// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IVRFWrapper {

 function estimateRequestPriceNative(uint32 _callbackGasLimit, uint32 _numWords, uint256 _requestGasPriceWei) 
    external view returns (uint256); 

}
