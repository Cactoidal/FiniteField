extends Control

@onready var ERC20 = Contract.ERC20
@onready var window = EthersWeb.window

var connected_wallet
var player_status = {}
var in_game = false


var listening = false
var connect_button_position = Vector2(50,25)
var prompt_connect = true

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
	fade("OUT", $Curtain)
	connect_buttons()
	load_and_attach(snarkjs_filepath)
	
	# witness_calculator.js files need to be attached to the
	# window using a wrapper (see below) and later passed as an object
	load_and_attach(handDraw_witness_calculator_filepath, "handDrawWitnessCalculator")
	load_and_attach(swapCards_witness_calculator_filepath, "swapCardsWitnessCalculator")
	load_and_attach(playCards_witness_calculator_filepath, "playCardsWitnessCalculator")
	
	load_and_attach(js_crypto_filepath)
	load_and_attach(zk_bridge_filepath)


func connect_buttons():
	$ConnectWallet.connect("pressed", connect_wallet)
	$Info/BuyTokens.connect("pressed", mint_and_deposit)
	$Info/WithdrawETH.connect("pressed", withdraw_eth)
	
	$Prompt/BuySeed.connect("pressed", buy_seed)
	$Prompt/GetHand.connect("pressed", get_hand)
	$Prompt/StartGame.connect("pressed", select_game_mode)
	
	$Overlay/Warning/CopyHand.connect("pressed", copy_hand)
	$Overlay/Restore/RestoreHand.connect("pressed", restore_hand)
	$Overlay/Restore/DeleteHand.connect("pressed", delete_hand)
	$Overlay/StartGame/StartGame.connect("pressed", start_game)
	
	#DEBUG
	$Prompt/RejoinGame.connect("pressed", conclude_game)
	#$Prompt/RejoinGame.connect("pressed", rejoin_game)
	
	EthersWeb.register_transaction_log(self, "receive_tx_receipt")


func connect_wallet():
	if EthersWeb.has_wallet:
		var callback = EthersWeb.create_callback(self, "got_account_list")
		EthersWeb.connect_wallet(callback)


func got_account_list(callback):
	if callback["result"]:
		connected_wallet = callback["result"][0]
		prompt_connect = false
		fade("OUT", $ConnectWallet, move_connect_button)
		fade("OUT", $Title, move_connect_button)
		fade("IN", $Info, fade.bind("IN", $Prompt))
		
		print_log("Retrieving player info for " + connected_wallet)
		get_player_status(connected_wallet)
		get_token_balance(connected_wallet)


# Check for disconnections or account switches
var poll_timer = 1.5
var status_poll_timer = 4
func _process(delta):
	if connected_wallet:
		
		poll_timer -= delta
		status_poll_timer -= delta
		
		if poll_timer < 0:
			var callback = EthersWeb.create_callback(self, "polled_accounts")
			EthersWeb.poll_accounts(callback)
			poll_timer = 1.5


# DEBUG
# Check if invited into a game
# If, at any point in time, the player has a valid hand
# and a gameId, they should be automatically moved from
# pregame state to game state.  Rejoining is similarly 
# automatic


func polled_accounts(callback):
	if !callback["result"]:
		if !prompt_connect:
			prompt_connect = true
			fade("IN", $ConnectWallet)
			$Info/TokenBalance.text = ""
	
	else:
		var wallet = callback["result"]
		if connected_wallet != wallet:
			get_player_status(wallet)
			get_token_balance(wallet)
		
		# Query on-chain state every few seconds
		elif status_poll_timer < 0:
			get_player_status(connected_wallet)
			
		connected_wallet = wallet
		
		if prompt_connect:
			prompt_connect = false
			fade("OUT", $ConnectWallet)
		
		




func get_player_status(player_address):
	
	# Reset the poll timer with every request, since a request
	# can come from multiple sources
	status_poll_timer = 4
	
	var callback = EthersWeb.create_callback(self, "received_player_status")

	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "tokenPlayerStatus", [player_address, SEPOLIA_GAME_TOKEN_ADDRESS]) 
	
	EthersWeb.read_from_contract(
		"Ethereum Sepolia",
		SEPOLIA_GAME_LOGIC_ADDRESS, 
		data,
		callback
		)


func get_token_balance(player_address):
	var callback = EthersWeb.create_callback(self, "received_token_balance")

	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "depositBalance", [player_address, SEPOLIA_GAME_TOKEN_ADDRESS]) 
	
	EthersWeb.read_from_contract(
		"Ethereum Sepolia",
		SEPOLIA_GAME_LOGIC_ADDRESS, 
		data,
		callback
		)

func received_token_balance(callback):
	if callback["result"]:
		player_status["token_balance"] = callback["result"][0]
		$Info/TokenBalance.text = "Token Balance: " + player_status["token_balance"]
	else:
		$Info/TokenBalance.text = ""
		check_rpc()



func received_player_status(callback):
	if callback["result"]:
		player_status["vrf_seed"] = callback["result"][0]
		player_status["hand_hash"] = callback["result"][2]
		player_status["game_id"] = callback["result"][3]
		player_status["player_index"] = callback["result"][4]
		player_status["total_bid_amount"] = callback["result"][5]
		player_status["has_requested_seed"] = callback["result"][6]
		
		
		if player_status["game_id"] != "0":
			if !in_game:
				handle_pregame()
			else:
				#update game
				pass
				
		elif !in_game:
			handle_pregame()
	
	else:
		check_rpc()


var PREGAME_STATE = ""
var must_copy_hand = true
func handle_pregame():
	var _pregame_state = ""
			
	if player_status["game_id"] != "0":
		if !"hand_hash" in hand:
			_pregame_state = "RESTORE_HAND"
		else:
			_pregame_state = "REJOIN_GAME"
				
	elif player_status["hand_hash"] != "0":
		if !"hand_hash" in hand:
			_pregame_state = "RESTORE_HAND"
		else:
			_pregame_state = "CREATE_GAME"
				
	elif player_status["vrf_seed"] != "0":
		_pregame_state = "PROVE_HAND"
			
	elif player_status["has_requested_seed"]:
		_pregame_state = "WAIT_FOR_SEED"
		
	else:
		_pregame_state = "BUY_SEED"
			
	if PREGAME_STATE != _pregame_state:
		reset_prompts()
		PREGAME_STATE = _pregame_state
	else:
		#DEBUG
		return
			
	match PREGAME_STATE:
		"REJOIN_GAME": prompt_rejoin_game()
		"CREATE_GAME": prompt_create_game()
		"RESTORE_HAND": prompt_restore_hand()
		"PROVE_HAND": prompt_prove_hand()
		"WAIT_FOR_SEED": wait_for_seed()
		"BUY_SEED": prompt_buy_seed()



func prompt_buy_seed():
	print_log("Seed not found")
	fadein_button($Prompt/BuySeed)

func wait_for_seed():
	print_log("Waiting for VRF response...")


func prompt_prove_hand():
	print_log("Hand not found")
	fadein_button($Prompt/GetHand)
	must_copy_hand = true


func prompt_restore_hand():
	$Overlay/Restore.visible = true
	$Overlay.visible = true
	
	if player_status["game_id"] != "0":
		$Overlay/Restore/DeleteHand.text = "Conclude Game"
	else:
		$Overlay/Restore/DeleteHand.text = "Join Game"


func prompt_create_game():
	print_log("Game ID not found")
	fadein_button($Prompt/StartGame)


func prompt_rejoin_game():
	print_log("Game ID found.  Joining...")
	fadein_button($Prompt/RejoinGame)


func get_hand():
	if must_copy_hand:
		hand = generate_hand(player_status["vrf_seed"], get_random_local_seed(), generate_nullifier_set(hand_size))
		$Overlay/Warning/HandText.text = str(hand)
		$Overlay/Warning.visible = true
		$Overlay.visible = true
	else:
		get_hand_zk_proof()


func copy_hand():
	copy_text($Overlay/Warning/HandText)
	$Overlay/Warning.visible = false
	$Overlay.visible = false
	must_copy_hand = false


func restore_hand():
	var hand_text = $Overlay/Restore/RestoreText.text
	var hand_json = JSON.parse_string(hand_text)
	if !hand_json:
		print_log("Invalid JSON")
		return
	if hand_json.keys() != ["vrf_seed", "fixed_seed", "cards", "nullifiers", "card_hashes", "hand_hash"]:
		print_log("Invalid JSON")
		return
	if hand_json["hand_hash"] != player_status["hand_hash"]:
		print_log("Hand does not match on-chain hash")
		return
		
	hand = hand_json
	$Overlay/Restore.visible = false
	$Overlay.visible = false
	get_player_status(connected_wallet)


# DEBUG
# Overlay needs to be made invisible again
func delete_hand():
	if $Overlay/Restore/DeleteHand.text == "Conclude Game":
		conclude_game()
	elif $Overlay/Restore/DeleteHand.text == "Join Game":
		start_game()



func check_for_invite():
	print_log("Looking for invitation...")
	get_player_status(connected_wallet)

# DEBUG
# Multi opponent support doesn't exist yet 
# (because TABLE_SIZE is currently a constant)
func select_game_mode():
	$Overlay/StartGame.visible = true
	$Overlay.visible = true



func rejoin_game():
	pass





# Needs to resolve based on tx type
func receive_tx_receipt(tx_receipt):
	
	var tx_hash = tx_receipt["hash"]
	var status = str(tx_receipt["status"])
	
	if status == "1":
		var blockNumber = str(tx_receipt["blockNumber"])
		print_log("Tx included in block " + blockNumber)
	
	if status == "0":
		print_log("Transaction failed")
		
	get_token_balance(connected_wallet)
	get_player_status(connected_wallet)
	#print_log(txt)


func print_log(txt):
	$Info/Log.text += "> " + txt + "\n"
	$Info/Log.scroll_vertical = $Info/Log.get_v_scroll_bar().max_value

func has_error(callback):
	if "error_code" in callback.keys():
		var txt = "Error " + str(callback["error_code"]) + ": " + callback["error_message"]
		print_log(txt)
		return true

func check_rpc():
	print_log("No response from chain, check RPC.")



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
	var data = EthersWeb.get_calldata(ABI, function_name, decoded_values)

	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "ZK_PROOF"})
	# DEBUG
	# Will probably split this part into a separate function
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_LOGIC_ADDRESS, data, "0", null, _callback)
	
	print_log("ZKP Generated")
	#print_log("PROOF VALUES:\n" + str(decoded_values) + "\n\n")
	


# DEBUG
func await_transaction(callback):
	var tx_type = ""
	if "tx_type" in callback.keys():
		tx_type = callback["tx_type"]
	
	var remove = true
	
	# SUCCESSFUL TX
	if "result" in callback.keys():
		print_log("Transaction Sent\nWaiting...")
		# DEBUG
		match tx_type:
			"GET_HAND_VRF":
				pass
			"START_GAME":
				pass
			"INITIATE_SWAP":
				pass
		
		
	# FAILED TX
	elif "error_message" in callback.keys():
		var error = callback["error_code"]
		
		# USER REJECTED
		if error == "ACTION_REJECTED":
			print_log("Transaction Rejected")
			match tx_type:
				"CONCLUDE_GAME":
					remove = false
		
		# RPC REJECTED
		if error == "CALL_EXCEPTION":
			print_log("Transaction Failed")
			match tx_type:
				"WITHDRAW":
					if player_status["game_id"] != "0":
						print_log("Cannot withdraw tokens during a game")
				
				"CONCLUDE_GAME":
					remove = false
					print_log("Game time limit has not elapsed")
			
	if remove:
		remove_overlay()
	
	
	
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
var SEPOLIA_GAME_LOGIC_ADDRESS = "0x5507ea3aAB6c1EF18B1AE24f29e6D207CE64905b"

# Token
var SEPOLIA_GAME_TOKEN_ADDRESS = "0x9acF3472557482091Fe76c2D08F82819Ab9a28eb"

var local_seeds = [948321578921, 323846237643, 29478234787, 947289484324, 4827847813436, 98432542473237, 56324278238234, 77238476429378, 10927437265398, 32589475384735, 87834727625345, 7723645230273, 298467856729, 233652987328, 2389572388357, 23858923387534, 1242398565735, 6875282937855, 82984325902750, 48547252957635743]

var deck = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
var hand_size = 5

var ante = "100"
var maximum_spend = "1000"

var vrf_swap_seed
var hand = {}
var discarded_cards

# DEBUG 
# Add a way to pull this from the chain instead of setting it manually here
var game_id = 2





## NEW HAND FUNCTIONS

func buy_seed():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
	
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "buyHandSeed", [connected_wallet, SEPOLIA_GAME_TOKEN_ADDRESS, ante])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "GET_HAND_VRF"})
	# Gas limit must be specified because ethers.js will underestimate
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_LOGIC_ADDRESS, data, "0.002", "260000", _callback)



func game_info():
	var callback = EthersWeb.create_callback(self, "got_game_info")

	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "gameSessions", [game_id]) 
	
	EthersWeb.read_from_contract(
		"Ethereum Sepolia",
		SEPOLIA_GAME_LOGIC_ADDRESS, 
		data,
		callback
		)

func got_game_info(callback):
	if has_error(callback):
		return
	
	print_log("Objective Seed: " + str(callback["result"][2]))
	#[0] gameToken
	#[1] startTimestamp
	#[2] objectiveSeed
	#[3] maximumSpend
	#[4] totalPot
	#[5] highBid
	#[6] hasConcluded
	#[7] players
	#[8] exited
	#[9] scores
	#[10] vrfSwapSeeds
	#[11] discardedCards
	#[12] winners


# DEBUG 
# Only returning zero?
func get_vrf_swap_seed():
	var callback = EthersWeb.create_callback(self, "got_vrf_swap_seed")

	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "getVRFSwapSeed", [connected_wallet, SEPOLIA_GAME_TOKEN_ADDRESS]) 
	
	EthersWeb.read_from_contract(
		"Ethereum Sepolia",
		SEPOLIA_GAME_LOGIC_ADDRESS, 
		data,
		callback
		)

func got_vrf_swap_seed(callback):
	if has_error(callback):
		return
	
	vrf_swap_seed = callback["result"][0]
	print_log("VRF Swap Seed: " + vrf_swap_seed)




func get_hand_zk_proof():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
	
	if !hand["vrf_seed"]:
		print_log("Please get the current seed")
		return
	
	print_log("Generating ZKP to prove hand...")
		
	# Parameter names must match circuit inputs' names
	var inputs = {   
	# Must come from the smart contract (will be validated on-chain 
	# using the public input)
	"vrfSeed": hand["vrf_seed"],
	
	# Selected from the set of local seeds, preferably chosen because it 
	# generates the hand containing the most preferred cards
	"fixedSeed": hand["fixed_seed"],

	"nullifiers": hand["nullifiers"],
	
	"gameToken": SEPOLIA_GAME_TOKEN_ADDRESS
  	}
	
	# Cache the hand locally for later use
	#hand = generate_hand(inputs["vrfSeed"], inputs["fixedSeed"], inputs["nullifiers"])

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
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "startGame", params)
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "START_GAME"})
	
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_LOGIC_ADDRESS, data, "0.002", "380000", _callback)
	
	# DEBUG 
	# NOTE
	# Remember - the VRF callback is what actually starts the game
	# Check for the objectiveSeed



func raise():
	# DEBUG
	# player would pass their own amount here
	var amount = "100"
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "raise", [SEPOLIA_GAME_TOKEN_ADDRESS, amount])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "RAISE"})
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_LOGIC_ADDRESS, data, "0", null, _callback)


func fold():
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "fold", [SEPOLIA_GAME_TOKEN_ADDRESS])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "FOLD"})
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_LOGIC_ADDRESS, data, "0", null, _callback)


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
	
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "swapCards", [SEPOLIA_GAME_TOKEN_ADDRESS, poseidon_hash])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "INITIATE_SWAP"})
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_LOGIC_ADDRESS, data, "0.002", "260000", _callback)


#To prove the swap, we need these inputs:
	# + The new VRF Swap Seed (vrfSeed)
	# + A new local seed (fixedSeed) - ideally optimized for the best score
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
func prove_swap():

	var fixed_seed = get_random_local_seed()
	var old_cards = hand["card_hashes"]
	var indices = [1,2]
	var new_nullifiers = generate_nullifier_set(2)
	var discard_nullifier = discarded_cards["nullifier"]
	
	
	# DEBUG
	# Needs to be done after the transaction is confirmed
	#     #     #     #     #     #     #     #     #     #
	hand["nullifiers"][indices[0]] = new_nullifiers[0]
	hand["nullifiers"][indices[1]] = new_nullifiers[1]
	
	var drawn_cards = generate_hand(vrf_swap_seed, fixed_seed, new_nullifiers)
	
	hand["cards"][indices[0]] = drawn_cards["cards"][0]
	hand["cards"][indices[1]] = drawn_cards["cards"][1]

	
	
	#var card_hashes = []
	#for i in range(5):
		#var card_hash = poseidon([hand["cards"][i], hand["nullifiers"][i]])
		#card_hashes.push_back(card_hash)
	#
	#hand["hand_hash"] = poseidon(hand["cards"])
	

	#     #     #     #     #     #     #     #     #     #
	
	var inputs = {
		
		"vrfSeed": vrf_swap_seed,
		
		"fixedSeed": fixed_seed,
		
		"gameToken": SEPOLIA_GAME_TOKEN_ADDRESS,
		
		"oldCards": old_cards,
		
		"indices": indices,
		
		"nullifiers": new_nullifiers,
		
		"discardNullifier": discard_nullifier
	}
	
	var public_types  = [
		["uint256"],
		["uint256"],
		["uint256"],
		["uint256"],
		["address"]
	]
	
	calculateProof(
		inputs, 
		public_types, 
		swapCards_zk_circuit, 
		swapCards_zk_proving_key, 
		window.swapCardsWitnessCalculator,
		"proveSwapCards")



#To prove, we need:
	# + The 5 nullifiers (nullifiers)
	# + The 5 cards (cards)
	# + SEPOLIA_GAME_TOKEN_ADDRESS (gameToken)
	
	#The types of the public outputs are:
	# + uint256 (handHash)
	# + uint256 (cards[0])
	# + uint256 (cards[1])
	# + uint256 (cards[2])
	# + uint256 (cards[3])
	# + uint256 (cards[4])
	# + address (gameToken)
func prove_play_cards():
	# DEBUG
	var nullifiers = hand["nullifiers"]
	var cards = hand["cards"]
	
	var inputs = {
		
		"nullifiers": nullifiers,
		
		"cards": cards,
		
		"gameToken": SEPOLIA_GAME_TOKEN_ADDRESS
	}
	
	# DEBUG
	# For some reason the address is coming in last,
	# make sure this remains consistent
	var public_types  = [
		["uint256"],
		["uint256"],
		["uint256"],
		["uint256"],
		["uint256"],
		["uint256"],
		["address"]
	]
	
	calculateProof(
		inputs, 
		public_types, 
		playCards_zk_circuit, 
		playCards_zk_proving_key, 
		window.playCardsWitnessCalculator,
		"provePlayCards")
	
	


func conclude_game():
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "concludeGame", [player_status["game_id"]])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "CONCLUDE_GAME"})
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_LOGIC_ADDRESS, data, "0", null, _callback)






## TOKEN MANAGEMENT

func mint_and_deposit():
	var deposit_contract = SEPOLIA_GAME_LOGIC_ADDRESS
	var data = EthersWeb.get_calldata(GAME_TOKEN_ABI, "mintAndDeposit", [connected_wallet, deposit_contract])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "DEPOSIT"})
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_TOKEN_ADDRESS, data, "0.0001", "220000", _callback)


func withdraw_eth():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
	
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "withdrawGameToken", [SEPOLIA_GAME_TOKEN_ADDRESS])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "WITHDRAW"})
	EthersWeb.send_transaction("Ethereum Sepolia", SEPOLIA_GAME_LOGIC_ADDRESS, data, "0", null, _callback)



## HELPER FUNCTIONS

func calculate_hands():
	var nullifiers = generate_nullifier_set(hand_size)
	for local_seed in local_seeds:
		generate_hand(player_status["vrf_seed"], local_seed, nullifiers)
		

# Predict hands using the set of local seeds
func generate_hand(_vrf_seed, fixed_seed, nullifiers):
	
	var _hand_size = nullifiers.size()
	
	# Apply the field modulus before hashing, otherwise large values 
	# won't validate properly
	var vrf_seed = window.zkBridge.bigNumberModulus(_vrf_seed, FIELD_MODULUS)
	
	var seed_hash = poseidon([vrf_seed, fixed_seed])
	
	var picked_cards = []
	
	for card_draw in range(_hand_size):
		seed_hash = poseidon([seed_hash])
	
		var index = int(window.zkBridge.bigNumberModulus(seed_hash, deck.size()))
	
		picked_cards.push_back(deck[index])
	
	var cards = []
	var card_hashes = []
	
	for card in range(_hand_size):
		var poseidon_hash = poseidon([picked_cards[card], nullifiers[card]])
		cards.push_back({
			"card": picked_cards[card],
			"nullifier": nullifiers[card],
			"hash": poseidon_hash
		})
		card_hashes.push_back(poseidon_hash)
	
	var hand_hash = poseidon(card_hashes)
	
	var hand = {
		"vrf_seed": vrf_seed,
		"fixed_seed": fixed_seed,
		"cards": picked_cards,
		"nullifiers": nullifiers,
		"card_hashes": card_hashes,
		"hand_hash": hand_hash
	}
	
	return hand


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
	

# From contract logic 
func predict_score(obj_attractor, obj_color, cards):
	var score = 0
	for card in cards:
		var card_color = 1
		if card > 10:
			card_color = 2
			
			card -= 10
		
		var diff = 0
		
		if card > obj_attractor:
			diff = card - obj_attractor
		elif card < obj_attractor:
			diff = obj_attractor - card
		
		var color_bonus = 1
		
		if card_color == obj_color:
			color_bonus = 2
		
		score += (10 - diff) * color_bonus
	
	return score



var GAME_LOGIC_ABI = [
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
			}
		],
		"name": "getVRFSwapSeed",
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
		"name": "verifyHandProof",
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



## UI HELPERS

func fade(outin, canvas, callback=null):
	var target = 1
	
	# Become visible
	if outin == "IN":
		target = 1
		
	# Become invisible
	elif outin == "OUT":
		target = 0
	
	var tween = create_tween()
	tween.tween_property(canvas, "modulate:a", target, 1)
	if callback:
		tween.tween_callback(callback)
	tween.play()
		

func move_connect_button():
	$ConnectWallet.position = connect_button_position

func reset_prompts():
	for prompt_button in $Prompt.get_children():
		prompt_button.modulate.a = 0
		prompt_button.visible = false


func fadein_button(_button):
	_button.visible = true
	fade("IN", _button)

func copy_text(source):
	var text_to_copy = source.text
	var js_code = "navigator.clipboard.writeText(%s);" % JSON.stringify(text_to_copy)
	JavaScriptBridge.eval(js_code)

func remove_overlay():
	for submenu in $Overlay.get_children():
		submenu.visible = false
	$Overlay.visible = false
