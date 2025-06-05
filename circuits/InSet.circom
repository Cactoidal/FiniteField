pragma circom 2.0.0;

include "utils/comparators.circom";

template InSet(length, values) {
    signal input checkValue;
    signal output out;


    component eqs[length];
    signal matches[length];

    for (var i = 0; i < length; i++) {
        eqs[i] = IsEqual();
        eqs[i].in[0] <== checkValue;
        eqs[i].in[1] <== values[i];
        matches[i] <== eqs[i].out;
    }

    // Sum all matches (should be 1 if there's a match, 0 otherwise)
    var sum = 0;
    for (var i = 0; i < length; i++) {
        sum = sum + matches[i];
    }

    // Output is 1 if in the set, 0 otherwise
    out <== sum;
}