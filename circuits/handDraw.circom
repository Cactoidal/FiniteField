pragma circom 2.0.0;

include "utils/poseidon.circom";
include "inSet.circom";
include "PRNGSelect.circom";

// This circuit defines the allowed localSeeds and cardIds.
// Returns the vrfSeed as a public input and the handHash as 
// a public output.

// Proves that the handHash represents a hand composed of valid cards,
// generated using ChainLink VRF and a local seed from a fixed set.

template Hand() {
    signal input vrfSeed;
    signal input fixedSeed;
    signal input nullifiers[5];

    signal output handHash;

    var localSeedCount = 20;
    var handSize = 5;
    var deckSize = 20;

    // fixedSeed must be in the set of allowed local seeds.
    component inSetCheck = InSet(localSeedCount, [1, 3, 7, 9, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71]);
    inSetCheck.checkValue <== fixedSeed;
    inSetCheck.out === 1;

    // Hash the two seeds together.
    component hasher = Poseidon(2);
    hasher.inputs[0] <== vrfSeed;
    hasher.inputs[1] <== fixedSeed;
    var seedHash = hasher.out;

    // Select cards from the deck.
    component prng = PRNGSelect(handSize, deckSize, [1, 3, 7, 9, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71]);
    prng._seed <== seedHash;
    var selectedCards[5] = prng.selected;

   
    component cardHasher[handSize];
    var cardHashes[handSize];

    // Hash cards with nullifiers
    for (var i = 0; i < handSize; i++) {
        cardHasher[i] = Poseidon(2);
        cardHasher[i].inputs[0] <== selectedCards[i];
        cardHasher[i].inputs[1] <== nullifiers[i];
        cardHashes[i] = cardHasher[i].out;
    }
    

    // Hash all cardHashes to get the handHash
    component handHasher = Poseidon(5);
    handHasher.inputs[0] <== cardHashes[0];
    handHasher.inputs[1] <== cardHashes[1];
    handHasher.inputs[2] <== cardHashes[2];
    handHasher.inputs[3] <== cardHashes[3];
    handHasher.inputs[4] <== cardHashes[4];
    
    handHash <== handHasher.out;
}

component main {public [vrfSeed]} = Hand();

