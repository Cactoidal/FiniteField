// SPDX-License-Identifier: MIT
// An example of a consumer contract that directly pays for each request.
pragma solidity 0.8.20;

interface IWithdraw {

    function burnAndWithdraw(address recipient, uint256 amount) external;

    function isGameToken() external view returns (bool);

}
