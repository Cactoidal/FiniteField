pragma circom 2.0.0;

include "utils/poseidon.circom";
include "inSet.circom";
include "PRNGSelect.circom";

// Given a set of nullifiers and cards, produces a handHash 
// and outputs the set of cards.  Validate the handHash on-chain against
// the recorded handHash.

template Play() {
    var handSize = 5;

    signal input nullifiers[handSize];
    signal input cards[handSize];

    signal output handHash;

    component cardHasher[handSize];
    var cardHashes[handSize];

    // Hash cards with nullifiers
    for (var i = 0; i < handSize; i++) {
        cardHasher[i] = Poseidon(2);
        cardHasher[i].inputs[0] <== cards[i];
        cardHasher[i].inputs[1] <== nullifiers[i];
        cardHashes[i] = cardHasher[i].out;
    }

    // Hash all cardHashes to get the handHash
    component handHasher = Poseidon(handSize);

    for (var x = 0; x < handSize; x++) {
        handHasher.inputs[x] <== cardHashes[x];
    }
    handHash <== handHasher.out;

}

component main {public [cards]} = Play();

