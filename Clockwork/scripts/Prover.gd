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

# For local Poseidon Hashing 
# Accessed at "window.IdenJsCrypto"
var js_crypto_filepath = "res://js/js_crypto.js"

# Required files for proving
var zk_circuit = "res://zk/addressbind.wasm"
var zk_proving_key = "res://zk/addressbind_final.zkey"

# Accessed at "window.witnessCalculatorBuilder"
var witness_calculator_filepath = "res://js/witness_calculator.js"



func _ready():
	connect_buttons()
	load_and_attach(snarkjs_filepath)
	
	# witness_calculator.js is not a library and needs to be attached to the
	# window using a wrapper (see below)
	load_and_attach(witness_calculator_filepath, "witnessCalculatorBuilder")
	load_and_attach(js_crypto_filepath)
	load_and_attach(zk_bridge_filepath)



func connect_buttons():
	$ConnectWallet.connect("pressed", connect_wallet)
	$WalletInfo.connect("pressed", get_wallet_info)

	$GetProof.connect("pressed", get_zk_proof)

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


func get_zk_proof():
	if !connected_wallet:
		print_log("Please connect your wallet")
		return
		
	# Parameter names must match circuit inputs' names
	var inputs = {"a": 4, "b": 3, "_address": str(connected_wallet)}
	
	# Must define public_types in callback
	var public_types  = [
		["uint256"],
		["address"]
	]
	
	var callback = EthersWeb.create_callback(self, "get_proof_calldata", {"public_types": public_types})
	
	
	calculateProof(inputs, callback)



func calculateProof(_inputs, callback="{}"):
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
	
	if "public_types" in callback:
		public = get_decoded_array(proof[3], callback["public_types"])
		public_count += proof[3].size()
	
	var decoded_values = [a, b, c, public]
	
	var ABI = [{
		"name": "verifyProof",
		
		"inputs" : [
		{"type": "uint256[2]"},
		{"type": "uint256[2][2]"},
		{"type": "uint256[2]"},
		{"type": "uint256[" + str(public_count) + "]"}
		]
	}]

	# Ready to send to contract
	var calldata = EthersWeb.get_calldata(ABI, "verifyProof", decoded_values)
	
	
	# ETHEREUM SEPOLIA
	var verifier_contract = "0xd11680F0cDF6d531f4fEf6ADa888Fbf55246FB7c"
	EthersWeb.send_transaction("Ethereum Sepolia", verifier_contract, calldata)
	
	
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
