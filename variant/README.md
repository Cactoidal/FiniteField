To entirely prevent the player from manipulating their own cards and predicting the opponents' range of cards, rather than using an allowed set of seeds, we can instead have players commit a "local seed hash" whenever they request Chainlink VRF for a draw or a swap.

The local seed hash is a random secret number combined with some random noise.  In the zero knowledge proof, we can enforce the usage of that random secret number as the local seed by recreating the hash in the circuit.

Because the secret local seed is committed before the player receives the Chainlink VRF value, the player is bound to a single secret outcome, and cannot alter that outcome.  The number of possible seeds is also vastly increased, preventing prediction of which cards an opponent might draw.

The circuits and contract in this directory demonstrate how this would be implemented, with few changes to the original logic.
_____

Committing the localSeedHash to the smart contract when requesting VRF:

[buyHandSeed](https://github.com/Cactoidal/FiniteField/blob/eeea7fd97fee5a209710b30396191210a49f7cf9/variant/CardGameVariant.sol#L103)

[swapCards](https://github.com/Cactoidal/FiniteField/blob/eeea7fd97fee5a209710b30396191210a49f7cf9/variant/CardGameVariant.sol#L356)

Enforcing usage of the committed local seed, mixed with the Chainlink VRF value:

[handDraw](https://github.com/Cactoidal/FiniteField/blob/eeea7fd97fee5a209710b30396191210a49f7cf9/variant/handDrawVariant.circom#L31)

[swapCards](https://github.com/Cactoidal/FiniteField/blob/eeea7fd97fee5a209710b30396191210a49f7cf9/variant/swapCardsVariant.circom#L47)

Checking the public output of the circuit against the on-chain copy of the localSeedHash:

[proveHand](https://github.com/Cactoidal/FiniteField/blob/eeea7fd97fee5a209710b30396191210a49f7cf9/variant/CardGameVariant.sol#L221)

[proveSwapCards](https://github.com/Cactoidal/FiniteField/blob/eeea7fd97fee5a209710b30396191210a49f7cf9/variant/CardGameVariant.sol#L400)
