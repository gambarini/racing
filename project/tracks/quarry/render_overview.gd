## Renders the Quarry top-down overview (hillshaded surface map, centre line, gates, start) to
## res://tracks/quarry/quarry_overview.png (4 px per terrain cell).
## Run: godot --headless --path project -s res://tracks/quarry/render_overview.gd
extends SceneTree

const PX := 2 ## pixels per terrain cell edge


func _initialize() -> void:
	_main()


func _main() -> void:
	var q := Quarry.new()
	root.add_child(q)
	await process_frame
	var t := q.terrain
	var n := Quarry.N
	var img := Image.create(n * PX, n * PX, false, Image.FORMAT_RGB8)
	var cols := {
		&"tarmac": Color(0.25, 0.25, 0.28), &"dirt": Color(0.62, 0.45, 0.28), &"grass": Color(0.38, 0.52, 0.30),
		&"gravel": Color(0.72, 0.70, 0.66), &"mud": Color(0.33, 0.22, 0.14),
	}
	for iz in n:
		for ix in n:
			var x := ix * Quarry.CELL
			var z := iz * Quarry.CELL
			var w := t.surface_at(x, z)
			var c := Color(0, 0, 0)
			for id in w:
				c += (cols[id] as Color) * w[id]
			var shade := (t.height_at(x - 2, z - 2) - t.height_at(x + 2, z + 2)) * 0.06
			var hs := clampf(1.0 + shade + (t.height_at(x, z) - 18.0) * 0.015, 0.6, 1.4)
			c = Color(c.r * hs, c.g * hs, c.b * hs)
			for dy in PX:
				for dx in PX:
					img.set_pixel(ix * PX + dx, iz * PX + dy, c)
	var len := q.track.length()
	for i in int(len / 2.0):
		var p: Vector3 = q.track.sample(i * 2.0)["position"]
		_dot(img, p, Color(1, 1, 1), 1)
	for off in q.track.gate_offsets:
		_dot(img, q.track.sample(off)["position"], Color(1, 0.1, 0.1), 4)
	_dot(img, q.track.sample(q.track.gate_offsets[0])["position"], Color(1, 1, 0), 6)
	img.save_png("res://tracks/quarry/quarry_overview.png")
	print("saved ", ProjectSettings.globalize_path("res://tracks/quarry/quarry_overview.png"))
	quit()


func _dot(img: Image, p: Vector3, c: Color, r: int) -> void:
	var cx := int(p.x / Quarry.CELL * PX)
	var cy := int(p.z / Quarry.CELL * PX)
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var x := cx + dx
			var y := cy + dy
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				img.set_pixel(x, y, c)
