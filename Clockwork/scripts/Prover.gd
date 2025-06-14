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

# The Scalar Field size used by Circom.
var FIELD_MODULUS = "21888242871839275222246405745257275088548364400416034343698204186575808495617"


# To create proofs, 3 files are required:
var handDraw_zk_circuit = "res://zk/handDraw.wasm"
var handDraw_zk_proving_key = "res://zk/handDraw_final.zkey"
# Accessed at window.handDrawWitnessCalculator
var handDraw_witness_calculator_filepath = "res://js/handDraw_witness_calculator.js"

var swapCards_zk_circuit = "res://zk/swapCards.wasm"
var swapCards_zk_proving_key = "res://zk/swapCards_final.zkey"
var swapCards_witness_calculator_filepath = "res://js/swapCards_witness_calculator.js"

var playCards_zk_circuit = "res://zk/playCards.wasm"
var playCards_zk_proving_key = "res://zk/playCards_final.zkey"
var playCards_witness_calculator_filepath = "res://js/playCards_witness_calculator.js"

func _ready():
	connect_buttons()
	load_and_attach(snarkjs_filepath)
	
	# witness_calculator.js files need to be attached to the
	# window using a wrapper (see below) and later passed as an object
	load_and_attach(handDraw_witness_calculator_filepath, "handDrawWitnessCalculator")
	load_and_attach(swapCards_witness_calculator_filepath, "swapCardsWitnessCalculator")
	load_and_attach(playCards_witness_calculator_filepath, "playCardsWitnessCalculator")
	
	load_and_attach(js_crypto_filepath)
	load_and_attach(zk_bridge_filepath)
	
	# DEBUG
	# Decode error messages by comparing them to keccak hashes of errors
	#print(window.walletBridge.getFunctionSelector("GameHasNotStarted()"))


func connect_buttons():
	$ConnectWallet.connect("pressed", connect_wallet)
	$WalletInfo.connect("pressed", get_wallet_info)

	$ProveHand.connect("pressed", get_hand_zk_proof)
	
	$BuySeed.connect("pressed", buy_seed)
	$CalculateHands.connect("pressed", get_vrf_seed)
	
	$MintAndDeposit.connect("pressed", mint_and_deposit)
	$WithdrawETH.connect("pressed", withdraw_eth)
	
	$StartGame.connect("pressed", start_game)
	$Raise.connect("pressed", raise)
	$SwapCards.connect("pressed", swap_cards)
	$Fold.connect("pressed", fold)
	$ConcludeGame.connect("pressed", conclude_game)
	
	$ProveSwap.connect("pressed", prove_swap)
	$PlayCards.connect("pressed", prove_play_cards)
	

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

# Generalized function for taking any inputs, circuit, and zkey,
# generating the proof, and sorting the calldata in the callback.
# The types of the public outputs must be defined.
# Optionally, the contract function can be specified, if it is called
# something other than verifyProof.
func calculateProof(_inputs, public_types, zk_circuit, zk_proving_key, witness_calculator, function_name="verifyProof"):
	
	var callback = EthersWeb.create_callback(self, "get_proof_calldata", {"public_types": public_types, "function_name": function_name})
	
	var inputs = str(_inputs)
	var circuit_bytes = load_bytes(zk_circuit)
	var key_bytes = load_bytes(zk_proving_key)
	
	window.zkBridge.calculateProof(
		inputs, 
		circuit_bytes.hex_encode(), 
		key_bytes.hex_encode(),
		witness_calculator, 
		EthersWeb.success_callback, 
		EthersWeb.error_callback, 
		callback)



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
		
		"inputs" : [
		{"type": "uint256[2]"},
		{"type": "uint256[2][2]"},
		{"type": "uint256[2]"},
		{"type": "uint256[" + str(public_count) + "]"}
		]
	}]

	# Ready to send to contract
	var calldata = EthersWeb.get_calldata(ABI, function_name, decoded_values)

	
	# DEBUG
	# Will probably split this part into a separate function
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
	


##  IdenJsCrypto
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

	JavaScriptBridge.eval(attaching_script, true)


func load_script_from_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file:
		return file.get_as_text()
	return ""


func load_bytes(path: String) -> PackedByteArray:
	var file = FileAccess.open(path, FileAccess.READ)
	return file.get_buffer(file.get_length())





### GAME VARIABLES

# Game Logic
var SEPOLIA_GAME_CONTRACT_ADDRESS = "0xBF2282CF0aAed8ac9A44787a33Ad9642c37e5a36"

# Token
var SEPOLIA_GAME_TOKEN_ADDRESS = "0x9acF3472557482091Fe76c2D08F82819Ab9a28eb"

var local_seeds = [948321578921, 323846237643, 29478234787, 947289484324, 4827847813436, 98432542473237, 56324278238234, 77238476429378, 10927437265398, 32589475384735, 87834727625345, 7723645230273, 298467856729, 233652987328, 2389572388357, 23858923387534, 1242398565735, 6875282937855, 82984325902750, 48547252957635743]

var deck = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
var hand_size = 5

var ante = "100"
var maximum_spend = "1000"

var vrf_seed
var hand_hash
var discarded_cards
var game_id = 5



## NEW HAND FUNCTIONS

func buy_seed():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
	
	var calldata = EthersWeb.get_calldata(GAME_CONTRACT_ABI, "buyHandSeed", [connected_wallet, SEPOLIA_GAME_TOKEN_ADDRESS, ante])
	
	# Gas limit must be specified because ethers.js will underestimate
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_CONTRACT_ADDRESS, calldata, "0.002", "260000")



func get_vrf_seed():
	var callback = EthersWeb.create_callback(self, "got_vrf_seed")

	var data = EthersWeb.get_calldata(GAME_CONTRACT_ABI, "tokenPlayerStatus", [connected_wallet, SEPOLIA_GAME_TOKEN_ADDRESS]) 
	
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
	
	# DEBUG
	#calculate_hands()



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
	
	# Selected from the set of local seeds, preferably chosen because it 
	# generates the hand containing the most preferred cards
	"fixedSeed": get_random_local_seed(),

	"nullifiers": generate_nullifier_set(hand_size),
	
	"gameToken": SEPOLIA_GAME_TOKEN_ADDRESS
  	}

	# Must define public_types for the callback
	var public_types  = [
		["uint256"],
		["uint256"],
		["address"]
	]
	
	calculateProof(
		inputs, 
		public_types, 
		handDraw_zk_circuit, 
		handDraw_zk_proving_key, 
		window.handDrawWitnessCalculator,
		"proveHand")




## GAME FUNCTIONS

func start_game():
	var params = [
		SEPOLIA_GAME_TOKEN_ADDRESS,
		ante,
		maximum_spend,
		# DEBUG
		# [TABLE_SIZE] players, i.e. 4 players
		[connected_wallet]
	]
	var calldata = EthersWeb.get_calldata(GAME_CONTRACT_ABI, "startGame", params)
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_CONTRACT_ADDRESS, calldata, "0.002", "380000")
	
	# DEBUG 
	# NOTE
	# Remember - the VRF callback is what actually starts the game
	# Check for the objectiveSeed



func raise():
	# DEBUG
	# player would pass their own amount here
	var amount = "100"
	var calldata = EthersWeb.get_calldata(GAME_CONTRACT_ABI, "raise", [SEPOLIA_GAME_TOKEN_ADDRESS, amount])
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_CONTRACT_ADDRESS, calldata)


func fold():
	var calldata = EthersWeb.get_calldata(GAME_CONTRACT_ABI, "fold", [SEPOLIA_GAME_TOKEN_ADDRESS])
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_CONTRACT_ADDRESS, calldata)


func swap_cards():
	# DEBUG
	# player would pass their own indices here
	var indices = [1, 2]
	var nullifier = generate_nullifier_set(1)[0]
	
	# Cache for proving once VRF seed has returned
	discarded_cards = {
		"indices": indices,
		"nullifier": nullifier
	}
	
	var poseidon_hash = poseidon([indices[0], indices[1], nullifier])
	
	var calldata = EthersWeb.get_calldata(GAME_CONTRACT_ABI, "swapCards", [SEPOLIA_GAME_TOKEN_ADDRESS, poseidon_hash])
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_CONTRACT_ADDRESS, calldata, "0.002", "260000")


func prove_swap():
	#To prove the swap, we need these inputs:
	# + The new VRF Swap Seed (vrfSeed)
	# + A local seed (fixedSeed)
	# + SEPOLIA_GAME_TOKEN_ADDRESS (gameToken)
	# + The 5 hashes of the old cards (oldCards)
	# + The 2 indices to be swapped (indices)
	# + The 2 nullifiers of the new cards (nullifiers)
	# + The nullifier of the discarded cards (discardNullifier)
	
	#The types of the public outputs are:
	# + uint256 (discardedCardHash)
	# + uint256 (oldHandHash)
	# + uint256 (newHandHash)
	# + uint256 (vrfSeed)
	# + address (gameToken)
	
	pass


func prove_play_cards():
	#To prove, we need:
	# + The 5 nullifiers (nullifiers)
	# + The 5 cards (cards)
	# + SEPOLIA_GAME_TOKEN_ADDRESS (gameToken)
	
	#The types of the public outputs are:
	# + uint256 (handHash)
	# + address (gameToken)
	# + uint256 (cards[0])
	# + uint256 (cards[1])
	# + uint256 (cards[2])
	# + uint256 (cards[3])
	# + uint256 (cards[4])
	pass


func conclude_game():
	# DEBUG
	# need to get the gameId 
	
	var calldata = EthersWeb.get_calldata(GAME_CONTRACT_ABI, "concludeGame", [game_id])
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_CONTRACT_ADDRESS, calldata)




## TOKEN MANAGEMENT

func mint_and_deposit():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
		
	var deposit_contract = SEPOLIA_GAME_CONTRACT_ADDRESS
	var calldata = EthersWeb.get_calldata(GAME_TOKEN_ABI, "mintAndDeposit", [connected_wallet, deposit_contract])
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_TOKEN_ADDRESS, calldata, "0.0001", "220000")


func withdraw_eth():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
	
	var calldata = EthersWeb.get_calldata(GAME_CONTRACT_ABI, "withdrawGameToken", [SEPOLIA_GAME_TOKEN_ADDRESS])
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_CONTRACT_ADDRESS, calldata)



## HELPER FUNCTIONS

func calculate_hands():
	var nullifiers = generate_nullifier_set(hand_size)
	for local_seed in local_seeds:
		generate_hand(vrf_seed, local_seed, nullifiers)
		

# Predict hands using the set of local seeds
func generate_hand(_vrf_seed, fixed_seed, nullifiers):
	
	# Apply the field modulus before hashing, otherwise large values 
	# won't validate properly
	var vrf_seed = window.zkBridge.bigNumberModulus(_vrf_seed, FIELD_MODULUS)
	
	var seed_hash = poseidon([vrf_seed, fixed_seed])
	
	var picked_cards = []
	
	for card_draw in range(hand_size):
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


func generate_nullifier_set(count):
	var nullifiers = []
	for nullifier in range(count):
		# Add "0x" so it can be converted into a BigInt 
		var bytes = "0x" + Crypto.new().generate_random_bytes(32).hex_encode()
		# Must apply the field modulus before hashing 
		var mod = window.zkBridge.bigNumberModulus(bytes, FIELD_MODULUS)
		var hash = poseidon([mod])
		nullifiers.push_back(hash)
	return nullifiers


func get_random_local_seed():
	var bytes = "0x" + Crypto.new().generate_random_bytes(32).hex_encode()
	var index = window.zkBridge.bigNumberModulus(bytes, 20)
	var local_seed = local_seeds[int(index)]
	return local_seed
	
	
	

var GAME_CONTRACT_ABI = [
	{
		"inputs": [],
		"stateMutability": "nonpayable",
		"type": "constructor"
	},
	{
		"inputs": [],
		"name": "AlreadyHaveHand",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "AlreadyRequestedSeed",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "AlreadySubmittedScore",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "AlreadySwapped",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "AnteDoesNotMatch",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "CannotWithdrawDuringGame",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "DoesNotMatchHandHash",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "GameAlreadyEnded",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "GameHasNotStarted",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "GameIDNotFound",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "HaveNotSwapped",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "InsufficientFundsForVRF",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "InsufficientTokensForAnte",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "InvalidDiscard",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "InvalidHash",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "InvalidMaximumSpend",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "InvalidPlayerCount",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "InvalidRaise",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "InvalidVRFSeed",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "InvalidZKP",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "NotEnoughTimePassed",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "NotGameToken",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "NotInGame",
		"type": "error"
	},
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
		"inputs": [],
		"name": "OutOfTime",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "PlayerAlreadyInGame",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "PlayerLacksHand",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "PlayerLacksTokens",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "TooEarly",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "TransferFailed",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "ZeroAddress",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "ZeroAmount",
		"type": "error"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": true,
				"internalType": "address",
				"name": "tokenContract",
				"type": "address"
			},
			{
				"indexed": true,
				"internalType": "address",
				"name": "recipient",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "amount",
				"type": "uint256"
			}
		],
		"name": "Deposited",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": false,
				"internalType": "address",
				"name": "player",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			}
		],
		"name": "Folded",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": false,
				"internalType": "address[]",
				"name": "winners",
				"type": "address[]"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "prize",
				"type": "uint256"
			}
		],
		"name": "GameConcluded",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "objectiveVRFSeed",
				"type": "uint256"
			}
		],
		"name": "GameStarted",
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
				"name": "player",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			},
			{
				"indexed": false,
				"internalType": "uint256[5]",
				"name": "cards",
				"type": "uint256[5]"
			}
		],
		"name": "PlayedCards",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": false,
				"internalType": "address",
				"name": "player",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "handHash",
				"type": "uint256"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "playerVRFSeed",
				"type": "uint256"
			}
		],
		"name": "ProvedHand",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": false,
				"internalType": "address",
				"name": "player",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "playerVRFSeed",
				"type": "uint256"
			}
		],
		"name": "ProvedSwap",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": false,
				"internalType": "address",
				"name": "player",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "amount",
				"type": "uint256"
			}
		],
		"name": "Raised",
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
		"anonymous": false,
		"inputs": [
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			}
		],
		"name": "StartingNewGame",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": false,
				"internalType": "address",
				"name": "player",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			}
		],
		"name": "SwappingCards",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": true,
				"internalType": "address",
				"name": "user",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "amount",
				"type": "uint256"
			}
		],
		"name": "Withdrawn",
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
				"name": "playerAddress",
				"type": "address"
			},
			{
				"internalType": "address",
				"name": "gameToken",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "ante",
				"type": "uint256"
			}
		],
		"name": "buyHandSeed",
		"outputs": [],
		"stateMutability": "payable",
		"type": "function"
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
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			}
		],
		"name": "concludeGame",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			},
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			}
		],
		"name": "depositBalance",
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
				"name": "tokenContract",
				"type": "address"
			},
			{
				"internalType": "address",
				"name": "player",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "amount",
				"type": "uint256"
			}
		],
		"name": "depositGameToken",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "gameToken",
				"type": "address"
			}
		],
		"name": "fold",
		"outputs": [],
		"stateMutability": "nonpayable",
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
		"name": "gameSessions",
		"outputs": [
			{
				"internalType": "address",
				"name": "gameToken",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "startTimestamp",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "objectiveSeed",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "maximumSpend",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "totalPot",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "highBid",
				"type": "uint256"
			},
			{
				"internalType": "bool",
				"name": "hasConcluded",
				"type": "bool"
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
				"name": "vrfSeed",
				"type": "uint256"
			}
		],
		"name": "getObjective",
		"outputs": [
			{
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			}
		],
		"stateMutability": "pure",
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
		"name": "latestGameId",
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
		"inputs": [
			{
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			}
		],
		"name": "pendingVRFRequest",
		"outputs": [
			{
				"internalType": "enum CardGame.vrfRequestType",
				"name": "requestType",
				"type": "uint8"
			},
			{
				"internalType": "address",
				"name": "requester",
				"type": "address"
			},
			{
				"internalType": "address",
				"name": "gameToken",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "playerIndex",
				"type": "uint256"
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
				"internalType": "uint256[3]",
				"name": "_pubSignals",
				"type": "uint256[3]"
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
				"internalType": "uint256[7]",
				"name": "_pubSignals",
				"type": "uint256[7]"
			}
		],
		"name": "provePlayCards",
		"outputs": [],
		"stateMutability": "nonpayable",
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
				"internalType": "uint256[5]",
				"name": "_pubSignals",
				"type": "uint256[5]"
			}
		],
		"name": "proveSwapCards",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "gameToken",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "amount",
				"type": "uint256"
			}
		],
		"name": "raise",
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
				"name": "vrfSeed",
				"type": "uint256"
			},
			{
				"internalType": "uint256[5]",
				"name": "cards",
				"type": "uint256[5]"
			}
		],
		"name": "scoreHand",
		"outputs": [
			{
				"internalType": "uint256",
				"name": "",
				"type": "uint256"
			}
		],
		"stateMutability": "pure",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "_gameToken",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "_ante",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "_maximumSpend",
				"type": "uint256"
			},
			{
				"internalType": "address[1]",
				"name": "players",
				"type": "address[1]"
			}
		],
		"name": "startGame",
		"outputs": [],
		"stateMutability": "payable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "gameToken",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "discardedCardsHash",
				"type": "uint256"
			}
		],
		"name": "swapCards",
		"outputs": [],
		"stateMutability": "payable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			},
			{
				"internalType": "address",
				"name": "",
				"type": "address"
			}
		],
		"name": "tokenPlayerStatus",
		"outputs": [
			{
				"internalType": "uint256",
				"name": "vrfSeed",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "ante",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "currentHand",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "playerIndex",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "totalBidAmount",
				"type": "uint256"
			},
			{
				"internalType": "bool",
				"name": "hasRequestedSeed",
				"type": "bool"
			}
		],
		"stateMutability": "view",
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
		"inputs": [
			{
				"internalType": "address",
				"name": "tokenContract",
				"type": "address"
			}
		],
		"name": "withdrawGameToken",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "uint256",
				"name": "gameId",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "limit",
				"type": "uint256"
			}
		],
		"name": "withinTimeLimit",
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
		"stateMutability": "payable",
		"type": "receive"
	}
]


## STARMARK


var GAME_TOKEN_ABI = [
	{
		"inputs": [],
		"stateMutability": "nonpayable",
		"type": "constructor"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "spender",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "allowance",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "needed",
				"type": "uint256"
			}
		],
		"name": "ERC20InsufficientAllowance",
		"type": "error"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "sender",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "balance",
				"type": "uint256"
			},
			{
				"internalType": "uint256",
				"name": "needed",
				"type": "uint256"
			}
		],
		"name": "ERC20InsufficientBalance",
		"type": "error"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "approver",
				"type": "address"
			}
		],
		"name": "ERC20InvalidApprover",
		"type": "error"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "receiver",
				"type": "address"
			}
		],
		"name": "ERC20InvalidReceiver",
		"type": "error"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "sender",
				"type": "address"
			}
		],
		"name": "ERC20InvalidSender",
		"type": "error"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "spender",
				"type": "address"
			}
		],
		"name": "ERC20InvalidSpender",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "TransferFailed",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "ZeroAddress",
		"type": "error"
	},
	{
		"inputs": [],
		"name": "ZeroAmount",
		"type": "error"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": true,
				"internalType": "address",
				"name": "owner",
				"type": "address"
			},
			{
				"indexed": true,
				"internalType": "address",
				"name": "spender",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "value",
				"type": "uint256"
			}
		],
		"name": "Approval",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": true,
				"internalType": "address",
				"name": "depositContract",
				"type": "address"
			},
			{
				"indexed": true,
				"internalType": "address",
				"name": "recipient",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "amount",
				"type": "uint256"
			}
		],
		"name": "Deposited",
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
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "value",
				"type": "uint256"
			}
		],
		"name": "Transfer",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{
				"indexed": true,
				"internalType": "address",
				"name": "user",
				"type": "address"
			},
			{
				"indexed": false,
				"internalType": "uint256",
				"name": "amount",
				"type": "uint256"
			}
		],
		"name": "Withdrawn",
		"type": "event"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "owner",
				"type": "address"
			},
			{
				"internalType": "address",
				"name": "spender",
				"type": "address"
			}
		],
		"name": "allowance",
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
				"name": "spender",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "value",
				"type": "uint256"
			}
		],
		"name": "approve",
		"outputs": [
			{
				"internalType": "bool",
				"name": "",
				"type": "bool"
			}
		],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "account",
				"type": "address"
			}
		],
		"name": "balanceOf",
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
				"internalType": "uint256",
				"name": "amount",
				"type": "uint256"
			},
			{
				"internalType": "address",
				"name": "recipient",
				"type": "address"
			}
		],
		"name": "burnAndWithdraw",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "decimals",
		"outputs": [
			{
				"internalType": "uint8",
				"name": "",
				"type": "uint8"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "isGameToken",
		"outputs": [
			{
				"internalType": "bool",
				"name": "",
				"type": "bool"
			}
		],
		"stateMutability": "pure",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "recipient",
				"type": "address"
			},
			{
				"internalType": "address",
				"name": "depositContract",
				"type": "address"
			}
		],
		"name": "mintAndDeposit",
		"outputs": [],
		"stateMutability": "payable",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "name",
		"outputs": [
			{
				"internalType": "string",
				"name": "",
				"type": "string"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "symbol",
		"outputs": [
			{
				"internalType": "string",
				"name": "",
				"type": "string"
			}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "totalSupply",
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
				"name": "to",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "value",
				"type": "uint256"
			}
		],
		"name": "transfer",
		"outputs": [
			{
				"internalType": "bool",
				"name": "",
				"type": "bool"
			}
		],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{
				"internalType": "address",
				"name": "from",
				"type": "address"
			},
			{
				"internalType": "address",
				"name": "to",
				"type": "address"
			},
			{
				"internalType": "uint256",
				"name": "value",
				"type": "uint256"
			}
		],
		"name": "transferFrom",
		"outputs": [
			{
				"internalType": "bool",
				"name": "",
				"type": "bool"
			}
		],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"stateMutability": "payable",
		"type": "receive"
	}
]
