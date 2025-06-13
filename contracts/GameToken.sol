// SPDX-License-Identifier: MIT
// An example of a consumer contract that directly pays for each request.
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {IDeposit} from "./interfaces/IDeposit.sol";

contract GameToken is ERC20, ReentrancyGuard {

    constructor() ERC20("GameToken", "GAME") {}

    error TransferFailed();
    error ZeroAddress();
    error ZeroAmount();
    event Deposited(address indexed depositContract, address indexed recipient, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    function mintAndDeposit(address recipient, address depositContract) public payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        
        uint256 mintAmount = msg.value;
        _mint(address(this), mintAmount);
        _approve(address(this), depositContract, mintAmount);
        IDeposit(depositContract).depositGameToken(address(this), recipient, mintAmount);

        emit Deposited(depositContract, recipient, mintAmount);
    }

    // potentially could use ratio instead of assuming always 1:1
    function burnAndWithdraw(uint256 amount, address recipient) public nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
    
        _burn(msg.sender, amount);
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Withdrawn(recipient, amount);
    }

    function isGameToken() external pure returns (bool) {
        return true;
    }

    receive() external payable {}

    


}
