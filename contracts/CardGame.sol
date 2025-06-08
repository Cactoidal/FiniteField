// SPDX-License-Identifier: MIT
// An example of a consumer contract that directly pays for each request.
pragma solidity 0.8.20;

import {ConfirmedOwner} from "@chainlink/contracts@1.4.0/src/v0.8/shared/access/ConfirmedOwner.sol";
import {LinkTokenInterface} from "@chainlink/contracts@1.4.0/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts@1.4.0/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts@1.4.0/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {Groth16VHandVerifier} from "./HandVerify.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";


contract CardGame is VRFV2PlusWrapperConsumerBase, ConfirmedOwner, Groth16VHandVerifier {
   
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(
        uint256 requestId,
        uint256[] randomWords,
        uint256 payment
    );

    struct RequestStatus {
        uint256 paid; 
        bool fulfilled; 
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus)
        public s_requests; 


    uint32 public callbackGasLimit = 100000;
    uint16 public requestConfirmations = 3;

    // SEPOLIA
    address public linkAddress = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    // SEPOLIA
    address public wrapperAddress = 0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1;
    

    uint public ENTRY_PRICE = 0.001 ether;
    mapping (address => bool) public requestedSeed;
    mapping (uint256 => address) public seedRequest;
    mapping (address => uint256) public currentSeed;
    mapping (address => uint256) public currentHand;

    mapping (address => uint256) public governancePower;

    uint256 FIELD_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    
    constructor() 
        ConfirmedOwner(msg.sender)
        VRFV2PlusWrapperConsumerBase(wrapperAddress)
    {}

    function buyHandSeed(address player) payable public {
        //require(!requestedSeed[player]);
        //require(msg.value >= ENTRY_PRICE);

        seedRequest[requestSeed()] = player;
        requestedSeed[player] = true;
        governancePower[player] += calculateGovernancePower();
    }


    function requestSeed() internal returns (uint256) {
        bytes memory extraArgs = VRFV2PlusClient._argsToBytes(
            VRFV2PlusClient.ExtraArgsV1({nativePayment: true})
        );
        uint256 requestId;
        uint256 reqPrice;

        (requestId, reqPrice) = requestRandomnessPayInNative(
            callbackGasLimit,
            requestConfirmations,
            1,
            extraArgs
            );
        
        s_requests[requestId] = RequestStatus({
            paid: reqPrice,
            randomWords: new uint256[](0),
            fulfilled: false
        });
        
        emit RequestSent(requestId, 1);
        
        return requestId;
    }



    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].paid > 0, "request not found");

        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;

        address player = seedRequest[_requestId];
        currentSeed[player] = _randomWords[0];

        emit RequestFulfilled(
            _requestId,
            _randomWords,
            s_requests[_requestId].paid
        );
    }



    function proveHand(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[2] calldata _pubSignals) public {
        require (currentSeed[msg.sender] != 0);

        require (this.verifyProof(_pA, _pB, _pC, _pubSignals));
        
        // Seed used in ZKP must match on-chain VRF seed
        // Apply the BN128 Field Modulus first, otherwise bigger values will not validate correctly
        require (_pubSignals[1] == currentSeed[msg.sender] % FIELD_MODULUS);
        
        // Hand hash cached to be used in card-playing proof
        currentHand[msg.sender] = _pubSignals[0];
    }


    function calculateGovernancePower() internal pure returns(uint256) {
        return 100;
    }


    function getRequestStatus(
        uint256 _requestId
    )
        external
        view
        returns (uint256 paid, bool fulfilled, uint256[] memory randomWords)
    {
        require(s_requests[_requestId].paid > 0, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.paid, request.fulfilled, request.randomWords);
    }

    /**
     * Allow withdraw of Link tokens from the contract
     */
    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(linkAddress);
        require(
            link.transfer(msg.sender, link.balanceOf(address(this))),
            "Unable to transfer"
        );
    }

    /// @notice withdrawNative withdraws the amount specified in amount to the owner
    /// @param amount the amount to withdraw, in wei
    function withdrawNative(uint256 amount) external onlyOwner {
        (bool success, ) = payable(owner()).call{value: amount}("");
        // solhint-disable-next-line gas-custom-errors
        require(success, "withdrawNative failed");
    }


    event Received(address, uint256);
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }


}
