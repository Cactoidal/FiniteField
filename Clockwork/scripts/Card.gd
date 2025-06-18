extends Control

var suit_color = Color.BLUE
var num = 7
var x_slide = 0
var slide_target
var finished_sliding = false

var main
var index

func _ready():
	alter_appearance()
	
	$Color/Button.connect("pressed", select_card)
	slide_target = position.x + x_slide

	slide_out()


func alter_appearance():
	var display_num = num
	if display_num > 10:
		suit_color = Color.SILVER
		display_num -= 10
		
		# Inverse cards are a separate color
		if display_num == 11:
			Color.DARK_ORANGE
	else:
		suit_color = Color.BLUE
	
	$Color/Number.text = str(display_num)
	
	$Color.color = suit_color
	if suit_color == Color.SILVER:
		$Color/Number.add_theme_color_override("font_color", Color.BLACK)
	else:
		$Color/Number.add_theme_color_override("font_color", Color.WHITE)


func slide_out():
	var tween = create_tween()
	tween.tween_property(self, "position:x", slide_target, 1.4).set_trans(Tween.TRANS_QUAD)
	tween.tween_callback(finish_slide)
	tween.play()


func finish_slide():
	finished_sliding = true
	$Highlight.position = $Color.position - Vector2(2,2)

func select_card():
	if !finished_sliding:
		return
	
	main.update_card_indices(index)


func show_highlight():
	$Highlight.visible = true

func deactivate_highlight():
	$Highlight.visible = false
