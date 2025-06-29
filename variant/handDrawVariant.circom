pragma circom 2.0.0;

include "utils/poseidon.circom";
include "PRNGSelect.circom";

// A variant of the hand draw circuit that introduces the localSeedHash
// as a means of controlling player-contributed entropy.  Instead
// of using a fixed set of seeds, players instead commit a hash of
// their secret random number when requesting VRF for the draw.

// The localSeedHash is then recreated in this circuit to enforce the
// usage of the committed secret number.  This entirely removes the ability 
// to manipulate the draw, and prevents players from knowing anything
// about their opponents' cards.

template Hand() {
    var handSize = 5;
    var deckSize = 20;

    signal input vrfSeed;

    signal input localSeed;
    signal input localSeedNoise;

    signal input handNoise[handSize];
    signal input gameToken;

    signal output localSeedHash;
    signal output handHash;

    // The localSeedHash must match the on-chain copy committed when requesting VRF.
    component localSeedHasher = Poseidon(2);
    localSeedHasher.inputs[0] <== localSeed;
    localSeedHasher.inputs[1] <== localSeedNoise;
    localSeedHash <== localSeedHasher.out;

    // Hash the two seeds together.
    component combiner = Poseidon(2);
    combiner.inputs[0] <== vrfSeed;
    combiner.inputs[1] <== localSeed;
    var seedHash = combiner.out;

    // Select cards from the deck.
    component prng = PRNGSelect(handSize, deckSize, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]);
    prng._seed <== seedHash;
    var selectedCards[handSize] = prng.selected;
   
    component cardHasher[handSize];
    var cardHashes[handSize];

    // Hash cards with noise
    for (var i = 0; i < handSize; i++) {
        cardHasher[i] = Poseidon(2);
        cardHasher[i].inputs[0] <== selectedCards[i];
        cardHasher[i].inputs[1] <== handNoise[i];
        cardHashes[i] = cardHasher[i].out;
    }
    
    // Hash all cards to get the handHash
    component handHasher = Poseidon(handSize);

    for (var u = 0; u < handSize; u++) {
        handHasher.inputs[u] <== cardHashes[u];
    }
    handHash <== handHasher.out;
}

component main {public [vrfSeed, gameToken]} = Hand();

