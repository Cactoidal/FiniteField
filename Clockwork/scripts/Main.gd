extends Control

@onready var window = EthersWeb.window
@onready var GAME_LOGIC_ABI = GameAbi.GAME_LOGIC_ABI
@onready var GAME_TOKEN_ABI = GameAbi.GAME_TOKEN_ABI

var test_network = "Base Sepolia"

# BASE SEPOLIA
const SEPOLIA_GAME_LOGIC_ADDRESS = "0x0eB6AA69FF74ff95089d48BAa14cfD75038eF140"
const SEPOLIA_GAME_TOKEN_ADDRESS = "0x0C8776B3427bBab1F4A4c599c153781598758495"


# The current active wallet 
var connected_wallet

# Player statuses are mapped to wallet addresses as they are detected
var player_status = {}

# Game states are mapped to wallet addresses while they are ongoing
var game_session = {}

@onready var card_scene = preload("res://scenes/Card.tscn")
@onready var opponent_scene = preload("res://scenes/Opponent.tscn")


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
	# Initialize UI
	fade("OUT", $Curtain)
	connect_buttons()
	EthersWeb.register_transaction_log(self, "receive_tx_receipt")
	
	# Load all ZK scripts from .PCK file
	load_and_attach(snarkjs_filepath)
	
	# witness_calculator.js files need to be attached to the
	# window using a wrapper (see below) and later passed as an object
	load_and_attach(handDraw_witness_calculator_filepath, "handDrawWitnessCalculator")
	load_and_attach(swapCards_witness_calculator_filepath, "swapCardsWitnessCalculator")
	load_and_attach(playCards_witness_calculator_filepath, "playCardsWitnessCalculator")
	
	load_and_attach(js_crypto_filepath)
	load_and_attach(zk_bridge_filepath)
	
	# DEBUG
	#print(window.walletBridge.getFunctionSelector("InvalidHash()"))


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
	
	$GameInfo/Raise.connect("pressed", raise)
	$GameInfo/Fold.connect("pressed", fold)
	$GameInfo/SwapWindow/SwapActuator.connect("pressed", actuate_swap)
	
	$RevealCards.connect("pressed", prove_play_cards)
	$ConcludeGame.connect("pressed", conclude_game)
	
	
func connect_wallet():
	if EthersWeb.has_wallet:
		var callback = EthersWeb.create_callback(self, "got_account_list")
		EthersWeb.connect_wallet(callback)


func got_account_list(callback):
	if callback["result"]:
		
		connected_wallet = callback["result"][0]
		
		# Instantiate the wallet if needed
		if !connected_wallet in player_status.keys():
			player_status[connected_wallet] = {"hand": {}}
		
		prompt_connect = false
		fade("OUT", $ConnectWallet, move_connect_button)
		fade("OUT", $Title, move_connect_button)
		fade("IN", $Log)
		fade("IN", $Info, fade.bind("IN", $Prompt))
		$Prompt.visible = true
		
		print_log("Retrieving player info for " + connected_wallet)
		get_player_status(connected_wallet)
		get_token_balance(connected_wallet)


# Check for disconnections or account switches
var poll_timer = 1.5
var status_poll_timer = 4
var game_poll_timer = 4
func _process(delta):
	if connected_wallet:
		
		poll_timer -= delta
		
		# Only poll the player status while in the pregame state
		if !in_game:
			status_poll_timer -= delta
		else:
			game_poll_timer -= delta
		
		if poll_timer < 0:
			var callback = EthersWeb.create_callback(self, "polled_accounts")
			EthersWeb.poll_accounts(callback)
			poll_timer = 1.5
		
		if game_poll_timer < 0:
			var game_id = player_status[connected_wallet]["game_id"]
		
			if !game_session[connected_wallet]["game_started"]:
				get_game_session(game_id)
			else:
				get_game_player_info(game_id)


func polled_accounts(callback):
	if !callback["result"]:
		if !prompt_connect:
			prompt_connect = true
			fade("IN", $ConnectWallet)
			$Info/TokenBalance.text = ""
	
	else:
		var wallet = callback["result"]
		if connected_wallet != wallet:
			
			# Instantiate new accounts
			if !wallet in player_status.keys():
				player_status[wallet] = {"hand":{}}
			
			# Account switch detected, reset UI
			reset_states()
			
			# Get info for new account
			connected_wallet = wallet
			print_log("Retrieving player info for " + wallet)
			get_player_status(wallet)
			get_token_balance(wallet)
		
		# Query on-chain state every few seconds
		elif status_poll_timer < 0:
			get_player_status(connected_wallet)
			
		if prompt_connect:
			prompt_connect = false
			fade("OUT", $ConnectWallet)
		
		


func get_player_status(player_address):
	
	# Reset the poll timer with every request, since a request
	# can come from multiple sources in this script
	status_poll_timer = 4
	
	var callback = EthersWeb.create_callback(self, "received_player_status")

	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "tokenPlayerStatus", [player_address, SEPOLIA_GAME_TOKEN_ADDRESS]) 
	
	EthersWeb.read_from_contract(
		test_network,
		SEPOLIA_GAME_LOGIC_ADDRESS, 
		data,
		callback
		)


func get_token_balance(player_address):
	var callback = EthersWeb.create_callback(self, "received_token_balance")

	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "depositBalance", [player_address, SEPOLIA_GAME_TOKEN_ADDRESS]) 
	
	EthersWeb.read_from_contract(
		test_network,
		SEPOLIA_GAME_LOGIC_ADDRESS, 
		data,
		callback
		)


func received_token_balance(callback):
	if callback["result"]:
		var wallet = player_status[connected_wallet]
		wallet["token_balance"] = callback["result"][0]
		$Info/TokenBalance.text = "Token Balance: " + wallet["token_balance"]
	else:
		$Info/TokenBalance.text = ""
		check_rpc()



func received_player_status(callback):
	if callback["result"]:
		var wallet = player_status[connected_wallet]
		wallet["vrf_seed"] = callback["result"][0]
		wallet["hand_hash"] = callback["result"][2]
		wallet["game_id"] = callback["result"][3]
		wallet["player_index"] = callback["result"][4]
		wallet["total_bid_amount"] = callback["result"][5]
		wallet["has_requested_seed"] = callback["result"][6]
		
		if wallet["game_id"] != "0":
			if !in_game:
				handle_pregame()
			else:
				#update game
				pass
				
		elif !in_game:
			handle_pregame()
	
	else:
		check_rpc()



func handle_pregame():
	var wallet = player_status[connected_wallet]
	var hand = wallet["hand"]
	
	var _pregame_state = ""
			
	if wallet["game_id"] != "0":
		if !"hand_hash" in hand:
			_pregame_state = "RESTORE_HAND"
		else:
			_pregame_state = "JOIN_GAME"
				
	elif wallet["hand_hash"] != "0":
		if !"hand_hash" in hand:
			_pregame_state = "RESTORE_HAND"
		else:
			_pregame_state = "CREATE_GAME"
				
	elif wallet["vrf_seed"] != "0":
		_pregame_state = "PROVE_HAND"
			
	elif wallet["has_requested_seed"]:
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
		"JOIN_GAME": prompt_join_game()
		"CREATE_GAME": prompt_create_game()
		"RESTORE_HAND": prompt_restore_hand()
		"PROVE_HAND": prompt_prove_hand()
		"WAIT_FOR_SEED": wait_for_seed()
		"BUY_SEED": prompt_buy_seed()



func prompt_buy_seed():
	print_log("Get tokens, then buy seed to generate hand")
	fadein_button($Prompt/BuySeed)

func wait_for_seed():
	print_log("Waiting for VRF response...")


func prompt_prove_hand():
	print_log("Generate hand to join a game")
	fadein_button($Prompt/GetHand)
	must_copy_hand = true


func prompt_restore_hand():
	$Overlay/Restore.visible = true
	$Overlay.visible = true
	
	if player_status[connected_wallet]["game_id"] != "0":
		$Overlay/Restore/DeleteHand.text = "Conclude Game"
	else:
		$Overlay/Restore/DeleteHand.text = "Join Game"


func prompt_create_game():
	print_log("Create or join a game")
	fadein_button($Prompt/StartGame)


func prompt_join_game():
	print_log("Game ID found.  Joining...")
	fade("OUT", $Info, join_game)
	



func get_hand():
	if must_copy_hand:
		var hand = generate_hand(player_status[connected_wallet]["vrf_seed"], generate_nullifier_set(hand_size), get_random_local_seed())
		player_status[connected_wallet]["hand"] = hand
		$Overlay/Warning/HandText.text = Marshalls.utf8_to_base64( str(hand) )
		$Overlay/Warning.visible = true
		$Overlay.visible = true
	else:
		get_hand_zk_proof()


func copy_hand():
	copy_text($Overlay/Warning/HandText)
	$Overlay/Warning.visible = false
	$Overlay.visible = false
	must_copy_hand = false
	get_hand_zk_proof()


func restore_hand():
	var hand_base64 = $Overlay/Restore/RestoreText.text
	var hand_text = Marshalls.base64_to_utf8(hand_base64)
	
	var hand_json = JSON.parse_string(hand_text)
	if !hand_json:
		print_log("Invalid JSON")
		return
	
	for key in hand_json.keys():
		if !key in ["vrf_seed", "fixed_seed", "cards", "nullifiers", "card_hashes", "hand_hash", "vrf_swap_seed", "discarded_cards", "has_swapped"]:
			print_log("Invalid JSON")
			return
			
	if hand_json["hand_hash"] != player_status[connected_wallet]["hand_hash"]:
		print_log("Hand does not match on-chain hash")
		return
		
	player_status[connected_wallet]["hand"] = hand_json
	
	# JSON spec converts numbers to floats, turn the cards back into integers
	var int_cards = []
	for card in player_status[connected_wallet]["hand"]["cards"]:
		card = int(card)
		int_cards.push_back(card)
	
	player_status[connected_wallet]["hand"]["cards"] = int_cards
	
	$Overlay/Restore.visible = false
	$Overlay.visible = false
	get_player_status(connected_wallet)


# DEBUG
func delete_hand():
	if $Overlay/Restore/DeleteHand.text == "Conclude Game":
		conclude_game()
	elif $Overlay/Restore/DeleteHand.text == "Join Game":
		start_game()


# DEBUG
# Multi opponent support doesn't exist yet 
# (because TABLE_SIZE is currently a constant)
func select_game_mode():
	$Overlay/StartGame.visible = true
	$Overlay.visible = true



func join_game():
	$Info.visible = false
	in_game = true
	splay_cards()
	initialize_game_state()
	var game_id = player_status[connected_wallet]["game_id"]
	get_game_session(game_id)
	get_game_player_info(game_id)
	# DEBUG
	$GameInfo/Bid.text = str(player_status[connected_wallet]["total_bid_amount"]) + " / 1000"



func splay_cards():
	var cards = player_status[connected_wallet]["hand"]["cards"]

	# DEBUG
	# Card width is 73 pixels
	var slide_increment = 80
	var x_slide = slide_increment
	var index = 0
	
	for card in cards:
		var new_card = card_scene.instantiate()
		new_card.main = self
		new_card.index = index
		new_card.num = card
		new_card.x_slide = x_slide
		$Cards.add_child(new_card)
		
		x_slide += slide_increment
		index += 1


func update_card_indices(_index):

	var vrf_swap_seed = player_status[connected_wallet]["hand"]["vrf_swap_seed"]
	
	if game_session[connected_wallet]["initiated_swap"] || vrf_swap_seed!= "0":
		print_log("Already selected cards for swap")
		return
	
	var selected_card_indices = game_session[connected_wallet]["selected_card_indices"]
		
	if _index in selected_card_indices:
		print_log("Already selected that card")
		return

	if selected_card_indices.size() == 2:
		selected_card_indices.pop_front()
	selected_card_indices.push_back(_index)
	
	for card in $Cards.get_children():
		card.deactivate_highlight()
	
	for index in selected_card_indices:
		$Cards.get_children()[index].show_highlight()
	
	var selected_count = selected_card_indices.size()
	
	$GameInfo/SwapWindow/Prompt.text = "Swap Cards (" + str(selected_count) + " / 2)"


func get_game_session(game_id):
	game_poll_timer = 4
	
	var callback = EthersWeb.create_callback(self, "got_game_session")

	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "gameSessions", [game_id]) 
	
	EthersWeb.read_from_contract(
		test_network,
		SEPOLIA_GAME_LOGIC_ADDRESS, 
		data,
		callback
		)


func got_game_session(callback):
	if has_error(callback):
		return
	
	var session = game_session[connected_wallet]
	
	session["gameToken"] = callback["result"][0]
	session["startTimestamp"] = callback["result"][1]
	session["objectiveSeed"] = callback["result"][2]
	session["maximumSpend"] = callback["result"][3]
	session["totalPot"] = callback["result"][4]
	session["highBid"] = callback["result"][5]
	session["hasConcluded"] = callback["result"][6]
	
	$GameInfo/TopBid.text = "TOP BID: " + str(session["highBid"])
	
	# Initialize timeElapsed.
	if !"timeElapsed" in game_session:
		session["timeElapsed"] = 0
	
	# Check for the objective; if it is non-zero, the game has started.
	if session["objectiveSeed"] != "0":
		if !session["got_game_objective"]:
			session["got_game_objective"] = true
			
			session["objective"] = get_objective(session["objectiveSeed"])
			
			# Update the UI with the objective and score prediction
			update_score_prediction()
			
			# Load the game UI
			print_log("Game has started")
			session["game_started"] = true
			get_game_player_info(player_status[connected_wallet]["game_id"])
			$GameInfo.visible = true
			fade("IN", $GameInfo)
		
		



func get_game_player_info(game_id):
	game_poll_timer = 4
	var callback = EthersWeb.create_callback(self, "got_game_player_info")

	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "getAllPlayers", [game_id]) 
	
	EthersWeb.read_from_contract(
		test_network,
		SEPOLIA_GAME_LOGIC_ADDRESS, 
		data,
		callback
		)


func got_game_player_info(callback):
	if has_error(callback):
		return
	
	var players = callback["result"][0]
	var exited = callback["result"][1]
	var vrfSwapSeeds = callback["result"][2]
	var scores = callback["result"][3]
	var totalBids = callback["result"][4]
	
	update_opponent_list(callback)
	
	var session = game_session[connected_wallet]
	
	var player = player_status[connected_wallet]
	
	# Check the time remaining.
	if session["game_started"]:
		get_time_limit(session["startTimestamp"])
	
	var player_index = player["player_index"]


	var vrf_swap_seed = vrfSwapSeeds[int(player_index)]
	player["hand"]["vrf_swap_seed"] = vrf_swap_seed
	
	if vrf_swap_seed == "0":
		if session["timeElapsed"] > 120:
			if !session["initiated_swap"]:
					# If seed hasn't been obtained or requested during the 2 minute window,
					# remove the option to swap
				fade("OUT", $GameInfo/SwapWindow)
	else:
		if player_status[connected_wallet]["hand"]["has_swapped"]:
			if $GameInfo/SwapWindow/SwapActuator.text != "Copy Hand":
				set_up_copy_swap()
		# DEBUG
		elif !$GameInfo/SwapWindow/SwapActuator.text in ["Finish Swap", "Copy Hand"]:
			print_log("VRF Swap Seed received.  Now prove the swap.")
			$GameInfo/SwapWindow/SwapActuator.text = "Finish Swap"
			prove_swap()


func set_up_copy_swap():
	$GameInfo/SwapWindow/SwapActuator.text = "Copy Hand"
	$GameInfo/SwapWindow/HandText.text = Marshalls.utf8_to_base64( str(player_status[connected_wallet]["hand"]) )


func update_opponent_list(callback):
	var players = callback["result"][0]
	var exited = callback["result"][1]
	var vrfSwapSeeds = callback["result"][2]
	var scores = callback["result"][3]
	var totalBids = callback["result"][4]
	
	# Initialize the opponent list
	var session = game_session[connected_wallet]
	if session["players"].is_empty():
		session["players"] = players
		initialize_opponent_list(players)
	
	for opponent in $Opponents.get_children():
		var index = opponent.index
		
		# Check if opponent hand probability has been calculated:
		if session["predicted_score"] != 0:
			if !opponent.probability_calculated:
				calculate_opponent_hand_score(opponent.address)
		
		# Check if opponent has exited the game
		# DEBUG - simulated
		if exited[0] != "0x0000000000000000000000000000000000000000":
		#if exited[index] != "0x0000000000000000000000000000000000000000":
			
			# DEBUG - simulated
			if str(scores[0]) != "0":
			#if str(scores[index]) != "0":
				
				# DEBUG - simulated
				opponent.final_score = str(scores[0])
				#opponent.final_score = str(scores[index])
			
			else:
				opponent.folded = true
		
		# Check if opponent swapped
		# DEBUG - simulated
		if vrfSwapSeeds[0] != "0":
		#if vrfSwapSeeds[index] != "0":
			if !opponent.swapped:
				# DEBUG - simulated
				var swapped_cards = generate_hand(vrfSwapSeeds[0], generate_nullifier_set(2))
				#var swapped_cards = generate_hand(vrfSwapSeeds[index], generate_nullifier_set(2))
				opponent.load_swapped_cards(swapped_cards["cards"])
		
		# Update opponent bid
		# DEBUG - simulated
		opponent.totalBid = totalBids[0]
		#opponent.totalBid = totalBids[index]
		
		# Update the opponent UI
		opponent.update()



func initialize_opponent_list(players):
	var y_shift = 0
	var index = 0
		
	# DEBUG 
	# Opponent simulation
	for player in [connected_wallet, connected_wallet, connected_wallet]:
	#for player in players:
			
		# DEBUG
		# For now, just simulate the opponent
		
		#DEBUG ! ! 
		if player == connected_wallet:
		#if player != connected_wallet:
			
			var new_opponent = opponent_scene.instantiate()
			new_opponent.index = index
			
			new_opponent.address = player
				
			$Opponents.add_child(new_opponent)
			new_opponent.position.y += y_shift
			# DEBUG
			# The opponent scene is 187 pixels on y axis
			y_shift += 191
			
		index += 1



func actuate_swap():
	
	if $GameInfo/SwapWindow/SwapActuator.text == "Initiate Swap":
		if game_session[connected_wallet]["selected_card_indices"].size() == 2:
			print_log("Initiating swap...")
			swap_cards()
		else:
			print_log("Select 2 cards")
	elif $GameInfo/SwapWindow/SwapActuator.text == "Prove Swap":
		prove_swap()
	elif $GameInfo/SwapWindow/SwapActuator.text == "Copy Hand":
		copy_text($GameInfo/SwapWindow/HandText)




# Needs to resolve based on tx type
func receive_tx_receipt(tx_receipt):
	
	var tx_hash = tx_receipt["hash"]
	var status = str(tx_receipt["status"])
	
	var tx_type = tx_receipt["tx_type"]
	
	if status == "1":
		var blockNumber = str(tx_receipt["blockNumber"])
		print_log("Tx included in block " + blockNumber)
		
		if tx_type == "FOLD":
			# Exit the game after folding
			print_log("Folded, exiting game...")
			reset_states()
		
		if tx_type == "RAISE":
			var amount = tx_receipt["amount"]
			# DEBUG
			var total_bid_amount = int(player_status[connected_wallet]["total_bid_amount"]) + int(amount)
			player_status[connected_wallet]["total_bid_amount"] = str(total_bid_amount)
			$GameInfo/Bid.text = str(player_status[connected_wallet]["total_bid_amount"]) + " / 1000"
	
		
		if tx_type == "CONCLUDE_GAME":
			print_log("Concluding game...")
			reset_states()
		
		if tx_type in ["START_GAME", "INITIATE_SWAP"]:
			print_log("Awaiting VRF Response...")
		
		if tx_type in ["ZK_PROOF"]:
			# After successfully proving cards at the end of the game,
			# exit the game session
			if game_session[connected_wallet]["proving_cards"]:
				game_session[connected_wallet]["proving_cards"] = false
				print_log("Proved cards, exiting game...")
				reset_states()
			
			# After successfully proving the swap, update the cards
			# and prompt the player to copy the new hand data.
			if game_session[connected_wallet]["initiated_swap"]:
				game_session[connected_wallet]["initiated_swap"] = false
				
				player_status[connected_wallet]["hand"]["has_swapped"] = true
				set_up_copy_swap()
				
				var index = 0
				for card in $Cards.get_children():
					card.num = player_status[connected_wallet]["hand"]["cards"][index]
					card.alter_appearance()
					index += 1
				
				# Update the UI
				update_score_prediction()
					
					
		
	if status == "0":
		print_log("Transaction failed")
		
	get_token_balance(connected_wallet)
	get_player_status(connected_wallet)



func print_log(txt):
	$Log.text += "> " + txt + "\n"
	$Log.scroll_vertical = $Log.get_v_scroll_bar().max_value


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

	EthersWeb.send_transaction(test_network, SEPOLIA_GAME_LOGIC_ADDRESS, data, "0", null, _callback)
	
	print_log("ZKP Generated")

	


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
				game_session[connected_wallet]["initiated_swap"] = true
				$GameInfo/SwapWindow/SwapActuator.text = "Awaiting VRF"
				print_log("Waiting for swap seed...")
		
		
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
					if player_status[connected_wallet]["game_id"] != "0":
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





### GAME CONSTANTS

const local_seeds = [948321578921, 323846237643, 29478234787, 947289484324, 4827847813436, 98432542473237, 56324278238234, 77238476429378, 10927437265398, 32589475384735, 87834727625345, 7723645230273, 298467856729, 233652987328, 2389572388357, 23858923387534, 1242398565735, 6875282937855, 82984325902750, 48547252957635743]

const deck = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
const hand_size = 5

const ante = "100"
const maximum_spend = "1000"




## NEW HAND FUNCTIONS

func buy_seed():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
	
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "buyHandSeed", [connected_wallet, SEPOLIA_GAME_TOKEN_ADDRESS, ante])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "GET_HAND_VRF"})
	# Gas limit must be specified because ethers.js will underestimate
	
	# DEBUG
	# the necessary GAS LIMIT varies by network
	EthersWeb.send_transaction(test_network, SEPOLIA_GAME_LOGIC_ADDRESS, data, "0.002", "360000", _callback)
	#EthersWeb.send_transaction(test_network, SEPOLIA_GAME_LOGIC_ADDRESS, data, "0.002", "260000", _callback)



func get_hand_zk_proof():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
	
	var hand = player_status[connected_wallet]["hand"]
	
	if !"vrf_seed" in hand.keys():
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
		# This array must contain [TABLE_SIZE] players, i.e. 4 players
		# Right now just solo
		[connected_wallet]
	]
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "startGame", params)
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "START_GAME"})
	
	# DEBUG
	# the necessary GAS LIMIT varies by network
	EthersWeb.send_transaction(test_network, SEPOLIA_GAME_LOGIC_ADDRESS, data, "0.002", "480000", _callback)
	#EthersWeb.send_transaction(test_network, SEPOLIA_GAME_LOGIC_ADDRESS, data, "0.002", "380000", _callback)
	




func raise():
	
	var amount = int($GameInfo/RaiseAmount.text)
	var total_bid_amount = int(player_status[connected_wallet]["total_bid_amount"])
	var maximum_spend = int(game_session[connected_wallet]["maximumSpend"])
	if amount + total_bid_amount > maximum_spend:
		print_log("Bid exceeds maximum spend")
		return
	
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "raise", [SEPOLIA_GAME_TOKEN_ADDRESS, amount])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "RAISE", "amount": amount})
	EthersWeb.send_transaction(test_network, SEPOLIA_GAME_LOGIC_ADDRESS, data, "0", null, _callback)


func fold():
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "fold", [SEPOLIA_GAME_TOKEN_ADDRESS])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "FOLD"})
	EthersWeb.send_transaction(test_network, SEPOLIA_GAME_LOGIC_ADDRESS, data, "0", null, _callback)


func swap_cards():

	var indices = game_session[connected_wallet]["selected_card_indices"]
	indices.sort()
	
	var nullifier = generate_nullifier_set(1)[0]
	
	# Cache for proving once VRF seed has returned
	var discarded_cards = {
		"indices": indices,
		"nullifier": nullifier
	}
	
	player_status[connected_wallet]["hand"]["discarded_cards"] = discarded_cards
	
	var poseidon_hash = poseidon([indices[0], indices[1], nullifier])
	
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "swapCards", [SEPOLIA_GAME_TOKEN_ADDRESS, poseidon_hash])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "INITIATE_SWAP"})
	
	# DEBUG
	# the necessary GAS LIMIT varies by network
	EthersWeb.send_transaction(test_network, SEPOLIA_GAME_LOGIC_ADDRESS, data, "0.002", "360000", _callback)
	#EthersWeb.send_transaction(test_network, SEPOLIA_GAME_LOGIC_ADDRESS, data, "0.002", "260000", _callback)

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
	
	# This is the direct reference, NOT a copy,
	# so changes will persist.
	var hand = player_status[connected_wallet]["hand"]

	var vrf_swap_seed = hand["vrf_swap_seed"]
	var old_cards = hand["card_hashes"]
	var indices = game_session[connected_wallet]["selected_card_indices"]
	var new_nullifiers = generate_nullifier_set(2)
	var discard_nullifier = hand["discarded_cards"]["nullifier"]
	
	

	# Update the hand and hand hash with the new cards.
	#     #     #     #     #     #     #     #     #     #
	hand["nullifiers"][indices[0]] = new_nullifiers[0]
	hand["nullifiers"][indices[1]] = new_nullifiers[1]
	
	var drawn_cards = generate_hand(vrf_swap_seed, new_nullifiers)
	
	hand["cards"][indices[0]] = drawn_cards["cards"][0]
	hand["cards"][indices[1]] = drawn_cards["cards"][1]

	var card_hashes = []
	for i in range(5):
		var card_hash = poseidon([hand["cards"][i], hand["nullifiers"][i]])
		card_hashes.push_back(card_hash)
	
	hand["hand_hash"] = poseidon(card_hashes)
	
	#     #     #     #     #     #     #     #     #     #
	
	var inputs = {
		
		"vrfSeed": vrf_swap_seed,
		
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
	
	print_log("Generating ZKP to prove swap...")
	
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
	
	var hand = player_status[connected_wallet]["hand"]
	
	var nullifiers = hand["nullifiers"]
	var cards = hand["cards"]
	
	var inputs = {
		
		"nullifiers": nullifiers,
		
		"cards": cards,
		
		"gameToken": SEPOLIA_GAME_TOKEN_ADDRESS
	}
	
	var public_types  = [
		["uint256"],
		["uint256"],
		["uint256"],
		["uint256"],
		["uint256"],
		["uint256"],
		["address"]
	]
	
	print_log("Generating ZKP to prove cards...")
	
	game_session[connected_wallet]["proving_cards"] = true
	
	calculateProof(
		inputs, 
		public_types, 
		playCards_zk_circuit, 
		playCards_zk_proving_key, 
		window.playCardsWitnessCalculator,
		"provePlayCards")
	
	


func conclude_game():
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "concludeGame", [player_status[connected_wallet]["game_id"]])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "CONCLUDE_GAME"})
	EthersWeb.send_transaction(test_network, SEPOLIA_GAME_LOGIC_ADDRESS, data, "0", null, _callback)






## TOKEN MANAGEMENT

func mint_and_deposit():
	var deposit_contract = SEPOLIA_GAME_LOGIC_ADDRESS
	var data = EthersWeb.get_calldata(GAME_TOKEN_ABI, "mintAndDeposit", [connected_wallet, deposit_contract])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "DEPOSIT"})
	EthersWeb.send_transaction(test_network, SEPOLIA_GAME_TOKEN_ADDRESS, data, "0.0001", "220000", _callback)


func withdraw_eth():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
	
	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "withdrawGameToken", [SEPOLIA_GAME_TOKEN_ADDRESS])
	
	var _callback = EthersWeb.create_callback(self, "await_transaction", {"tx_type": "WITHDRAW"})
	EthersWeb.send_transaction(test_network, SEPOLIA_GAME_LOGIC_ADDRESS, data, "0", null, _callback)



## HELPER FUNCTIONS

func calculate_opponent_hand_score(opponent_address):
	var callback = EthersWeb.create_callback(self, "get_opponent_probability", {"opponent_address": opponent_address})

	var data = EthersWeb.get_calldata(GAME_LOGIC_ABI, "tokenPlayerStatus", [opponent_address, SEPOLIA_GAME_TOKEN_ADDRESS]) 
	
	EthersWeb.read_from_contract(
		test_network,
		SEPOLIA_GAME_LOGIC_ADDRESS, 
		data,
		callback
		)
	
	

func get_opponent_probability(callback):
	if has_error(callback):
		return
	
	var vrf_seed = callback["result"][0]
	
	var session = game_session[connected_wallet]
	var objective_attractor = session["objective"]["attractor"]
	var objective_color = session["objective"]["color"] 
	var nullifiers = generate_nullifier_set(hand_size)
	
	var count = 0.0
	
	var player_predicted_score = session["predicted_score"]
	
	for local_seed in local_seeds:
		var cards = generate_hand(vrf_seed, nullifiers, local_seed)["cards"]
		var score = predict_score(objective_attractor, objective_color, cards)
		if score > player_predicted_score:
			count += 1.0
	
	var probability = count / 20.0
	
	var opponent_address = callback["opponent_address"]
	
	for opponent in $Opponents.get_children():
		if opponent.address == opponent_address:
			opponent.probability_calculated = true
			opponent.probability = probability * 100
			opponent.update()
	
	




# Predict hands using the set of local seeds
func generate_hand(_vrf_seed, nullifiers, fixed_seed=null):
	
	var _hand_size = nullifiers.size()
	
	var _deck = deck.duplicate()
	
	# Apply the field modulus before hashing, otherwise large values 
	# won't validate properly
	var vrf_seed = window.zkBridge.bigNumberModulus(_vrf_seed, FIELD_MODULUS)
	
	# Swaps just use the vrf seed, while drawing a hand combines the
	# vrf seed with a fixed local seed
	var seed_hash = vrf_seed
	if fixed_seed:
		seed_hash = poseidon([vrf_seed, fixed_seed])
	else:
		# If it is a swap, append 21 to the deck
		_deck.push_back(21)
	
	var picked_cards = []
	
	for card_draw in range(_hand_size):
		seed_hash = poseidon([seed_hash])
	
		var index = int(window.zkBridge.bigNumberModulus(seed_hash, _deck.size()))
	
		picked_cards.push_back(_deck[index])
	
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
		"hand_hash": hand_hash,
		"vrf_swap_seed": "0",
		"has_swapped": false
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
	
	
	# DEBUG
	# BIG NOTE
	# The inSet template in the handDraw circuit is broken;
	# the for loop should be checking i < length + 1, but currently
	# just checks length, which means that max rolls will erroneously 
	# turn up invalid.  Fix this later
	var index = window.zkBridge.bigNumberModulus(bytes, 19)
	#var index = window.zkBridge.bigNumberModulus(bytes, 20)
	var local_seed = local_seeds[int(index)]
	return local_seed


func get_objective(vrf_seed):
	var obj_attractor = int(window.zkBridge.bigNumberModulus(vrf_seed, 10)) + 1
	var obj_color = int(window.zkBridge.bigNumberModulus(vrf_seed, 2)) + 1
	
	var objective = {
		"attractor": obj_attractor,
		"color": obj_color
	}
	return objective

# From contract logic 
func predict_score(obj_attractor, obj_color, cards):
	
	# Determine if the score will be inverted
	var inverse = false
	for card in cards:
		if card == 21:
			if inverse == false:
				inverse = true
			else:
				inverse = false
				
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
		
		# Inverse cards have no suit and are not
		# affected by the attractor
		if card == 11:
			score += 11
		else:
			# Cards closest to the attractor have a higher base score;
			# cards of the objective color have their base score multiplied by 2
			score += (10 - diff) * color_bonus
	
	if inverse:
		score = 100 - score
	
	return score


func get_time_limit(start_timestamp):
	var callback = EthersWeb.create_callback(self, "got_timestamp", {"start_timestamp": start_timestamp})
	EthersWeb.get_block_timestamp(callback)

func got_timestamp(callback):
	if has_error(callback):
		return

	var time_elapsed = int(callback["result"]) - int(callback["start_timestamp"])
	game_session[connected_wallet]["timeElapsed"] = time_elapsed
	
	# DEBUG
	var time_remaining = 240 - time_elapsed
	
	$GameInfo/Time.visible = true
	$GameInfo/Time.text = "TIME REMAINING: " + str(time_remaining)
	
	if time_elapsed > 240 && !game_session[connected_wallet]["entered_prove_phase"]:
		game_session[connected_wallet]["entered_prove_phase"] = true
		end_play_phase()
	
	if time_elapsed > 600 && !game_session[connected_wallet]["entered_conclusion_phase"]:
		game_session[connected_wallet]["entered_conclusion_phase"] = true
		conclusion_phase()


func end_play_phase():
	$RevealCards.visible = true
	fade("OUT", $GameInfo, fade.bind("IN", $RevealCards))

func conclusion_phase():
	$GameInfo.visible = false
	$RevealCards.visible = false
	$ConcludeGame.visible = true
	fade("IN", $ConcludeGame)
	# DEBUG
	# Conclusion button


## UI HELPERS


# UI and State Variables
var connect_button_position = Vector2(50,25)
var prompt_connect = true
var must_copy_hand = true
var PREGAME_STATE = ""
var in_game = false


func initialize_game_state():
	game_session[connected_wallet] = {
		"players": [],
		"timeElapsed": 0,
		"predicted_score": 0,
		"game_started": false,
		"got_game_objective": false,
		"selected_card_indices": [],
		"initiated_swap": false,
		"entered_prove_phase": false,
		"proving_cards": false,
		"entered_conclusion_phase": false
	}



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

func reset_states():
	$Info.modulate.a = 1
	$Info.visible = true
	$Curtain.modulate.a = 1
	fade("OUT", $Curtain)
	poll_timer = 1.5
	status_poll_timer = 4
	PREGAME_STATE = ""
	reset_prompts()
	remove_overlay()
	reset_game_ui()

func reset_game_ui():
	$GameInfo.modulate.a = 0
	$GameInfo.visible = false
	$GameInfo/Time.visible = false
	$GameInfo/TopBid.text = "TOP BID: 0"
	$GameInfo/SwapWindow/SwapActuator.text = "Initiate Swap"
	$GameInfo/SwapWindow/HandText.text = ""
	$GameInfo/SwapWindow.modulate.a = 1
	$GameInfo/RaiseAmount.text = "100"
	$RevealCards.modulate.a = 0
	$ConcludeGame.modulate.a = 0
	$RevealCards.visible = false
	$ConcludeGame.visible = false
	$GameInfo/Objective.text = ""

	for card in $Cards.get_children():
		card.queue_free()
	
	for opponent in $Opponents.get_children():
		opponent.queue_free()
		
	in_game = false
	game_session[connected_wallet] = {}


func update_score_prediction():
	var session = game_session[connected_wallet]
	
	var objective_attractor = session["objective"]["attractor"]
	var objective_color = session["objective"]["color"]
	var cards = player_status[connected_wallet]["hand"]["cards"]
	var predicted_score = predict_score(objective_attractor, objective_color, cards) 
			
	session["predicted_score"] = predicted_score
	
	var color_text = "Blue"
	if objective_color == 2:
		color_text = "Silver"
	$GameInfo/Objective.text = "Attractor: " + str(objective_attractor) + "\nColor: " + color_text + "\nPredicted Score: " + str(predicted_score)
