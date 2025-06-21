extends TextureRect

var hexagon_scene = preload("res://scenes/Hexagon.tscn")
var propagation = 4
var propagation_timer = 0.1

var main

func _ready():
	# $Main/Hexagons/Hexagon
	main = get_parent().get_parent()
	var tween = create_tween()
	tween.tween_property(self, "modulate:a", 1, 0.3).set_delay(0.2)
	tween.tween_property(self, "modulate:a", 0, 0.5)
	tween.tween_callback(queue_free)
	tween.play()

func _process(delta):
	
	propagation_timer -= delta
	if propagation_timer < 0:
		propagation_timer = 0.1
	
		if propagation > 0:
			propagation -= 1
			propagate()


var hex_size = Vector2(100, 100)  
var hex_directions = [
	Vector2(1, 0), Vector2(1, -1), Vector2(0, -1),
	Vector2(-1, 0), Vector2(-1, 1), Vector2(0, 1)]

func propagate():

	var new_hexagon = hexagon_scene.instantiate()

	new_hexagon.propagation = propagation - 1
	
	var random_point = [0,0]
	var attempt = 0
	while random_point in main.hexagon_positions && attempt < 6:
		random_point = position + (hex_directions[randi() % 6] * hex_size)
		attempt += 1
		
	main.hexagon_positions.push_back(random_point)

	new_hexagon.position = random_point

	get_parent().add_child(new_hexagon)
	
