pragma circom 2.0.0;

include "utils/comparators.circom";

template Selection(deckSize, deck) {
    signal input index;
    signal output out;

    component selectors[deckSize];
    var selectedList[deckSize];

    // Find the matching index and add it to the
    // selectedList accumulator
    for (var j = 0; j < deckSize; j++) {
            selectors[j] = IsEqual();
            selectors[j].in[0] <== index;
            selectors[j].in[1] <== j;
            selectedList[j] = deck[j] * selectors[j].out;
        }

        // Sum the values in selectedList to get the 
        // actual selected value
    var card = 0;
    for (var k = 0; k < deckSize; k++) {
            card = card + selectedList[k];
        }
        
    out <== card;

}


