pragma circom 2.0.0;

include "utils/poseidon.circom";
include "PRNGSelect.circom";

// A variant of the swap circuit that introduces the localSeedHash
// as a means of controlling player-contributed entropy.  Instead
// of using a fixed set of seeds, players instead commit a hash of
// their secret random number when requesting VRF for the swap.

// The localSeedHash is then recreated in this circuit to enforce the
// usage of the committed secret number.

template Swap() {
    var handSize = 5;
    var drawSize = 2;
    var deckSize = 21;

    signal input vrfSeed;
    signal input gameToken;

    signal input localSeed;
    signal input localSeedNoise;

    signal input oldCards[handSize];

    signal input indices[drawSize];
    signal input drawNoise[drawSize];

    signal input discardNoise;

    signal output localSeedHash;
    signal output discardedCardHash;
    signal output oldHandHash;
    signal output newHandHash;


    // Hash all cards to get the oldHandHash
    component oldHandHasher = Poseidon(handSize);

    for (var u = 0; u < handSize; u++) {
        oldHandHasher.inputs[u] <== oldCards[u];
    }
    oldHandHash <== oldHandHasher.out;


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


    // Select new cards from the deck.
    component prng = PRNGSelect(drawSize, deckSize, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21]);
    prng._seed <== seedHash;
    var selectedCards[drawSize] = prng.selected;


    component cardHasher[drawSize];
    var cardHashes[drawSize];

    // Hash new cards with noise
    for (var i = 0; i < drawSize; i++) {
        cardHasher[i] = Poseidon(2);
        cardHasher[i].inputs[0] <== selectedCards[i];
        cardHasher[i].inputs[1] <== drawNoise[i];
        cardHashes[i] = cardHasher[i].out;
    }


    component discardedHasher = Poseidon(3);
    discardedHasher.inputs[0] <== indices[0];
    discardedHasher.inputs[1] <== indices[1];
    discardedHasher.inputs[2] <== discardNoise;
    discardedCardHash <== discardedHasher.out;

    var newCards[handSize] = oldCards;

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
            keepOld[loopIndex] <== newCards[k] * (1 - isTarget);

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

