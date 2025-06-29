To entirely prevent the player from manipulating their own cards and predicting the opponents' range of cards, we can instead have players commit a "local seed hash" whenever they request Chainlink VRF for a draw or a swap.

The local seed hash is a random secret number combined with some random noise.  In the zero knowledge proof, we can enforce the usage of that random secret number as the local seed by recreating the hash in the circuit.

The circuits and contract in this repository demonstrate how this would be implemented, with few changes to the original logic.

HandDraw
swapCards

Contract functions
