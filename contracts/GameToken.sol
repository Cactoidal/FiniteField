// SPDX-License-Identifier: MIT
// An example of a consumer contract that directly pays for each request.
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IDeposit} from "./IDeposit.sol";

contract GameToken is ERC20, ReentrancyGuard {

    constructor() ERC20("GameToken", "GAME") {}

    function mintAndDeposit(address recipient, address depositContract) public payable nonReentrant {
        require(msg.value > 0, "Amount must be > 0");
        require(recipient != address(0), "Cannot deposit to zero address");
        
        uint256 mintAmount = msg.value;
        _mint(address(this), mintAmount);
        approve(depositContract, mintAmount);
        IDeposit(depositContract).deposit(address(this), recipient, mintAmount);

        emit Deposited(depositContract, recipient, mintAmount);
    }

    function burnAndWithdraw(uint256 amount, address recipient) public nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(recipient != address(0), "Cannot withdraw to zero address");
        _burn(msg.sender, amount);
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "ETH transfer failed");

        emit Withdrawn(recipient, amount);
    }

    function isGameToken() external pure returns (bool) {
        return true;
    }

    receive() external payable {}

    event Deposited(address indexed depositContract, address indexed recipient, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);


}
