# Finite Field

A game where players draw hands of secret, random cards and try to win the pot by achieving the highest score.  

Randomness is sourced from Chainlink VRF, which is used for drawing cards, and for determining the game objective at the moment the game begins.  

Secrecy is achieved by mixing the Chainlink VRF seed with a seed secretly picked from an allowed set, preventing players from knowing exactly which hand an opponent possesses, only that there is a range of possible hands.  Because players cannot control the Chainlink VRF value, and cannot know beforehand how the game will be scored, the advantage of deliberate hand selection is minimized.  

Zero knowledge proofs enforce the correctness of a card draw, without revealing which seed the player secretly selected.

Chainlink VRF seeds are requested in three places, with three different execution paths:

[NEW_HAND](https://github.com/Cactoidal/FiniteField/blob/ced934101ebb9183e2fdf875c6074fee91945753/contracts/CardGame.sol#L88)

[SWAP_CARDS](https://github.com/Cactoidal/FiniteField/blob/ced934101ebb9183e2fdf875c6074fee91945753/contracts/CardGame.sol#L328)

[GAME_OBJECTIVE](https://github.com/Cactoidal/FiniteField/blob/ced934101ebb9183e2fdf875c6074fee91945753/contracts/CardGame.sol#L231)

VRF fulfillment [viewed here](https://github.com/Cactoidal/FiniteField/blob/ced934101ebb9183e2fdf875c6074fee91945753/contracts/CardGame.sol#L151).


Chainlink VRF seeds are used in the handDraw and swapCards circuits:

[handDraw](https://github.com/Cactoidal/FiniteField/blob/005744db086d22cf108b87446abc52736fb56fd1/circuits/handDraw.circom#L33)

[swapCards](https://github.com/Cactoidal/FiniteField/blob/005744db086d22cf108b87446abc52736fb56fd1/circuits/swapCards.circom#L51)


The ZKPs verifying the usage of Chainlink VRF are then validated on-chain:

[proveHand](https://github.com/Cactoidal/FiniteField/blob/ced934101ebb9183e2fdf875c6074fee91945753/contracts/CardGame.sol#L219)

[proveSwap](https://github.com/Cactoidal/FiniteField/blob/ced934101ebb9183e2fdf875c6074fee91945753/contracts/CardGame.sol#L394)


____

Demo available here:
https://finite-field.vercel.app/

The game contract is deployed on Base Sepolia, and has been configured for 4 players.  The dApp is designed for seamless account switching, allowing you to play against yourself if you wish to do so.  You will need only testnet ETH to play; 0.01 ETH per account is more than sufficient.  

The object of the game is to assemble a hand of cards with face values closest to the random "attractor" value.  The closer a card is to the attractor, the higher its base score.  Cards of the "objective color" are worth double.  Drawing the rare "inverse" card (only possible on a swap) will invert your score.

Games last 4 minutes.  You can freely fold or raise (up to the game's maximumSpend) during those 4 minutes.  You can only initiate a swap during the first 2 minutes of the game, and you must prove the swap during the 4 minute time limit.  

Any players who have not folded after 4 minutes will automatically raise to meet the highest bid.  

Once the game is over, players have 6 minutes to submit a final proof of their hand for scoring.  After those 6 minutes, anyone can "conclude" the game, which will distribute the pot to the player(s) with the highest score.  Players who fail to prove have a score of 0.

NOTE:
When starting a game, you will need to provide an array of valid opponent addresses (as strings, with quotation marks), i.e.:

["0xabc...", "0x123...", "0xa1b..."]

When using Firefox, pasting something into a text box will spawn a small "Paste" modal; click this to update the browser clipboard.
On Chromium/Brave, you can simply paste twice to overwrite whatever was previously in your browser clipboard.
