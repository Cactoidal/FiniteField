// SPDX-License-Identifier: MIT
// An example of a consumer contract that directly pays for each request.
pragma solidity 0.8.20;

interface IZKPVerifier {

    function verifyHandProof(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[3] calldata _pubSignals) view external returns(bool);

    function verifySwapProof() view external returns(bool);

    function verifyPlayProof() view external returns(bool);

}
