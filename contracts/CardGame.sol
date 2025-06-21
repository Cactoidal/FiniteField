// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts@1.4.0/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts@1.4.0/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {IVRFWrapper} from "./interfaces/IVRFWrapper.sol";
import {IWithdraw} from "./interfaces/IWithdraw.sol";
import {IZKPVerifier} from "./interfaces/IZKPVerifier.sol";

contract CardGame is VRFV2PlusWrapperConsumerBase, ReentrancyGuard {

    // CONSTANTS
    uint8 constant TIME_LIMIT = 240;
    uint16 constant END_LIMIT = 600; 
    
    uint8 constant TABLE_SIZE = 4;

    // The Scalar Field size used by Circom.
    // Because VRF seeds can sometimes exceed this value, it must be applied as a modulus to the on-chain
    // seed before validating it against the proof's public output.
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
        address[TABLE_SIZE] exited;
        uint256[TABLE_SIZE] scores;
        uint256[TABLE_SIZE] vrfSwapSeeds;
        uint256[TABLE_SIZE] discardedCards;
        bool[TABLE_SIZE] completedSwap;
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


    // Player address > GameToken contract > playerStatus
    mapping (address => mapping(address => playerStatus)) public tokenPlayerStatus;
    mapping (uint256 => vrfRequest) public pendingVRFRequest;
    mapping (uint256 => game) public gameSessions;
    uint256 public latestGameId = 1;


    // CONSTRUCTOR ADDRESSES
    
    // BASE SEPOLIA
    address vrfWrapperAddress = 0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed;
    address handZKPVerifier = 0x4F42DE06d0789dD5C280B11F8B47749403f9D26a;
    address swapZKPVerifier = 0x03406057c8EB0531A7cd9edFEbFe12269329cc49;
    address playZKPVerifier = 0x0DCE3ECE63594bae4AB4eDfBc4a11B609fCBCeAf;

    constructor() 
        VRFV2PlusWrapperConsumerBase(vrfWrapperAddress)
    {}

    // Players must commit to a specific token and a specific ante when buying
    // a Chainlink VRF seed.
    function buyHandSeed(address playerAddress, address gameToken, uint256 ante) payable public nonReentrant {
        if (playerAddress == address(0)) revert ZeroAddress();
        if (ante == 0) revert ZeroAmount();

        playerStatus storage player = tokenPlayerStatus[playerAddress][gameToken];
        
        // Cannot request new seed for this token until the previous one has been used in a game.
        if (player.hasRequestedSeed) revert AlreadyRequestedSeed();

        // The ante is an upfront cost for a seed; the seed is only eligible for use in 
        // games with the same ante.
        if (depositBalance[playerAddress][gameToken] < ante) revert InsufficientTokensForAnte();
        
        player.hasRequestedSeed = true;
        player.ante = ante; 

        depositBalance[playerAddress][gameToken] -= ante;
        
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


    // The VRF callback has three execution paths: 
    // NEW_HAND, SWAP_CARDS, and GAME_OBJECTIVE
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
            vrfRequest storage request = pendingVRFRequest[_requestId];
            address playerAddress = request.requester;
            address gameToken = request.gameToken;

            // The VRF seed for drawing a new hand has been recorded; the player 
            // may now use it to generate a ZKP linked to a secret hand.
            tokenPlayerStatus[playerAddress][gameToken].vrfSeed = vrfSeed;
        }

        else if (requestType == vrfRequestType.SWAP_CARDS) {
            vrfRequest storage request = pendingVRFRequest[_requestId];
            uint256 gameId = request.gameId;
            uint256 playerIndex = request.playerIndex;

            // This VRF seed can be used to swap out 2 cards and generate
            // a new ZKP linked to the modified hand.
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


    // Commit a hash linked to a secret hand, proving it was drawn from the approved deck,
    // using a Chainlink VRF seed combined with a secret seed from a fixed set
    function proveHand(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[3] calldata _pubSignals) public nonReentrant {
        address gameToken = address(uint160(_pubSignals[2]));
        playerStatus storage player = tokenPlayerStatus[msg.sender][gameToken];
        uint256 playerVRFSeed = player.vrfSeed;

        if (playerVRFSeed == 0) revert InvalidVRFSeed();
        if (player.currentHand != 0) revert AlreadyHaveHand();

        // Validate the proof.
        if (!IZKPVerifier(handZKPVerifier).verifyHandProof(_pA, _pB, _pC, _pubSignals)) revert InvalidZKP();
        
        // Seed used in ZKP must match on-chain VRF seed
        // Apply the modulus first, otherwise bigger values will not validate correctly
        if (_pubSignals[1] != playerVRFSeed % FIELD_MODULUS) revert InvalidVRFSeed();
        
        // Hand hash cached for use in game
        player.currentHand = _pubSignals[0];
        
        emit ProvedHand(msg.sender, _pubSignals[0], playerVRFSeed);
    }


    // Initiate another Chainlink VRF call to determine the objective of the game
    // (the scoring criteria, i.e. the target card number and suit).  The VRF
    // callback will start the game.
    function startGame(address _gameToken, uint256 _ante, uint256 _maximumSpend, address[TABLE_SIZE] calldata players) payable public nonReentrant {
        address gameToken = _gameToken;
        uint256 ante = _ante;
        uint256 maximumSpend = _maximumSpend;

        if (ante == 0) revert ZeroAmount();


        // Check if all players are eligible to play
        for (uint i = 0; i < TABLE_SIZE; i++) {
            address playerAddress = players[i];
            if (playerAddress == address(0)) revert ZeroAddress();

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


    // Players can raise up to the game's maximumSpend. 
    // Only callable during the first 4 minutes of a game
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

        // Add to the pot
        session.totalPot += amount;

        // Update the game state if new totalBidAmount exceeds previous high bid
        if (player.totalBidAmount > session.highBid) {
            session.highBid = player.totalBidAmount;
        }
    
        emit Raised(msg.sender, gameId, amount);
    }

    // Exit a game early by folding.
    // Only callable during the first 4 minutes of a game
    function fold(address gameToken) public {
        // Check if the player is eligible to fold.
        playerStatus storage player = tokenPlayerStatus[msg.sender][gameToken];
        uint gameId = player.gameId;
        if (gameId == 0) revert GameIDNotFound();
        if (!withinTimeLimit(gameId, TIME_LIMIT)) revert OutOfTime();

        // Exit the game.
        clearPlayerStatus(gameId, msg.sender);

        emit Folded(msg.sender, gameId);
    }

    // Swap 2 cards by committing the hash of the discarded card indices.  
    // This will initiate another Chainlink VRF call, which will be used 
    // to draw 2 new cards.
    // Only callable during the first 2 minutes of the game
    function swapCards(address gameToken, uint256 discardedCardsHash) public payable {
        // Check if the player is eligible to swap cards.
        playerStatus storage player = tokenPlayerStatus[msg.sender][gameToken];
        uint gameId = player.gameId;
        if (gameId == 0) revert GameIDNotFound();
        if (!withinTimeLimit(gameId, TIME_LIMIT - 120)) revert OutOfTime();

        uint256 playerIndex = player.playerIndex;
        game storage session = gameSessions[gameId];

        // A player can only swap cards once per game.
        if (session.discardedCards[playerIndex] != 0) revert AlreadySwapped();

        if (discardedCardsHash == 0) revert InvalidDiscard();

        // A Poseidon hash of the discarded card indices is committed,
        // to be later validated against the ZKP's public output.
        session.discardedCards[playerIndex] = discardedCardsHash;

        // Call VRF.
        uint256 requestId = requestSeed();

        // Record the VRF callback arguments.
        vrfRequest storage request = pendingVRFRequest[requestId];
        request.requestType = vrfRequestType.SWAP_CARDS;
        request.gameId = gameId;
        request.playerIndex = playerIndex;

        // Transfer any extra ETH back to the caller.
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        if (!success) revert TransferFailed();

        emit SwappingCards(msg.sender, gameId);

    }

    // Update your hand hash by proving you possessed cards matching the previous hand hash, that you
    // discarded the cards at the pre-specified indices, and that the Chainlink VRF seed was used
    // to draw the new cards.
    // Only callable during the first 4 minutes of the game
    function proveSwapCards(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[5] calldata _pubSignals) public {
        
        // Check that the player is eligible to prove the swap.
        address gameToken = address(uint160(_pubSignals[4]));

        playerStatus storage player = tokenPlayerStatus[msg.sender][gameToken];
        uint gameId = player.gameId;
        if (gameId == 0) revert GameIDNotFound();
        if (!withinTimeLimit(gameId, TIME_LIMIT)) revert OutOfTime();

        game storage session = gameSessions[gameId];
        // The player must have requested a VRF seed to swap cards.
        uint256 vrfSwapSeed = session.vrfSwapSeeds[player.playerIndex];
        if (vrfSwapSeed == 0) revert HaveNotSwapped();
        
        // Validate the proof.
        if (!IZKPVerifier(swapZKPVerifier).verifySwapProof(_pA, _pB, _pC, _pubSignals)) revert InvalidZKP();

        // Validate the discarded cards against the committed hash.
        if (session.discardedCards[player.playerIndex] != _pubSignals[0]) revert InvalidDiscard();

        // Validate against old hand
        if (player.currentHand != _pubSignals[1]) revert InvalidHash();

        // Validate VRF seed
        // Must apply modulus for large numbers to validate correctly
        if (_pubSignals[3] != vrfSwapSeed % FIELD_MODULUS) revert InvalidVRFSeed();

        // Update to new hand
        player.currentHand = _pubSignals[2];

        // Mark that the player has completed the swap.
        session.completedSwap[player.playerIndex] = true;

        emit ProvedSwap(msg.sender, gameId, vrfSwapSeed);
    }
    

    // Once the game ends, to score your cards, you must prove that your hand 
    // is linked to your on-chain hand hash.
    // Only callable after the first 4 minutes, before 10 minutes have elapsed
    function provePlayCards(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[7] calldata _pubSignals) public {

        // Check that the player is eligible to reveal their cards
        address gameToken = address(uint160(_pubSignals[6]));
        playerStatus storage player = tokenPlayerStatus[msg.sender][gameToken];
        uint gameId = player.gameId;
        if (gameId == 0) revert GameIDNotFound();
        if (withinTimeLimit(gameId, TIME_LIMIT)) revert TooEarly();
        if (!withinTimeLimit(gameId, END_LIMIT)) revert OutOfTime();
        
        uint256 playerIndex = player.playerIndex;
        game storage session = gameSessions[gameId];
        if (session.scores[playerIndex] != 0) revert AlreadySubmittedScore();

        // Validate the proof.
        if (!IZKPVerifier(playZKPVerifier).verifyPlayProof(_pA, _pB, _pC, _pubSignals)) revert InvalidZKP();

        // Validate against hand hash.
        if (_pubSignals[0] != player.currentHand) revert InvalidHash();
        
        // If the player swapped, make sure they proved the swap.
        if (session.vrfSwapSeeds[playerIndex] != 0) {
            if (!session.completedSwap[playerIndex]) revert HaveNotSwapped();
        }

        // Get the score
        uint256[5] memory cards = [_pubSignals[1], _pubSignals[2], _pubSignals[3], _pubSignals[4], _pubSignals[5]];
        uint256 score = scoreHand(session.objectiveSeed, cards);
        
        // Update the score array
        session.scores[playerIndex] = score;

        // Match the high bid
        uint256 diff =  session.highBid - player.totalBidAmount;
        depositBalance[msg.sender][gameToken] -= diff;
        session.totalPot += diff;

        // Exit the game
        clearPlayerStatus(gameId, msg.sender);

        emit PlayedCards(msg.sender, gameId, cards);
    }


    // Distribute prizes to the winners and eject any AFK players from the game.
    // Only callable after 10 minutes have elapsed
    function concludeGame(uint256 gameId) public nonReentrant {

        game storage session = gameSessions[gameId];
        address gameToken = session.gameToken;
     
        // If no gameToken is recorded, the session doesn't exist
        if (gameToken == address(0)) revert GameIDNotFound();
        if (withinTimeLimit(gameId, END_LIMIT)) revert TooEarly();
        if (session.hasConcluded) revert GameAlreadyEnded();

        session.hasConcluded = true;

        uint[TABLE_SIZE] memory scores = session.scores;
        address[TABLE_SIZE] memory players = session.players;
        address[TABLE_SIZE] memory exited = session.exited;
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
            address playerAddress = players[j];

            // If the player did not prove or fold, make sure
            // they have automatched the high bid. 
            // It must be done in this step, otherwise players 
            // could wait to see what other players reveal
            // during the proving phase, and dodge paying
            // the highBid if their hand isn't a winner.
            if (exited[j] != playerAddress) {
                playerStatus storage player = tokenPlayerStatus[playerAddress][gameToken];
                uint256 diff =  highBid - player.totalBidAmount;
                depositBalance[playerAddress][gameToken] -= diff;
                session.totalPot += diff;

                // Remove AFK players from the game.  Only players who have
                // failed to fold or prove by this point would still have
                // a gameId matching the game session Id.
                if (player.gameId == gameId) {
                    clearPlayerStatus(gameId, playerAddress);
                }
            }
            
            // Get the winners
            if (scores[j] == highScore) {
                winners.push(playerAddress);
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



    // Cards have a face number of 1-10, and are colored blue or silver.

    // Cards have a base score determined by their proximity to the "attractor" number, 
    // which is randomly selected each game.  Cards of the objective color are valued double.
    function scoreHand(uint256 objVRFSeed, uint256[5] memory cards) public pure returns(uint256) {
        (uint256 objAttractor, uint256 objColor) = getObjective(objVRFSeed);

        // The score will be inverted if the hand contains
        // one inverse card (card #21).
        bool inverse = false;
        for (uint j = 0; j < 5; j++) {
            if (cards[j] == 21) {
                if (inverse == false) {
                    inverse = true;
                }
                else {
                    inverse = false;
                }
            }
        }

        // Right now the maximum score is 100,
        // so could fit into a uint8 if desired
        uint256 score = 0;

        for (uint i = 0; i < 5; i++) {
            uint256 card = cards[i];
            uint8 cardColor = 1;
            if (card > 10) {
                cardColor = 2;

                // Shim for 11-21
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

            // Inverse cards have no suit color and are
            // not affected by the attractor
            if (card == 11) {
                score += 11;
            }
            else {
            // Cards closest to the attractor have a higher base score;
            // cards of the objective color have their base score multiplied by 2
                score += (10 - diff) * colorBonus;
            }
        }

        if (inverse) {
            score = 100 - score;
        }

        return score;

    }

    function getObjective(uint256 vrfSeed) public pure returns(uint256, uint256) {
        uint attractor = (vrfSeed % 10) + 1;
        uint color = (vrfSeed % 2) + 1;

        return (attractor, color);
    }

    // Players manually remove themselves from a game when they fold or prove their hand;
    // AFK players are also automatically removed when a game is concluded.
    function clearPlayerStatus(uint256 _gameId, address _playerAddress) internal {
        uint256 gameId = _gameId;
        address playerAddress = _playerAddress;
        game storage session = gameSessions[gameId];
        address gameToken = gameSessions[gameId].gameToken;

        if (session.gameToken == address(0)) revert GameIDNotFound();
        if (playerAddress == address(0)) revert ZeroAddress();

        playerStatus storage player = tokenPlayerStatus[playerAddress][gameToken];
        if (player.gameId != gameId) revert GameIDNotFound();

        // Mark that the player has exited the game.
        session.exited[player.playerIndex] = _playerAddress;

        // Reset the player's state
        player.vrfSeed = 0;
        player.ante = 0;
        player.currentHand = 0;
        player.gameId = 0;
        player.playerIndex = 0;
        player.totalBidAmount = 0;
        player.hasRequestedSeed = false;
    }


    // Used by Godot to monitor player states during the game
    function getAllPlayers(uint gameId) public view returns(
        address[TABLE_SIZE] memory, 
        address[TABLE_SIZE] memory, 
        uint256[TABLE_SIZE] memory,
        uint256[TABLE_SIZE] memory,
        uint256[TABLE_SIZE] memory, 
        bool[TABLE_SIZE] memory,
        uint256 totalPot,
        uint256 highBid) 
        {
        game storage session = gameSessions[gameId];

        address gameToken = session.gameToken;
        address[TABLE_SIZE] memory players;
        address[TABLE_SIZE] memory exited;
        uint256[TABLE_SIZE] memory vrfSwapSeeds;
        uint256[TABLE_SIZE] memory scores;
        uint256[TABLE_SIZE] memory totalBids;
        bool[TABLE_SIZE] memory hasSwapped;

        for (uint i = 0; i < TABLE_SIZE; i++) {
            players[i] = session.players[i];
            exited[i] = session.exited[i];
            vrfSwapSeeds[i] = session.vrfSwapSeeds[i];
            scores[i] = session.scores[i];
            totalBids[i] = tokenPlayerStatus[players[i]][gameToken].totalBidAmount;
            hasSwapped[i] = session.completedSwap[i];
        }

        return (players, exited, vrfSwapSeeds, scores, totalBids, hasSwapped, session.totalPot, session.highBid);
    }


    //  TOKEN MANAGEMENT

    // Player > Token > Amount
    mapping (address => mapping (address => uint256)) public depositBalance;

    error NotGameToken();
    error ZeroAddress();
    error ZeroAmount();
    event Deposited(address indexed tokenContract, address indexed recipient, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    function depositGameToken(address tokenContract, address player, uint256 amount) external nonReentrant {
        if (!IWithdraw(tokenContract).isGameToken()) revert NotGameToken();
        if (amount == 0) revert ZeroAmount();
        if (player == address(0)) revert ZeroAddress();

        IERC20(tokenContract).transferFrom(tokenContract, address(this), amount);
        depositBalance[player][tokenContract] += amount;

        emit Deposited(tokenContract, player, amount);
    }


    function withdrawGameToken(address tokenContract) public nonReentrant {
        if (!IWithdraw(tokenContract).isGameToken()) revert NotGameToken();

        // Because games require players to have enough tokens to cover the maximumSpend,
        // withdrawals of the gameToken are forbidden while the player is still in a game session.
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
    error InvalidDiscard();
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
    uint32 public callbackGasLimit = 300000;
    uint16 public requestConfirmations = 1;

    struct RequestStatus {
        uint256 paid; 
        bool fulfilled; 
        uint256[] randomWords;
    }
    
    mapping(uint256 => RequestStatus)
    public s_requests; 

}
