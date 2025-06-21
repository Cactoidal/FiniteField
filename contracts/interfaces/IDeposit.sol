// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IDeposit {

    function depositGameToken(address depositorContract, address playerAddress, uint256 amount) external;

}
