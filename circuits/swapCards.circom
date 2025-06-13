pragma circom 2.0.0;

include "utils/poseidon.circom";
include "inSet.circom";
include "PRNGSelect.circom";
include "utils/comparators.circom";

// This circuit takes an existing handHash and updates it with new cards.
// Returns the vrfSeed as a public input, and the oldHandHash and 
// newHandHash as public outputs.  The smart contract must validate that
// the provided oldHandHash matches the on-chain handHash.

// Proves that the newHandHash has been derived by changing cards found
// in the oldHandHash, with randomness generated using ChainLink VRF 
// and a local seed from a fixed set.

// Like the drawHand circuit, contains hardcoded deck and local seed arrays.

template Swap() {
    var handSize = 5;
    var drawSize = 2;
    var deckSize = 20;
    var localSeedCount = 20;

    signal input vrfSeed;
    signal input fixedSeed;
    signal input gameToken;

    signal input oldCards[handSize];

    signal input indices[drawSize];
    signal input nullifiers[drawSize];

    signal input discardNullifier;

    signal output discardedCardHash;
    signal output oldHandHash;
    signal output newHandHash;

    // Hash all cards to get the oldHandHash
    component oldHandHasher = Poseidon(handSize);

    for (var u = 0; u < handSize; u++) {
        oldHandHasher.inputs[u] <== oldCards[u];
    }
    oldHandHash <== oldHandHasher.out;

    // fixedSeed must be in the set of allowed local seeds.
    component inSetCheck = InSet(localSeedCount, [948321578921, 323846237643, 29478234787, 947289484324, 4827847813436, 98432542473237, 56324278238234, 77238476429378, 10927437265398, 32589475384735, 87834727625345, 7723645230273, 298467856729, 233652987328, 2389572388357, 23858923387534, 1242398565735, 6875282937855, 82984325902750, 48547252957635743]);
    inSetCheck.checkValue <== fixedSeed;
    inSetCheck.out === 1;

    // Hash the two seeds together.
    component hasher = Poseidon(2);
    hasher.inputs[0] <== vrfSeed;
    hasher.inputs[1] <== fixedSeed;
    var seedHash = hasher.out;

    // Select new cards from the deck.
    component prng = PRNGSelect(drawSize, deckSize, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]);
    prng._seed <== seedHash;
    var selectedCards[drawSize] = prng.selected;

    component cardHasher[drawSize];
    var cardHashes[drawSize];

    // Hash new cards with nullifiers
    for (var i = 0; i < drawSize; i++) {
        cardHasher[i] = Poseidon(2);
        cardHasher[i].inputs[0] <== selectedCards[i];
        cardHasher[i].inputs[1] <== nullifiers[i];
        cardHashes[i] = cardHasher[i].out;
    }

    component discardedHasher = Poseidon(3);
    discardedHasher.inputs[0] <== indices[0];
    discardedHasher.inputs[1] <== indices[1];
    discardedHasher.inputs[2] <== discardNullifier;
    discardedCardHash <== discardedHasher.out;

    var newCards[handSize];

    var loopSize = handSize * drawSize;
    component eqs[loopSize];

    // Intermediate signals
    signal keepOld[loopSize];
    signal useNew[loopSize];

    // Searches for specified indices and replaces old cards
    // with new cards.  If invalid indices are specified,
    // the hand will simply remain the same.
    for (var j = 0; j < drawSize; j++) {
        for (var k = 0; k < handSize; k++) {
            var loopIndex = k + (j*handSize);
            eqs[loopIndex] = IsEqual();
            eqs[loopIndex].in[0] <== indices[j];
            eqs[loopIndex].in[1] <== k;
            var isTarget = eqs[loopIndex].out;

            // If k is not the specified index, keeps the old hash at 
            // hand index k; otherwise, reduces the hash to zero.
            keepOld[loopIndex] <== oldCards[k] * (1 - isTarget);

            // If k is the specified index, adds the new card found 
            // at draw index j; otherwise, does nothing.
            useNew[loopIndex] <== cardHashes[j] * isTarget;

            // Add the intermediate signals together to get the final result.
            newCards[k] = keepOld[loopIndex] + useNew[loopIndex];
        }
    }
 

    // Hash all cards again to get the newHandHash
    component newHandHasher = Poseidon(handSize);

    for (var x = 0; x < handSize; x++) {
        newHandHasher.inputs[x] <== newCards[x];
    }
    newHandHash <== newHandHasher.out;

}

component main {public [vrfSeed, gameToken]} = Swap();

