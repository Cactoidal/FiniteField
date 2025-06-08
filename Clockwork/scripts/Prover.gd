extends Control

@onready var ERC20 = Contract.ERC20
@onready var window = EthersWeb.window

var connected_wallet
var listening = false

## ZK 

# Accessed at "window.snarkjs"
var snarkjs_filepath = "res://js/snarkjs.min.js"

# Bridge script between Godot and snarkjs
# Accessed at "window.zkBridge"
var zk_bridge_filepath = "res://js/zk_bridge.js"

# For local Poseidon hashing 
# Accessed at "window.IdenJsCrypto"
var js_crypto_filepath = "res://js/js_crypto.js"

# Required files for proving
var zk_circuit = "res://zk/handDraw.wasm"
var zk_proving_key = "res://zk/handDraw_final.zkey"

# Accessed at "window.witnessCalculatorBuilder"
var witness_calculator_filepath = "res://js/witness_calculator.js"


var SEPOLIA_GAME_CONTRACT_ADDRESS = "0xB7A5A226f19CDD52958572B75Ec427995B215466"
var vrf_seed
var hand_hash

var local_seeds = [1, 3, 7, 9, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71]

func _ready():
	connect_buttons()
	load_and_attach(snarkjs_filepath)
	
	# witness_calculator.js is not a library and needs to be attached to the
	# window using a wrapper (see below)
	load_and_attach(witness_calculator_filepath, "witnessCalculatorBuilder")
	load_and_attach(js_crypto_filepath)
	load_and_attach(zk_bridge_filepath)
	
	# Example for predicting hands locally using different fixed seeds 
	#test_hand()


func connect_buttons():
	$ConnectWallet.connect("pressed", connect_wallet)
	$WalletInfo.connect("pressed", get_wallet_info)

	$GetProof.connect("pressed", get_hand_zk_proof)
	
	$BuyHand.connect("pressed", buy_hand)
	$CalculateHands.connect("pressed", get_vrf_seed)

	EthersWeb.register_transaction_log(self, "receive_tx_receipt")



func connect_wallet():
	var callback = EthersWeb.create_callback(self, "got_account_list")
	EthersWeb.connect_wallet(callback)


func got_account_list(callback):
	if has_error(callback):
		return
		
	connected_wallet = callback["result"][0]
	print_log(connected_wallet + " Connected")
	

func get_wallet_info():
	var callback = EthersWeb.create_callback(self, "show_wallet_info")
	EthersWeb.get_connected_wallet_info(callback)


func show_wallet_info(callback):
	if has_error(callback):
		return
		
	var info =  callback["result"]
	
	var txt = "Address " + info["address"] + "\n"
	txt += "ChainID " + info["chainId"] + "\n"
	txt += "Gas Balance " + info["balance"]
	print_log(txt)


func receive_tx_receipt(tx_receipt):

	var tx_hash = tx_receipt["hash"]
	var status = str(tx_receipt["status"])
	
	var txt = "Tx: " + tx_hash + "\nStatus: " + status
	
	if status == "1":
		var blockNumber = str(tx_receipt["blockNumber"])
		txt += "\nIncluded in block " + blockNumber
	
	print_log(txt)


func print_log(txt):
	$Log.text += txt + "\n___________________________________\n"
	$Log.scroll_vertical = $Log.get_v_scroll_bar().max_value

func has_error(callback):
	if "error_code" in callback.keys():
		var txt = "Error " + str(callback["error_code"]) + ": " + callback["error_message"]
		print_log(txt)
		return true



### SNARKJS


func get_vrf_seed():
	
	var callback = EthersWeb.create_callback(self, "got_vrf_seed")

	var data = EthersWeb.get_calldata(GAME_CONTRACT, "currentSeed", [connected_wallet]) 
	
	EthersWeb.read_from_contract(
		"Ethereum Sepolia",
		SEPOLIA_GAME_CONTRACT_ADDRESS, 
		data,
		callback
		)

func got_vrf_seed(callback):
	if has_error(callback):
		return
	
	vrf_seed = callback["result"][0]
	print_log("VRF Seed: " + vrf_seed)
	calculate_hands()


func calculate_hands():
	var nullifiers = [poseidon([44334434]), poseidon([27842362]), poseidon([27323373]), poseidon([12312987]), poseidon([73248927])]
	for local_seed in local_seeds:
		generate_hand(vrf_seed, local_seed, nullifiers)



# DEBUG
# Test for drawing a hand

# vrfSeed will need to come off the chain, fixedSeed will need to come
# from a set of local seeds, and nullifiers need to be randomly generated.
# Simulated hands will have been generated using all the local seeds, and the
# hand containing the most preferred cards will have been selected.
func get_hand_zk_proof():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
	
	if !vrf_seed:
		print_log("Please get the current seed")
		return
		
	# Parameter names must match circuit inputs' names
	var inputs = {   
	# Must come from the smart contract (will be validated on-chain 
	# using the public input)
	"vrfSeed": vrf_seed,
	
	# Selected from the set of local seeds, chosen because it generates
	# the hand containing the most preferred cards
	"fixedSeed": 11,
	
	# Large, randomized nullifiers will work
	"nullifiers": [poseidon([44334434]), poseidon([27842362]), poseidon([27323373]), poseidon([12312987]), poseidon([73248927])]
  	}
	
	# Must define public_types for the callback
	var public_types  = [
		["uint256"],
		["uint256"]
	]
	
	#var callback = EthersWeb.create_callback(self, "get_proof_calldata", {"public_types": public_types})
	
	calculateProof(inputs, public_types, "proveHand")


# Generlalized function for taking any inputs, circuit, and zkey,
# generating the proof, and sorting the calldata in the callback.
# The types of the public outputs must be defined.
# Optionally, the contract function can be specified, if it is called
# something other than verifyProof.
func calculateProof(_inputs, public_types, function_name="verifyProof"):
	
	var callback = EthersWeb.create_callback(self, "get_proof_calldata", {"public_types": public_types, "function_name": function_name})
	
	var inputs = str(_inputs)
	var circuit_bytes = load_bytes(zk_circuit)
	var key_bytes = load_bytes(zk_proving_key)
	
	window.zkBridge.calculateProof(
		inputs, 
		circuit_bytes.hex_encode(), 
		key_bytes.hex_encode(), 
		EthersWeb.success_callback, 
		EthersWeb.error_callback, 
		callback)



#verifyProof(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[2] calldata _pubSignals)

# The proof returns as an array of length 4.
# At index 0 is point A, an array with two uint256 coordinates.
# At index 1 is point B, two arrays each with two uint256 coordinates.
# At index 2 is point C, an array with two uint256 coordinates.
# At index 3 are the public inputs, an array containing any number of 
# values of different types.

func get_proof_calldata(callback):
	if has_error(callback):
		return
	
	# snarkJS sends the proof back as a string
	var proof = JSON.parse_string("[" + callback["result"] + "]")
	
	var point_types = [["uint256"], ["uint256"]]
	
	var a = get_decoded_array(proof[0], point_types)

	var b = [
		get_decoded_array(proof[1][0], point_types),
		get_decoded_array(proof[1][1], point_types)
		]
		
	var c = get_decoded_array(proof[2], point_types)
	
	var public = []
	var public_count = 0
	
	var function_name = callback["function_name"]
	
	if "public_types" in callback:
		public = get_decoded_array(proof[3], callback["public_types"])
		public_count += proof[3].size()
	
	var decoded_values = [a, b, c, public]
	
	var ABI = [{
		"name": function_name,
		#"name": "verifyProof",
		
		"inputs" : [
		{"type": "uint256[2]"},
		{"type": "uint256[2][2]"},
		{"type": "uint256[2]"},
		{"type": "uint256[" + str(public_count) + "]"}
		]
	}]

	# Ready to send to contract
	var calldata = EthersWeb.get_calldata(ABI, function_name, decoded_values)
	#var calldata = EthersWeb.get_calldata(ABI, "verifyProof", decoded_values)
	
	# DEBUG
	# Will probably split this part into a separate function
	# ETHEREUM SEPOLIA
	
	#var verifier_contract = "0x7bC7120f7c3f6885D6f0ACB0eF71035d13AfE0D8"
	#var verifier_contract = "0x932066b35E4922dAE2Bf3b717628745bd2ea5543"
	
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_CONTRACT_ADDRESS, calldata)
	
	
	print_log("PROOF VALUES:\n" + str(decoded_values) + "\n\n")
	
	
	
	
func get_decoded_array(values, types):
	var length = values.size()
	var n = 0
	var new = []
	while n < length:
		# Use the lowest level .js function because the strings
		# are not padded
		var decoded = Calldata._js_abi_decode(types[n], values[n])
		new.push_back(decoded)
		n += 1
	return new
	


#IdenJsCrypto
func poseidon(_inputs):
	if typeof(_inputs) != 28:
		push_error("Poseidon inputs must be inside an array!")
	var inputs = EthersWeb.arr_to_obj(_inputs)
	return window.zkBridge.poseidonHash(inputs)


### LOAD SCRIPTS

func load_and_attach(path, exported=false):
	var attaching_script = load_script_from_file(path)
	
	# wrapper for witness_calculator.js
	if exported: 
		var wrapper_code = "var module = { exports: {} }; var exports = module.exports;\n"
		attaching_script = wrapper_code + attaching_script + "\nwindow." + exported + "= module.exports;"
		#attaching_script = wrapper_code + attaching_script + "\nwindow.witnessCalculatorBuilder = module.exports;"

	JavaScriptBridge.eval(attaching_script, true)


func load_script_from_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file:
		return file.get_as_text()
	return ""


func load_bytes(path: String) -> PackedByteArray:
	var file = FileAccess.open(path, FileAccess.READ)
	return file.get_buffer(file.get_length())



### GAME

var deck = [1, 3, 7, 9, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71]
var hand_size = 5

func test_hand():
	
	# vrf_seed is not controlled by the player (it must match the VRF
	# seed given on-chain by ChainLink)
	var vrf_seed = "89839320076660362182307967905715657782572128825723119922534927862398646168506"
	
	# fixed_seed is controllable to alter the possible hand you draw, to
	# prevent adversaries from predicting the exact content of your hand
	var fixed_seed = 11
	
	# nullifiers are generated randomly and will be revealed when playing 
	# the cards in your hand
	var nullifiers = [44334434, 27842362, 27323373, 12312987, 73248927]
	generate_hand(vrf_seed, fixed_seed, nullifiers)


# Predict hands using the set of local seeds
func generate_hand(vrf_seed, fixed_seed, nullifiers):
	
	var seed_hash = poseidon([vrf_seed, fixed_seed])
	print(seed_hash)
	
	var picked_cards = []
	
	for drawing in range(hand_size):
		seed_hash = poseidon([seed_hash])
	
		var index = int(window.zkBridge.bigNumberModulus(seed_hash, deck.size()))
	
		picked_cards.push_back(deck[index])
	
	var cards = []
	var card_hashes = []
	
	for card in range(hand_size):
		var poseidon_hash = poseidon([picked_cards[card], nullifiers[card]])
		cards.push_back({
			"card": picked_cards[card],
			"nullifier": nullifiers[card],
			"hash": poseidon_hash
		})
		card_hashes.push_back(poseidon_hash)
	
	var hand_hash = poseidon(card_hashes)
	
	print_log(str(picked_cards))
	#print("CARDS: ")
	#print(cards)
	#print("HAND HASH: ")
	#print(hand_hash)





func buy_hand():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
		
	var calldata = EthersWeb.get_calldata(GAME_CONTRACT, "buyHandSeed", [connected_wallet])
	
	#var verifier_contract = "0x77459F9aDA5E41C80D235e3394CAE04A786B5446"
	
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_CONTRACT_ADDRESS, calldata, "0.001", "220000")
	#EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_CONTRACT_ADDRESS, calldata, "0.001")
	#EthersWeb.send_transaction("Ethereum Sepolia", verifier_contract, calldata, "0.001")



var GAME_CONTRACT = [
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "have",
				"type": "address"
			},
			{
				"internalType": "address",
				"name": "want",
				"type": "address"
			}
		],
		"name": "OnlyVRFWrapperCanFulfill",
		"type": "error"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": true,
				"internalType": "address",
				"name": "from",
				"type": "address"
			},
			{
				"indexed": true,
				"internalType": "address",
				"name": "to",
				"type": "address"
			}
		],
		"name": "OwnershipTransferRequested",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": true,
				"internalType": "address",
				"name": "from",
				"type": "address"
			},
			{
				"indexed": true,
				"internalType": "address",
				"name": "to",
				"type": "address"
			}
		],
		"name": "OwnershipTransferred",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": false,
				"internalType": "address",
				"name": "",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			}
		],
		"name": "Received",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "requestId",
				"type": "uint256"
			},
			{
				"indexed": false,
				"internalType": "uint256[]",
				"name": "randomWords",
				"type": "uint256[]"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "payment",
				"type": "uint256"
			}
		],
		"name": "RequestFulfilled",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "requestId",
				"type": "uint256"
			},
			{
				"indexed": false,
				"internalType": "uint32",
				"name": "numWords",
				"type": "uint32"
			}
		],
		"name": "RequestSent",
		"type": "event"
	},
	{
		"inputs": [],
		"name": "acceptOwnership",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "player",
				"type": "address"
			}
		],
		"name": "buyHandSeed",
		"outputs": [],
		"stateMutability": "payable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "uint256[2]",
				"name": "_pA",
				"type": "uint256[2]"
			},
			{
				"internalType": "uint256[2][2]",
				"name": "_pB",
				"type": "uint256[2][2]"
			},
			{
				"internalType": "uint256[2]",
				"name": "_pC",
				"type": "uint256[2]"
			},
			{
				"internalType": "uint256[2]",
				"name": "_pubSignals",
				"type": "uint256[2]"
			}
		],
		"name": "proveHand",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "uint256",
				"name": "_requestId",
				"type": "uint256"
			},
			{
				"internalType": "uint256[]",
				"name": "_randomWords",
				"type": "uint256[]"
			}
		],
		"name": "rawFulfillRandomWords",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "to",
				"type": "address"
			}
		],
		"name": "transferOwnership",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"stateMutability": "payable",
		"type": "receive"
	},
	{
		"inputs": [],
		"name": "withdrawLink",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "uint256",
				"name": "amount",
				"type": "uint256"
			}
		],
		"name": "withdrawNative",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [],
		"stateMutability": "nonpayable",
		"type": "constructor"
	},
	{
		"inputs": [],
		"name": "callbackGasLimit",
		"outputs": [
			{
				"internalType": "uint32",
				"name": "",
				"type": "uint32"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			}
		],
		"name": "currentHand",
		"outputs": [
			{
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			}
		],
		"name": "currentSeed",
		"outputs": [
			{
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "ENTRY_PRICE",
		"outputs": [
			{
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "getBalance",
		"outputs": [
			{
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "getLinkToken",
		"outputs": [
			{
				"internalType": "contract LinkTokenInterface",
				"name": "",
				"type": "address"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "uint256",
				"name": "_requestId",
				"type": "uint256"
			}
		],
		"name": "getRequestStatus",
		"outputs": [
			{
				"internalType": "uint256",
				"name": "paid",
				"type": "uint256"
			},
			{
				"internalType": "bool",
				"name": "fulfilled",
				"type": "bool"
			},
			{
				"internalType": "uint256[]",
				"name": "randomWords",
				"type": "uint256[]"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			}
		],
		"name": "governancePower",
		"outputs": [
			{
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "i_vrfV2PlusWrapper",
		"outputs": [
			{
				"internalType": "contract IVRFV2PlusWrapper",
				"name": "",
				"type": "address"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "linkAddress",
		"outputs": [
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "owner",
		"outputs": [
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "requestConfirmations",
		"outputs": [
			{
				"internalType": "uint16",
				"name": "",
				"type": "uint16"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			}
		],
		"name": "requestedSeed",
		"outputs": [
			{
				"internalType": "bool",
				"name": "",
				"type": "bool"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			}
		],
		"name": "s_requests",
		"outputs": [
			{
				"internalType": "uint256",
				"name": "paid",
				"type": "uint256"
			},
			{
				"internalType": "bool",
				"name": "fulfilled",
				"type": "bool"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			}
		],
		"name": "seedRequest",
		"outputs": [
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "uint256[2]",
				"name": "_pA",
				"type": "uint256[2]"
			},
			{
				"internalType": "uint256[2][2]",
				"name": "_pB",
				"type": "uint256[2][2]"
			},
			{
				"internalType": "uint256[2]",
				"name": "_pC",
				"type": "uint256[2]"
			},
			{
				"internalType": "uint256[2]",
				"name": "_pubSignals",
				"type": "uint256[2]"
			}
		],
		"name": "verifyProof",
		"outputs": [
			{
				"internalType": "bool",
				"name": "",
				"type": "bool"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "wrapperAddress",
		"outputs": [
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			}
		],
		"stateMutability": "view",
		"type": "function"
	}
]
