// SPDX-License-Identifier: MIT
// An example of a consumer contract that directly pays for each request.
pragma solidity 0.8.20;

interface IDeposit {

    function deposit(address depositorContract, address playerAddress, uint256 amount) external;

}
