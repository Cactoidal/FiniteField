extends ColorRect

var random = true
@onready var high = $RangeButtons/High
@onready var mid = $RangeButtons/Mid
@onready var low = $RangeButtons/Low

@onready var blue = $ColorButtons/Blue
@onready var silver = $ColorButtons/Silver

var obj_attractor = 5
var obj_color = 1

func _ready():
	$Random.connect("pressed", pick_random)
	
	high.connect("pressed", pick_button.bind(high))
	mid.connect("pressed", pick_button.bind(mid))
	low.connect("pressed", pick_button.bind(low))
	
	blue.connect("pressed", pick_button.bind(blue))
	silver.connect("pressed", pick_button.bind(silver))

func pick_random():
	if random:
		$Random.button_pressed = true
		return
		
	random = true
	for button in $RangeButtons.get_children():
		button.button_pressed = false
	
	for button in $ColorButtons.get_children():
		button.button_pressed = false

func pick_button(exempt):
	random = false
	$Random.button_pressed = false
	
	var button_set = exempt.get_parent()
	
	for button in button_set.get_children():
		if button != exempt:
			button.button_pressed = false
	
	exempt.button_pressed = true
	
	match exempt:
		high: obj_attractor = 8
		mid: obj_attractor = 5
		low: obj_attractor = 2
		blue: obj_color = 1
		silver: obj_color = 2
