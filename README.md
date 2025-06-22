# Finite Field

A game where players draw hands of secret, random cards and try to win the pot by achieving the highest score.  Randomness is enforced by Chainlink VRF, which is used for drawing cards, and for determining the game objective at the moment the game begins.  Secrecy is achieved by mixing the Chainlink VRF seed with seeds from an allowed set, preventing players from knowing exactly which hand an opponent possesses.  Because players cannot know beforehand how the game will be scored, the advantage of deliberate hand selection is minimized.  Zero knowledge proofs enforce the correctness of a card draw, without revealing which seed the player selected.

Chainlink VRF seeds are requested in three places, with three different execution paths:

HAND_DRAW

SWAP_CARDS

PLAY_CARDS

VRF fulfillment viewed here:


Chainlink VRF seeds are used in the handDraw and swapCards circuits:


The ZKPs verifying the usage of Chainlink VRF are then validated on-chain:

____

Demo available here:
https://finite-field.vercel.app/

The game contract is deployed on Base Sepolia, and has been configured for 4 players.  The dApp is designed for seamless account switching, allowing you to play against yourself if you wish to do so.  You will need only ETH to play; 0.01 ETH per account is more than sufficient.  

The object of the game is to assemble a hand of cards with face values closest to the random "attractor" value.  The closer a card is to the attractor, the higher its base score.  Cards of the "objective color" are worth double.
