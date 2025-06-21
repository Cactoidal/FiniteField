extends Control

var address
var index
var probability

var final_score

# DEBUG
# Initialized here because the function that updates the totalBid
# first checks whether it is lower than the incoming value
var totalBid = 0

var folded

var probability_calculated = false
var swapped = false
var swapped_cards 

var card_scene = preload("res://scenes/Card.tscn")

func _ready():
	modulate.a = 0
	var tween = create_tween()
	tween.tween_property(self, "modulate:a", 1, 1)
	tween.play()


func update():
	$Background/Address.text = address
	$Background/Bid.text = "BID: " + str(totalBid)
	
	if probability:
		$Background/Info/Probability.visible = true
		$Background/Info/Probability.text = str(probability) + "% Chance of Higher Initial Score"
	
	if folded:
		$Background/Info.visible = false
		$Background/Folded.visible = true
	
	if final_score:
		$Background/FinalScore.text = "Final Score:\n" + str(final_score)
		$Background/FinalScore.visible = true
		$Background/Info.visible = false



func load_swapped_cards(cards):
	if swapped:
		return
	swapped = true
	
	swapped_cards = cards
	
	var i = 0
	for card in cards:
		var new_card = card_scene.instantiate()
		new_card.is_opponent_card = true
		new_card.num = card
		match i:
			0: $Background/Info/Card1.add_child(new_card)
			1: $Background/Info/Card2.add_child(new_card)
		i += 1;
	

func raise_animation(new_total_bid):
	var amount = int(new_total_bid) - int(totalBid)
	$Background/Raised.text = "Raised: +" + str(amount)
	$Background/Raised.modulate.a = 1
	var tween = create_tween()
	tween.tween_property($Background/Raised, "modulate:a", 1, 1) # 1 second delay
	tween.tween_property($Background/Raised, "modulate:a", 0, 4)
	tween.play()
