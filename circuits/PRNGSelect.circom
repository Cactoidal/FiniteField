pragma circom 2.0.0;

include "utils/poseidon.circom";
include "utils/signal_modulus.circom";
include "selection.circom";

template PRNGSelect(handSize, deckSize, deck) {
    signal input _seed;
    signal output selected[handSize];

    var seed = _seed;

    // Accumulators
    component seedHashes[handSize];
    component modulii[handSize];
    component selection[handSize];
    
    for (var i = 0; i < handSize; i++) {
        seedHashes[i] = Poseidon(1);
        seedHashes[i].inputs[0] <== seed;
        seed = seedHashes[i].out;

        modulii[i] = SignalModulus(deckSize, 20);
        modulii[i].in <== seed;
        var index;
        index = modulii[i].out;

        selection[i] = Selection(deckSize, deck);
        selection[i].index <== index;
        
        selected[i] <== selection[i].out;

    }
}

