// SPDX-License-Identifier: MIT
// An example of a consumer contract that directly pays for each request.
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {IDeposit} from "./interfaces/IDeposit.sol";

// Rationale: 
// Game sessions require players to lock a certain quantity of tokens to cover
// both the ante and the maximumSpend of the session.  wETH is suitable for this
// purpose, but the introduction of mintAndDeposit and burnAndWithdraw allow for
// improved UX (no approvals required).  The pool of ETH created by minting gameTokens 
// must also be kept siloed from the game logic contract, where VRF requests paid 
// in native ETH could affect the pool.

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

        // Regardless of the content of depositGameToken(), the caller must pay ETH
        // to mint an equivalent amount of tokens, and the ETH will remain here.
        IDeposit(depositContract).depositGameToken(address(this), recipient, mintAmount);

        emit Deposited(depositContract, recipient, mintAmount);
    }

    // NOTE: potentially could use ratio instead of assuming always 1:1
    function burnAndWithdraw(address recipient, uint256 amount) public nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
    
        // Attempts to withdraw ETH will automatically fail unless the sender
        // actually possesses the token.
        _burn(msg.sender, amount);

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Withdrawn(recipient, amount);
    }

    // NOTE: This is not a security check
    function isGameToken() external pure returns (bool) {
        return true;
    }

    receive() external payable {}

    


}
