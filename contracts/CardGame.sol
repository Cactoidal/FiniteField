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

import {Groth16HandVerifier} from "./HandVerify.sol";
//import {Groth16VSwapVerifier} from "./SwapVerify.sol";
//import {Groth16VPlayVerifier} from "./PlayVerify.sol";


contract CardGame is VRFV2PlusWrapperConsumerBase, ConfirmedOwner, ReentrancyGuard, Groth16HandVerifier {
   
    error InvalidVRFSeed();
    error InvalidZKP();
    error AlreadyRequestedSeed();
    error AlreadyHaveHand();
    error AlreadySwapped();
    error NotInGame();
    error NotEnoughTimePassed();
    error DoesNotMatchHandHash();

    error InvalidPlayerCount();
    error PlayerAlreadyInGame();
    error PlayerLacksHand();
    error AnteDoesNotMatch();
    error PlayerLacksTokens();

    error GameHasNotStarted();
    error OutOfTime();
    error TooEarly();
    
    error TransferFailed();
    error InsufficientTokensForAnte();
    error InsufficientFundsForVRF();

    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(
        uint256 requestId,
        uint256[] randomWords,
        uint256 payment
    );

    event ProvedHand(address player, uint256 handHash, uint256 playerVRFSeed);
    event StartingNewGame(uint256 gameId);
    event GameStarted(uint256 gameId, uint256 objectiveVRFSeed);
    event SwappedCards(address player, uint256 gameId, uint256 playerVRFSeed);
    event Raised(address player, uint256 gameId, uint256 amount);
    event Folded(address player, uint256 gameId, uint256 amount);
    event PlayedCards(address player, uint256 gameId, uint8[] cards);
    event GameConcluded(address[] winners, uint256 gameId, uint256 prize);

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
    address public vrfWrapperAddress = 0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1;
    
    
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
        uint256 startTimestamp;
        uint256 objectiveVRF;
    }

    struct gameStatus {
        uint256 vrfSeed;
        uint256 ante;
        uint256 currentHand;
        uint256 gameId;
        uint256 vrfSwapSeed;
        bool hasRequestedSwap;
    }

    // Player > GameToken > handHash
    mapping (address => mapping(address => gameStatus)) public tokenGameStatus;
    mapping (address => mapping(address => bool)) public hasRequestedSeedForToken;

 
    mapping (uint256 => vrfRequest) public pendingVRFRequest;
    uint256 public gameIds = 1;
    mapping (uint256 => game) public gameSession;

    uint8 constant TIME_LIMIT = 180;
    uint16 constant END_LIMIT = 900;
  


    // The Scalar Field size used by Circom.  
    uint256 FIELD_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // DEBUG
    uint mostRecentEstimate;

    constructor() 
        ConfirmedOwner(msg.sender)
        VRFV2PlusWrapperConsumerBase(vrfWrapperAddress)
    {}

    function buyHandSeed(address player, address gameToken, uint256 ante) payable public nonReentrant {
        if (player == address(0)) revert ZeroAddress();
        
        // Cannot request new seed for this token until request completes.
        if (hasRequestedSeedForToken[player][gameToken]) revert AlreadyRequestedSeed();

        // Cannot request new seed if it has been used to create a hand.
        if (tokenGameStatus[player][gameToken].currentHand != 0) revert AlreadyHaveHand();

        // The ante is an upfront cost for a seed; the seed is only eligible for use in 
        // games with the same ante.
        if (depositBalance[player][gameToken] > ante) revert InsufficientTokensForAnte();
        
        hasRequestedSeedForToken[player][gameToken] = true;
        depositBalance[player][gameToken] -= ante;
        tokenGameStatus[player][gameToken].ante = ante; 

        uint estimate = IVRFWrapper(vrfWrapperAddress).estimateRequestPriceNative(
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

            // The VRF seed for a new hand has been recorded; the player 
            // may now use it to generate a ZKP linked to a secret hand.
            tokenGameStatus[player][gameToken].vrfSeed = vrfSeed;
            hasRequestedSeedForToken[player][gameToken] = false;
        }

        else if (requestType == vrfRequestType.CARD_SWAP) {
            address player = pendingVRFRequest[_requestId].requester;
            address gameToken = pendingVRFRequest[_requestId].gameToken;

            // The VRF seed for swapping cards has been recorded; the player 
            // may now use it to draw 2 cards and generate a new ZKP.
            tokenGameStatus[player][gameToken].vrfSwapSeed = vrfSeed;

        }

        else if (requestType == vrfRequestType.GAME_OBJECTIVE) {
            uint256 gameId = pendingVRFRequest[_requestId].gameId;
            game storage startingGame = gameSession[gameId];

            // Tells the players what kind of hands they need to win,
            // and sets the time limits for the game.  At this point,
            // the game has begun.
            startingGame.objectiveVRF = vrfSeed;
            startingGame.startTimestamp = block.timestamp;

            emit GameStarted(gameId, vrfSeed);

        }

        
        emit RequestFulfilled(
            _requestId,
            _randomWords,
            s_requests[_requestId].paid
        );
        
    }



    function proveHand(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[3] calldata _pubSignals) public nonReentrant {
        address gameToken = address(uint160(_pubSignals[2]));
        gameStatus memory playerInfo = tokenGameStatus[msg.sender][gameToken];
        uint256 playerVRFSeed = playerInfo.vrfSeed;

        if (playerVRFSeed == 0) revert InvalidVRFSeed();
        if (playerInfo.currentHand == 0) revert AlreadyHaveHand();
        if (!this.verifyHandProof(_pA, _pB, _pC, _pubSignals)) revert InvalidZKP();
        
        // Seed used in ZKP must match on-chain VRF seed
        // Apply the BN128 Field Modulus first, otherwise bigger values will not validate correctly
        if (_pubSignals[1] != playerVRFSeed % FIELD_MODULUS) revert InvalidVRFSeed();
        
        // Hand hash cached for use in game
        tokenGameStatus[msg.sender][gameToken].currentHand = _pubSignals[0];
        
        emit ProvedHand(msg.sender, _pubSignals[0], playerVRFSeed);
    }


    function startGame(address _gameToken, uint256 _ante, uint256 _maximumSpend, address[] calldata players) payable public nonReentrant {
        uint playerCount = players.length;
        if (playerCount > 6 || playerCount < 3) revert InvalidPlayerCount();

        address gameToken = _gameToken;
        uint256 ante = _ante;
        uint256 maximumSpend = _maximumSpend;

        uint estimate = IVRFWrapper(vrfWrapperAddress).estimateRequestPriceNative(
            callbackGasLimit, 
            1, 
            tx.gasprice);

        if (msg.value < estimate) revert InsufficientFundsForVRF(); 

        for (uint i = 0; i < playerCount; i++) {
            gameStatus memory playerInfo = tokenGameStatus[players[i]][gameToken];
            if (playerInfo.gameId != 0) revert PlayerAlreadyInGame();
            if (playerInfo.currentHand == 0) revert PlayerLacksHand();
            if (playerInfo.ante != ante) revert AnteDoesNotMatch();
            if (depositBalance[players[i]][gameToken] < maximumSpend) revert PlayerLacksTokens();
            
            tokenGameStatus[players[i]][gameToken].gameId = gameIds;
        }

        game memory newSession;
        newSession.players = players;
        newSession.gameToken = gameToken;
        newSession.ante = ante;
        newSession.maximumSpend = maximumSpend;

        gameSession[gameIds] = newSession;

         // Call VRF.
        uint256 requestId = requestSeed();

        // Record the VRF callback arguments.
        pendingVRFRequest[requestId].requestType = vrfRequestType.GAME_OBJECTIVE;
        pendingVRFRequest[requestId].gameId = gameIds;

        emit StartingNewGame(gameIds);

        gameIds++;

        // Transfer any extra ETH back to the caller.
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        if (!success) revert TransferFailed();

        
    }

    // Only callable during the first 3 minutes
    function raise(address gameToken) public {
        if (!withinTimeLimit(msg.sender, gameToken, TIME_LIMIT)) revert OutOfTime();

        // emit Raised()
    }

    function fold(address gameToken) public {
        if (!withinTimeLimit(msg.sender, gameToken, TIME_LIMIT)) revert OutOfTime();

        //emit Folded()
    }

    function swapCards(address gameToken) public {
        if (!withinTimeLimit(msg.sender, gameToken, TIME_LIMIT)) revert OutOfTime();

        //emit SwappedCards()
    }
    

    // Only callable after the first 3 minutes, before 15 minutes have elapsed
    function playCards(address gameToken) public {
        if (withinTimeLimit(msg.sender, gameToken, TIME_LIMIT)) revert TooEarly();
        if (!withinTimeLimit(msg.sender, gameToken, END_LIMIT)) revert OutOfTime();

        //emit PlayedCards()
    }

    // Only callable after 15 minutes have elapsed
    function concludeGame(address gameToken) public {
        if (withinTimeLimit(msg.sender, gameToken, END_LIMIT)) revert TooEarly();
        
        //emit GameConcluded()
    }


    function withinTimeLimit(address player, address gameToken, uint limit) public view returns(bool) {
        bool within = false;

        uint gameId = tokenGameStatus[player][gameToken].gameId;
        if (gameId == 0) revert GameHasNotStarted();

        uint startTimestamp = gameSession[gameId].startTimestamp;
        if (startTimestamp == 0) revert GameHasNotStarted();

        if ((block.timestamp - startTimestamp) < limit ) {
            within = true;
        }

        return within;
    }



    //  TOKEN MANAGEMENT

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








    // MAINTENANCE


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


}
