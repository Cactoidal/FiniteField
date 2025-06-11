// SPDX-License-Identifier: MIT
// An example of a consumer contract that directly pays for each request.
pragma solidity 0.8.20;

import {ConfirmedOwner} from "@chainlink/contracts@1.4.0/src/v0.8/shared/access/ConfirmedOwner.sol";
import {LinkTokenInterface} from "@chainlink/contracts@1.4.0/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts@1.4.0/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts@1.4.0/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IVRFWrapper} from "./IVRFWrapper.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IWithdraw} from "./IWithdraw.sol";

import {Groth16VHandVerifier} from "./HandVerify.sol";
//import {Groth16VSwapVerifier} from "./SwapVerify.sol";
//import {Groth16VPlayVerifier} from "./PlayVerify.sol";


contract CardGame is VRFV2PlusWrapperConsumerBase, ConfirmedOwner, ReentrancyGuard, Groth16VHandVerifier {
   
    error AlreadyHaveSeed();
    error AlreadyRequestedSeed();
    error TransferFailed();
    error InsufficientTokensForAnte();
    error InsufficientFundsForVRF();

    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(
        uint256 requestId,
        uint256[] randomWords,
        uint256 payment
    );

    struct RequestStatus {
        uint256 paid; 
        bool fulfilled; 
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus)
        public s_requests; 


    uint32 public callbackGasLimit = 100000;
    uint16 public requestConfirmations = 3;

    // SEPOLIA
    address public linkAddress = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address public wrapperAddress = 0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1;
    address public poolAddress;
    
    
    enum vrfRequestType {
        GAME_OBJECTIVE,
        NEW_HAND,
        CARD_SWAP
    }

    struct vrfRequest {
        vrfRequestType requestType;
        address requester;
        address gameToken;
        uint256 gameId;
    }

    struct game {
        address[] players;
        address gameToken;
        uint256 ante;
        uint256 maximumSpend;
        uint256 gameId;
    }

    struct seed {
        uint256 vrfSeed;
        uint256 ante;
    }

    // Player > GameToken > handHash
    mapping (address => mapping(address => seed)) public seedForToken;
    mapping (address => mapping(address => bool)) public hasRequestedSeedForToken;

 
    mapping (uint256 => vrfRequest) public pendingVRFRequest;
    mapping (address => uint256) public currentSeed;
    mapping (address => uint256) public currentHand;


    // The Scalar Field size used by Circom.  
    uint256 FIELD_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // DEBUG
    uint mostRecentEstimate;

    constructor() 
        ConfirmedOwner(msg.sender)
        VRFV2PlusWrapperConsumerBase(wrapperAddress)
    {}

    function buyHandSeed(address player, address gameToken, uint256 ante) payable public nonReentrant {
        if (player == address(0)) revert ZeroAddress();
        if (seedForToken[player][gameToken].vrfSeed != 0) revert AlreadyHaveSeed();
        if (hasRequestedSeedForToken[player][gameToken]) revert AlreadyRequestedSeed();
        if (depositBalance[player][gameToken] > ante) revert InsufficientTokensForAnte();
        
        hasRequestedSeedForToken[player][gameToken] = true;
        depositBalance[player][gameToken] -= ante;
        seedForToken[player][gameToken].ante = ante; 

        uint estimate = IVRFWrapper(wrapperAddress).estimateRequestPriceNative(
            callbackGasLimit, 
            1, 
            tx.gasprice);

        // DEBUG
        mostRecentEstimate = estimate;
        if (msg.value < estimate) revert InsufficientFundsForVRF(); 
        
        // Call VRF.
        uint256 requestId = requestSeed();

        // Record the VRF callback arguments.
        pendingVRFRequest[requestId].requestType = vrfRequestType.NEW_HAND;
        pendingVRFRequest[requestId].requester = player;
        pendingVRFRequest[requestId].gameToken = gameToken;
        
        // Transfer any extra ETH back to the caller.
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        if (!success) revert TransferFailed();

    }


    function requestSeed() internal returns (uint256) {
        bytes memory extraArgs = VRFV2PlusClient._argsToBytes(
            VRFV2PlusClient.ExtraArgsV1({nativePayment: true})
        );
        uint256 requestId;
        uint256 reqPrice;

        (requestId, reqPrice) = requestRandomnessPayInNative(
            callbackGasLimit,
            requestConfirmations,
            1,
            extraArgs
            );
        
        s_requests[requestId] = RequestStatus({
            paid: reqPrice,
            randomWords: new uint256[](0),
            fulfilled: false
        });
        
        emit RequestSent(requestId, 1);
        
        return requestId;
    }



    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].paid > 0, "request not found");

        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;

        uint256 vrfSeed = _randomWords[0];
        vrfRequestType requestType = pendingVRFRequest[_requestId].requestType;

        if (requestType == vrfRequestType.NEW_HAND) {
            address player = pendingVRFRequest[_requestId].requester;
            address gameToken = pendingVRFRequest[_requestId].gameToken;
            seedForToken[player][gameToken].vrfSeed = vrfSeed;
            hasRequestedSeedForToken[player][gameToken] = false;
        }

        else if (requestType == vrfRequestType.CARD_SWAP) {
            address player = pendingVRFRequest[_requestId].requester;

        }

        else if (requestType == vrfRequestType.GAME_OBJECTIVE) {
            uint256 gameId = pendingVRFRequest[_requestId].gameId;
        }

        
        emit RequestFulfilled(
            _requestId,
            _randomWords,
            s_requests[_requestId].paid
        );
        
    }



    function proveHand(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[2] calldata _pubSignals) public {
        require (currentSeed[msg.sender] != 0);

        require (this.verifyProof(_pA, _pB, _pC, _pubSignals));
        
        // Seed used in ZKP must match on-chain VRF seed
        // Apply the BN128 Field Modulus first, otherwise bigger values will not validate correctly
        require (_pubSignals[1] == currentSeed[msg.sender] % FIELD_MODULUS);
        
        // Hand hash cached to be used in card-playing proof
        currentHand[msg.sender] = _pubSignals[0];
    }



    function getRequestStatus(
        uint256 _requestId
    )
        external
        view
        returns (uint256 paid, bool fulfilled, uint256[] memory randomWords)
    {
        require(s_requests[_requestId].paid > 0, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.paid, request.fulfilled, request.randomWords);
    }

    /**
     * Allow withdraw of Link tokens from the contract
     */
    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(linkAddress);
        require(
            link.transfer(msg.sender, link.balanceOf(address(this))),
            "Unable to transfer"
        );
    }

    /// @notice withdrawNative withdraws the amount specified in amount to the owner
    /// @param amount the amount to withdraw, in wei
    function withdrawNative(uint256 amount) external onlyOwner {
        (bool success, ) = payable(owner()).call{value: amount}("");
        // solhint-disable-next-line gas-custom-errors
        require(success, "withdrawNative failed");
    }


    event Received(address, uint256);
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }


    mapping (address => mapping (address => uint256)) depositBalance;

    error NotGameToken();
    error ZeroAddress();
    error ZeroAmount();
    event Deposited(address indexed tokenContract, address indexed recipient, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    function depositGameToken(address tokenContract, address player, uint256 amount) external nonReentrant {
        if (!IWithdraw(tokenContract).isGameToken()) revert NotGameToken();
        if (amount == 0) revert ZeroAmount();
        if (player == address(0)) revert ZeroAddress();

        IERC20(tokenContract).transferFrom(tokenContract, player, amount);
        depositBalance[player][tokenContract] += amount;

        emit Deposited(tokenContract, player, amount);
    }

    function withdrawGameToken(address tokenContract) public nonReentrant {
        if (!IWithdraw(tokenContract).isGameToken()) revert NotGameToken();

        uint256 balance = depositBalance[msg.sender][tokenContract];
        if (balance == 0) revert ZeroAmount();

        depositBalance[msg.sender][tokenContract] = 0;
        IWithdraw(tokenContract).burnAndWithdraw(msg.sender, balance);

        emit Withdrawn(msg.sender, balance);
    }

    


}
