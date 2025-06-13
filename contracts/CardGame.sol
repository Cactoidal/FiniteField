// SPDX-License-Identifier: MIT
// An example of a consumer contract that directly pays for each request.
pragma solidity 0.8.20;

import {ConfirmedOwner} from "@chainlink/contracts@1.4.0/src/v0.8/shared/access/ConfirmedOwner.sol";
import {LinkTokenInterface} from "@chainlink/contracts@1.4.0/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts@1.4.0/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts@1.4.0/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {IVRFWrapper} from "./interfaces/IVRFWrapper.sol";
import {IWithdraw} from "./interfaces/IWithdraw.sol";
import {IZKPVerifier} from "./interfaces/IZKPVerifier.sol";


contract CardGame is VRFV2PlusWrapperConsumerBase, ConfirmedOwner, ReentrancyGuard {

    // CONSTANTS
    uint8 constant TIME_LIMIT = 180;
    uint16 constant END_LIMIT = 900;
    uint8 constant TABLE_SIZE = 4;
    // The Scalar Field size used by Circom.  
    uint256 constant FIELD_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    enum vrfRequestType {
        NEW_HAND,
        SWAP_CARDS,
        GAME_OBJECTIVE
    }

    struct vrfRequest {
        vrfRequestType requestType;
        address requester;
        address gameToken;
        uint256 gameId;
        uint256 playerIndex;
    }

    struct game {
        address gameToken;
        uint256 startTimestamp;
        uint256 objectiveSeed;
        uint256 maximumSpend;
        uint256 totalPot;
        uint256 highBid;
        bool hasConcluded;
        address[TABLE_SIZE] players;
        address[TABLE_SIZE] folded;
        uint256[TABLE_SIZE] scores;
        uint256[TABLE_SIZE] vrfSwapSeeds;
        bool[TABLE_SIZE] hasRequestedSwap;
        address[] winners;
    }

    struct playerStatus {
        uint256 vrfSeed;
        uint256 ante;
        uint256 currentHand;
        uint256 gameId;
        uint256 playerIndex;
        uint256 totalBidAmount;
        bool hasRequestedSeed;
    }

    mapping (uint256 => vrfRequest) public pendingVRFRequest;

    // Player address > GameToken contract > playerStatus
    mapping (address => mapping(address => playerStatus)) public tokenPlayerStatus;

    mapping (uint256 => game) public gameSessions;
    uint256 public latestGameId = 1;

    // DEBUG
    uint mostRecentEstimate;

    // CONSTRUCTOR ADDRESSES
    // SEPOLIA
    address vrfWrapperAddress = 0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1;
    address gameZKPVerifier;

    constructor(address _gameZKPVerifier) 
        ConfirmedOwner(msg.sender)
        VRFV2PlusWrapperConsumerBase(vrfWrapperAddress)
    {gameZKPVerifier = _gameZKPVerifier;}

    function buyHandSeed(address playerAddress, address gameToken, uint256 ante) payable public nonReentrant {
        if (playerAddress == address(0)) revert ZeroAddress();
        if (ante == 0) revert ZeroAmount();

        playerStatus storage player = tokenPlayerStatus[playerAddress][gameToken];
        
        // Cannot request new seed for this token while a request is already pending.
        if (player.hasRequestedSeed) revert AlreadyRequestedSeed();

        // Cannot request new seed if it has been used to create a hand.
        if (player.currentHand != 0) revert AlreadyHaveHand();

        // The ante is an upfront cost for a seed; the seed is only eligible for use in 
        // games with the same ante.
        if (depositBalance[playerAddress][gameToken] > ante) revert InsufficientTokensForAnte();
        
        player.hasRequestedSeed = true;
        player.ante = ante; 

        depositBalance[playerAddress][gameToken] -= ante;
        
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
        vrfRequest storage request = pendingVRFRequest[requestId];
        request.requestType = vrfRequestType.NEW_HAND;
        request.requester = playerAddress;
        request.gameToken = gameToken;
        
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
            vrfRequest memory request = pendingVRFRequest[_requestId];
            address playerAddress = request.requester;
            address gameToken = request.gameToken;

            // The VRF seed for drawing a new hand has been recorded; the player 
            // may now use it to generate a ZKP linked to a secret hand.
            tokenPlayerStatus[playerAddress][gameToken].vrfSeed = vrfSeed;
        }

        else if (requestType == vrfRequestType.SWAP_CARDS) {
            vrfRequest memory request = pendingVRFRequest[_requestId];
            uint256 gameId = request.gameId;
            uint256 playerIndex = request.playerIndex;

            // This VRF seed can be used to generate a ZKP linked to
            // a new, modified secret hand.
            gameSessions[gameId].vrfSwapSeeds[playerIndex] = vrfSeed;
        }


        else if (requestType == vrfRequestType.GAME_OBJECTIVE) {
            uint256 gameId = pendingVRFRequest[_requestId].gameId;
            game storage startingGame = gameSessions[gameId];

            // Randomly determines the game objective (i.e. the scoring criteria)
            // and starts the game.
            startingGame.objectiveSeed = vrfSeed;
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
        playerStatus storage player = tokenPlayerStatus[msg.sender][gameToken];
        uint256 playerVRFSeed = player.vrfSeed;

        if (playerVRFSeed == 0) revert InvalidVRFSeed();
        if (player.currentHand != 0) revert AlreadyHaveHand();

        if (!IZKPVerifier(gameZKPVerifier).verifyHandProof(_pA, _pB, _pC, _pubSignals)) revert InvalidZKP();
        
        // Seed used in ZKP must match on-chain VRF seed
        // Apply the BN128 Field Modulus first, otherwise bigger values will not validate correctly
        if (_pubSignals[1] != playerVRFSeed % FIELD_MODULUS) revert InvalidVRFSeed();
        
        // Hand hash cached for use in game
        player.currentHand = _pubSignals[0];
        
        emit ProvedHand(msg.sender, _pubSignals[0], playerVRFSeed);
    }


    function startGame(address _gameToken, uint256 _ante, uint256 _maximumSpend, address[TABLE_SIZE] calldata players) payable public nonReentrant {
        address gameToken = _gameToken;
        uint256 ante = _ante;
        uint256 maximumSpend = _maximumSpend;

        if (ante == 0) revert ZeroAmount();

        // Check VRF fee
        uint estimate = IVRFWrapper(vrfWrapperAddress).estimateRequestPriceNative(
            callbackGasLimit, 
            1, 
            tx.gasprice);

        if (msg.value < estimate) revert InsufficientFundsForVRF(); 

        for (uint i = 0; i < TABLE_SIZE; i++) {
            address playerAddress = players[i];
            if (playerAddress == address(0)) revert ZeroAddress();

            // Check if all players are eligible to play
            playerStatus storage player = tokenPlayerStatus[playerAddress][gameToken];
            if (player.gameId != 0) revert PlayerAlreadyInGame();
            if (player.currentHand == 0) revert PlayerLacksHand();
            if (player.ante != ante) revert AnteDoesNotMatch();
            if (depositBalance[playerAddress][gameToken] < maximumSpend) revert PlayerLacksTokens();
            
            // Assign the player to the game
            player.playerIndex = i;
            player.gameId = latestGameId;
        }

        // Initialize the game state
        game storage newSession = gameSessions[latestGameId];
        newSession.players = players;
        newSession.gameToken = gameToken;
        newSession.totalPot = ante * TABLE_SIZE;
        newSession.maximumSpend = maximumSpend;

         // Call VRF.
        uint256 requestId = requestSeed();

        // Record the VRF callback arguments.
        vrfRequest storage request = pendingVRFRequest[requestId];
        request.requestType = vrfRequestType.GAME_OBJECTIVE;
        request.gameId = latestGameId;

        emit StartingNewGame(latestGameId);

        latestGameId++;

        // Transfer any extra ETH back to the caller.
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        if (!success) revert TransferFailed();
    }


    // Only callable during the first 3 minutes of a game
    function raise(address gameToken, uint amount) public nonReentrant {
        // Check if player is eligible to raise
        playerStatus storage player = tokenPlayerStatus[msg.sender][gameToken];
        
        uint gameId = player.gameId;
        if (gameId == 0) revert GameIDNotFound();
        if (!withinTimeLimit(gameId, TIME_LIMIT)) revert OutOfTime();

        game storage session = gameSessions[gameId];
        
        if (amount + player.totalBidAmount > session.maximumSpend) revert InvalidRaise();

        // Update the player's state
        player.totalBidAmount += amount;
        depositBalance[msg.sender][gameToken] -= amount;

        // Update the game state if new totalBidAmount exceeds previous high bid
        if (player.totalBidAmount > session.highBid) {
            session.highBid = player.totalBidAmount;
        }
    
        emit Raised(msg.sender, gameId, amount);
    }

    // Only callable during the first 3 minutes of a game
    function fold(address gameToken) public {
        // Check if the player is eligible to fold.
        playerStatus memory player = tokenPlayerStatus[msg.sender][gameToken];
        uint gameId = player.gameId;
        if (gameId == 0) revert GameIDNotFound();
        if (!withinTimeLimit(gameId, TIME_LIMIT)) revert OutOfTime();

        // Mark that the player has folded.
        uint playerIndex = player.playerIndex;
        gameSessions[gameId].folded[playerIndex] = msg.sender;

        // Exit the game.
        clearPlayerStatus(gameId, msg.sender);

        emit Folded(msg.sender, gameId);
    }

    // NOTE 
    // It could make sense to require a commitment here: a hash of the 
    // two discarded cards, which will be used as an input to the ZKP
    // and then validated on-chain as a public signal

    // Only callable during the first 2 minutes of the game
    function swapCards(address gameToken) public payable {
        // Check if the player is eligible to swap cards.
        playerStatus memory player = tokenPlayerStatus[msg.sender][gameToken];
        uint gameId = player.gameId;
        if (gameId == 0) revert GameIDNotFound();
        if (!withinTimeLimit(gameId, TIME_LIMIT - 60)) revert OutOfTime();

        uint256 playerIndex = player.playerIndex;
        game storage session = gameSessions[gameId];

        // A player can only swap cards once per game.
        if (session.hasRequestedSwap[playerIndex]) revert AlreadySwapped();
        session.hasRequestedSwap[playerIndex] = true;

        // Check VRF fee.
        uint estimate = IVRFWrapper(vrfWrapperAddress).estimateRequestPriceNative(
            callbackGasLimit, 
            1, 
            tx.gasprice);

        if (msg.value < estimate) revert InsufficientFundsForVRF();

        // Call VRF.
        uint256 requestId = requestSeed();

        // Record the VRF callback arguments.
        vrfRequest storage request = pendingVRFRequest[requestId];
        request.requestType = vrfRequestType.SWAP_CARDS;
        request.gameId = gameId;
        request.playerIndex = playerIndex;

        emit SwappingCards(msg.sender, gameId);

    }

    // DEBUG
    // Double check _pubSignals size

    // Only callable during the first 3 minutes of the game
    function proveSwapCards(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[4] calldata _pubSignals) public {
        
        // Check that the player is eligible to prove the swap.

        address gameToken = address(uint160(_pubSignals[3]));
        playerStatus memory player = tokenPlayerStatus[msg.sender][gameToken];
        uint gameId = player.gameId;
        if (gameId == 0) revert GameIDNotFound();
        if (!withinTimeLimit(gameId, TIME_LIMIT)) revert OutOfTime();

        // The player must request a VRF seed to swap cards.
        uint256 vrfSwapSeed = gameSessions[gameId].vrfSwapSeeds[player.playerIndex];
        if (vrfSwapSeed == 0) revert HaveNotSwapped();
        
        // DEBUG
        // Check the proof
        // here

        // Validate against old hand
        if (_pubSignals[0] != player.currentHand) revert InvalidHash();

        // Validate VRF seed
        if (vrfSwapSeed != _pubSignals[2]) revert InvalidVRFSeed();

        // Update to new hand
        player.currentHand = _pubSignals[1];

        emit ProvedSwap(msg.sender, gameId, vrfSwapSeed);
    }
    


    // Only callable after the first 3 minutes, before 15 minutes have elapsed
    // DEBUG
    // Double check _pubSignals size
    function playCards(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[7] calldata _pubSignals) public {
        
        // Check that the player is eligible to reveal their cards
        address gameToken = address(uint160(_pubSignals[1]));
        playerStatus memory player = tokenPlayerStatus[msg.sender][gameToken];
        uint gameId = player.gameId;
        if (gameId == 0) revert GameIDNotFound();
        if (withinTimeLimit(gameId, TIME_LIMIT)) revert TooEarly();
        if (!withinTimeLimit(gameId, END_LIMIT)) revert OutOfTime();
        
        uint256 playerIndex = player.playerIndex;
        game storage session = gameSessions[gameId];
        if (session.scores[playerIndex] != 0) revert AlreadySubmittedScore();

        // DEBUG
        // Check the proof
        // here

        // Validate against hand hash
        if (_pubSignals[0] != player.currentHand) revert InvalidHash();
        
        // Get the score
        uint256[5] memory cards = [_pubSignals[2], _pubSignals[3], _pubSignals[4], _pubSignals[5], _pubSignals[6]];
        uint256 score = scoreHand(session.objectiveSeed, cards);
        
        // Update the score array
        session.scores[playerIndex] = score;

        // Exit the game
        clearPlayerStatus(gameId, msg.sender);

        emit PlayedCards(msg.sender, gameId, cards);
    }


    // Only callable after 15 minutes have elapsed
    function concludeGame(uint256 gameId) public nonReentrant {

        game memory session = gameSessions[gameId];
        address gameToken = session.gameToken;
     
        // If no gameToken is recorded, the session doesn't exist
        if (gameToken == address(0)) revert GameIDNotFound();
        if (withinTimeLimit(gameId, END_LIMIT)) revert TooEarly();
        if (session.hasConcluded) revert GameAlreadyEnded();

        session.hasConcluded = true;

        uint[TABLE_SIZE] memory scores = session.scores;
        address[TABLE_SIZE] memory players = session.players;
        address[TABLE_SIZE] memory folded = session.folded;
        uint256 highBid = session.highBid;

        address[] storage winners = gameSessions[gameId].winners;

        uint highScore = 0;
        
        // Determine the high score
        for (uint i = 0; i < TABLE_SIZE; i++) {
            if (scores[i] > highScore) {
                highScore = scores[i];
            }
        }

        // Get all winners (since ties are possible)
        // Additionally, update the pot
         for (uint j = 0; j < TABLE_SIZE; j++) {
            address player = players[j];

            // If the player did not fold, make sure
            // they have automatched the high bid. 
            // It must be done in this step, otherwise players 
            // could wait to see what other player reveal
            // during the proving phase, and dodge paying
            // the highBid if their hand isn't a winner.
            if (folded[j] != player) {
                uint256 diff =  highBid - tokenPlayerStatus[player][gameToken].totalBidAmount;
                depositBalance[player][gameToken] -= diff;
                session.totalPot += diff;
            }
            
            // Get the winners
            if (scores[j] == highScore) {
                winners.push(player);
            }
        }

        uint winnerCount = session.winners.length;
        uint prizeAmount = session.totalPot / winnerCount;

        // highScore of 0 indicates all players folded
        // Distribute prizes to winners
        if (highScore != 0) {
            for (uint k = 0; k < winnerCount; k++) {
                depositBalance[winners[k]][gameToken] += prizeAmount;
            }

        }
      
        // add up bets for automatching players who haven't folded
        // clear player status for any players who have not folded/proved
        
    
        emit GameConcluded(winners, gameId, prizeAmount);
    }


    function withinTimeLimit(uint gameId, uint limit) public view returns(bool) {
        bool within = false;

        if (gameId == 0) revert GameHasNotStarted();

        uint startTimestamp = gameSessions[gameId].startTimestamp;
        if (startTimestamp == 0) revert GameHasNotStarted();

        if ((block.timestamp - startTimestamp) < limit ) {
            within = true;
        }

        return within;
    }





    // In theory the scoring contract could be separate and even swappable

    // Cards 1-10
    // attractor is high card
    // colors are silver and blue (?)

    // in theory we could detect multiples, straights, flushes, full house by supplying
    // an array of "claims" that are then checked against the provided cards
    // uint[] calldata claims

    // Because this function can only be called with valid cards, they do not need to be validated here
    function scoreHand(uint256 vrfSeed, uint256[5] memory cards) public pure returns(uint256) {
        (uint256 objAttractor, uint256 objColor) = getObjective(vrfSeed);

        // Right now the maximum score is 100,
        // so could fit into a uint8 if desired
        uint256 score = 0;

        for (uint i = 0; i < 5; i++) {
            uint256 card = cards[i];
            uint8 cardColor = 1;
            if (card > 10) {
                cardColor = 2;

                // Shim for 11-20
                card -= 10;
            }

            uint256 diff = 0;

            if (card > objAttractor) {
                diff = card - objAttractor;
            }
            else if (card < objAttractor) {
                diff = objAttractor - card;
            }

            uint colorBonus = 1;

            if (cardColor == objColor) {
                colorBonus = 2;
            }

            // Cards closest to the attractor have a higher base score;
            // cards of the objective color have their base score multiplied by 2
            score += (10 - diff) * colorBonus;
        }

        return score;

    }

    
    
    function getObjective(uint256 vrfSeed) public pure returns(uint256, uint256) {
        uint attractor = (vrfSeed % 10) + 1;
        uint color = (vrfSeed % 2) + 1;

        return (attractor, color);
    }


    function clearPlayerStatus(uint256 _gameId, address _playerAddress) internal {
        uint256 gameId = _gameId;
        address playerAddress = _playerAddress;
        address gameToken = gameSessions[gameId].gameToken;
        if (gameToken == address(0)) revert GameIDNotFound();
        if (playerAddress == address(0)) revert ZeroAddress();

        playerStatus storage player = tokenPlayerStatus[playerAddress][gameToken];
        if (player.gameId != gameId) revert GameIDNotFound();

        // Reset the player's state
        player.vrfSeed = 0;
        player.ante = 0;
        player.currentHand = 0;
        player.gameId = 0;
        player.playerIndex = 0;
        player.totalBidAmount = 0;
        player.hasRequestedSeed = false;
    }


    //  TOKEN MANAGEMENT

    // Player > Token > Amount
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

        // Because games require players to have enough tokens to cover the maximumSpend,
        // withdrawals are forbidden while the player is still in a game session.
        if (tokenPlayerStatus[msg.sender][tokenContract].gameId != 0) revert CannotWithdrawDuringGame();

        uint256 balance = depositBalance[msg.sender][tokenContract];
        if (balance == 0) revert ZeroAmount();

        depositBalance[msg.sender][tokenContract] = 0;
        IWithdraw(tokenContract).burnAndWithdraw(msg.sender, balance);

        emit Withdrawn(msg.sender, balance);
    }



    event Received(address, uint256);
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }


    // ERRORS

    error InvalidVRFSeed();
    error InvalidZKP();
    error AlreadyRequestedSeed();
    error AlreadyHaveHand();
    error NotInGame();
    error NotEnoughTimePassed();
    error DoesNotMatchHandHash();

    error InvalidPlayerCount();
    error PlayerAlreadyInGame();
    error PlayerLacksHand();
    error AnteDoesNotMatch();
    error PlayerLacksTokens();
    error InvalidMaximumSpend();

    error GameHasNotStarted();
    error OutOfTime();
    error TooEarly();
    error GameIDNotFound();
    error InvalidRaise();
    error AlreadySwapped();
    error HaveNotSwapped();
    error InvalidHash();
    error AlreadySubmittedScore();
    error GameAlreadyEnded();
    
    error TransferFailed();
    error InsufficientTokensForAnte();
    error InsufficientFundsForVRF();
    error CannotWithdrawDuringGame();

    // EVENTS

    event ProvedHand(address player, uint256 handHash, uint256 playerVRFSeed);
    event StartingNewGame(uint256 gameId);
    event GameStarted(uint256 gameId, uint256 objectiveVRFSeed);
    event SwappingCards(address player, uint256 gameId);
    event ProvedSwap(address player, uint256 gameId, uint256 playerVRFSeed);
    event Raised(address player, uint256 gameId, uint256 amount);
    event Folded(address player, uint256 gameId);
    event PlayedCards(address player, uint256 gameId, uint256[5] cards);
    event GameConcluded(address[] winners, uint256 gameId, uint256 prize);

    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(
        uint256 requestId,
        uint256[] randomWords,
        uint256 payment
    );

    

    // VRF CONFIG
    uint32 public callbackGasLimit = 100000;
    uint16 public requestConfirmations = 3;

    struct RequestStatus {
        uint256 paid; 
        bool fulfilled; 
        uint256[] randomWords;
    }
    
    mapping(uint256 => RequestStatus)
    public s_requests; 

}
