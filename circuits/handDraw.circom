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
    var handSize = 5;
    var deckSize = 20;
    var localSeedCount = 20;

    signal input vrfSeed;
    signal input fixedSeed;
    signal input nullifiers[handSize];
    signal input gameToken;

    signal output handHash;

    // fixedSeed must be in the set of allowed local seeds.
    component inSetCheck = InSet(localSeedCount, [948321578921, 323846237643, 29478234787, 947289484324, 4827847813436, 98432542473237, 56324278238234, 77238476429378, 10927437265398, 32589475384735, 87834727625345, 7723645230273, 298467856729, 233652987328, 2389572388357, 23858923387534, 1242398565735, 6875282937855, 82984325902750, 48547252957635743]);
    inSetCheck.checkValue <== fixedSeed;
    inSetCheck.out === 1;

    // Hash the two seeds together.
    component hasher = Poseidon(2);
    hasher.inputs[0] <== vrfSeed;
    hasher.inputs[1] <== fixedSeed;
    var seedHash = hasher.out;

    // Select cards from the deck.
    component prng = PRNGSelect(handSize, deckSize, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]);
    prng._seed <== seedHash;
    var selectedCards[handSize] = prng.selected;
   
    component cardHasher[handSize];
    var cardHashes[handSize];

    // Hash cards with nullifiers
    for (var i = 0; i < handSize; i++) {
        cardHasher[i] = Poseidon(2);
        cardHasher[i].inputs[0] <== selectedCards[i];
        cardHasher[i].inputs[1] <== nullifiers[i];
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

