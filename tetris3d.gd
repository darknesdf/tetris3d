extends Node3D
## TETRIS 3D untuk Godot 4.x - satu skrip, semuanya dibuat lewat kode.
## Proyek siap main: buka folder ini di Godot 4.2+ lalu tekan F5.
## Tidak butuh file gambar/suara: semua suara dibuat otomatis oleh kode.

const W := 10
const H := 20
const RATE := 22050
const STEP := 56.0
const HAPTIC := {"rotate": 8, "lock": 18, "drop": 40, "clear": 70, "tetris": 140}
const SAVE_PATH := "user://tetris3d.save"
const KEYS := ["I", "O", "T", "S", "Z", "J", "L"]

const SHAPES := {
	"I": [Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
	"O": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
	"T": [Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)],
	"S": [Vector2i(-1, 0), Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1)],
	"Z": [Vector2i(-1, 1), Vector2i(0, 1), Vector2i(0, 0), Vector2i(1, 0)],
	"J": [Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0)],
	"L": [Vector2i(1, 1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0)],
}

const COLORS := {
	"I": Color(0.0, 0.9, 1.0),
	"O": Color(1.0, 0.9, 0.1),
	"T": Color(0.7, 0.2, 1.0),
	"S": Color(0.2, 1.0, 0.3),
	"Z": Color(1.0, 0.2, 0.25),
	"J": Color(0.2, 0.4, 1.0),
	"L": Color(1.0, 0.55, 0.1),
}

# ---------- status game ----------
var grid: Array = []          # grid[y][x] = 0 (kosong) atau 1..7 (warna)
var blocks: Array = []        # blocks[y][x] = MeshInstance3D atau null
var state := "menu"           # menu / playing / clearing / over
var cur_type := ""
var cur_cells: Array = []
var cur_pos := Vector2i.ZERO
var cur_nodes: Array[MeshInstance3D] = []
var ghost_nodes: Array[MeshInstance3D] = []
var next_nodes: Array[MeshInstance3D] = []
var bag: Array = []
var next_type := ""
var score := 0
var lines := 0
var level := 1
var fall_t := 0.0
var soft := false
var held := ""
var held_t := 0.0
var held_first := true
var shake := 0.0
var bests := [0, 0]            # rekor: [klasik, gravitasi]
var rule_gravity := false
var rule_btn: Button
var best: int:
	get:
		return bests[1 if rule_gravity else 0]
	set(v):
		bests[1 if rule_gravity else 0] = v
var touch_ui := false
var use_pad := false          # false = gestur, true = tombol layar
var pad: Array = []           # [tombol, aksi]
var ui_btns: Array[Button] = []
var fingers := {}             # index jari -> aksi tombol
var g_id := -1
var g_total := Vector2.ZERO
var g_acc := Vector2.ZERO
var g_vel := Vector2.ZERO
var g_time := 0.0
var mode_btn: Button
var t_total := 0.0

# ---------- objek ----------
var cam: Camera3D
var cube_mesh: BoxMesh
var mats := {}
var ghost_mat: StandardMaterial3D
var flash_mat: StandardMaterial3D
var bg_cubes: Array = []
var sfx := {}
var players: Array[AudioStreamPlayer] = []
var music: AudioStreamPlayer
var lbl_info: Label
var lbl_msg: Label
var start_btn: Button


func _ready() -> void:
	randomize()
	get_window().size_changed.connect(_on_resize)
	_on_resize()
	_build_world()
	_build_audio()
	_build_ui()
	_load_best()
	_reset_grid()
	lbl_msg.text = "TETRIS 3D\n\nPanah / WASD: geser, turun   Atas: putar\nSpasi: jatuhkan   P: jeda   M: ganti mode"
	if touch_ui:
		lbl_msg.text = "TETRIS 3D\n\nGeser: pindah   Tarik ke bawah: turun\nTap: putar   Sentak ke bawah: jatuhkan"
	start_btn.text = "MULAI"
	_update_hud()


# =====================================================================
#  DUNIA 3D: cahaya, bayangan, dinding, kamera
# =====================================================================
func _build_world() -> void:
	cube_mesh = BoxMesh.new()
	cube_mesh.size = Vector3.ONE * 0.94

	var bsh := Shader.new()
	bsh.code = """
shader_type spatial;
uniform vec4 col : source_color = vec4(1.0);
void fragment() {
	vec2 d = min(UV, 1.0 - UV);
	float edge = 1.0 - smoothstep(0.03, 0.17, min(d.x, d.y));
	vec3 rim = mix(col.rgb, vec3(1.0), 0.6);
	ALBEDO = mix(col.rgb * 0.78, rim, edge);
	EMISSION = col.rgb * 0.3 + rim * edge * 0.45;
	METALLIC = 0.3;
	ROUGHNESS = 0.25;
}
"""
	for k in KEYS:
		var m := ShaderMaterial.new()
		m.shader = bsh
		m.set_shader_parameter("col", COLORS[k])
		mats[k] = m

	ghost_mat = StandardMaterial3D.new()
	ghost_mat.albedo_color = Color(1, 1, 1, 0.18)
	ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_mat.emission_enabled = true
	ghost_mat.emission = Color(1, 1, 1)
	ghost_mat.emission_energy_multiplier = 0.5

	flash_mat = StandardMaterial3D.new()
	flash_mat.albedo_color = Color(1, 1, 1)
	flash_mat.emission_enabled = true
	flash_mat.emission = Color(1, 1, 1)
	flash_mat.emission_energy_multiplier = 4.0

	# Lingkungan: latar gelap + glow (efek neon)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.02, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.5, 0.7)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.1
	env.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# Cahaya utama dengan bayangan
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, -28, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.0
	sun.directional_shadow_max_distance = 50.0
	add_child(sun)

	# Dinding belakang dengan garis grid (menerima bayangan balok)
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 f = fract(wpos.xy + 0.5);
	float d = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	float line = 1.0 - smoothstep(0.0, 0.05, d);
	ALBEDO = mix(vec3(0.04, 0.05, 0.10), vec3(0.10, 0.45, 0.80), line * 0.5);
	ROUGHNESS = 0.85;
	EMISSION = vec3(0.05, 0.3, 0.5) * line * 0.6;
}
"""
	var wall_mat := ShaderMaterial.new()
	wall_mat.shader = sh
	var wall := MeshInstance3D.new()
	var wm := BoxMesh.new()
	wm.size = Vector3(10.0, 20.0, 0.2)
	wall.mesh = wm
	wall.material_override = wall_mat
	wall.position = Vector3(4.5, 9.5, -1.3)
	add_child(wall)

	# Lantai
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.06, 0.07, 0.12)
	floor_mat.metallic = 0.6
	floor_mat.roughness = 0.3
	var fl := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(11.0, 0.4, 2.4)
	fl.mesh = fm
	fl.material_override = floor_mat
	fl.position = Vector3(4.5, -0.7, 0.0)
	add_child(fl)

	# Rel samping bercahaya
	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = Color(0.0, 0.8, 1.0)
	rail_mat.emission_enabled = true
	rail_mat.emission = Color(0.0, 0.8, 1.0)
	rail_mat.emission_energy_multiplier = 1.6
	for rx in [-0.8, 9.8]:
		var rail := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(0.25, 20.8, 0.8)
		rail.mesh = rm
		rail.material_override = rail_mat
		rail.position = Vector3(rx, 9.5, 0.0)
		rail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(rail)

	# Kubus melayang di latar belakang (memberi kesan kedalaman)
	for i in 28:
		var m := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * randf_range(1.0, 3.5)
		m.mesh = bm
		var mt := StandardMaterial3D.new()
		var col := Color.from_hsv(randf_range(0.5, 0.85), 0.7, 1.0)
		mt.albedo_color = col * 0.3
		mt.emission_enabled = true
		mt.emission = col
		mt.emission_energy_multiplier = 0.25
		m.material_override = mt
		m.position = Vector3(randf_range(-22, 30), randf_range(-4, 30), randf_range(-26, -8))
		m.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(m)
		bg_cubes.append(m)

	# Balok bayangan (ghost) dan pratinjau balok berikutnya
	for i in 4:
		var g := MeshInstance3D.new()
		g.mesh = cube_mesh
		g.material_override = ghost_mat
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		g.visible = false
		add_child(g)
		ghost_nodes.append(g)

		var n := MeshInstance3D.new()
		n.mesh = cube_mesh
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		n.visible = false
		add_child(n)
		next_nodes.append(n)

	# Kamera perspektif
	cam = Camera3D.new()
	cam.fov = 55.0
	cam.current = true
	add_child(cam)
	_update_camera(0.0)


func _update_camera(delta: float) -> void:
	var asp: float = get_viewport().get_visible_rect().size.aspect()
	var portrait := asp < 0.8
	var vis_h := maxf(31.0, 14.0 / asp) if portrait else maxf(28.0, 14.0 / asp + 2.0)
	var dist := vis_h / (2.0 * tan(deg_to_rad(cam.fov * 0.5)))
	var target := Vector3(4.5, 9.0 if portrait else 11.5, 0.0)
	var sway := sin(t_total * 0.5) * (1.2 if portrait else 2.5)      # goyangan lembut agar terasa 3D
	cam.position = target + Vector3(sway, dist * 0.2, dist * 0.98)
	cam.look_at(target)
	shake = maxf(0.0, shake - delta * 2.5)
	cam.h_offset = randf_range(-1.0, 1.0) * shake
	cam.v_offset = randf_range(-1.0, 1.0) * shake


# =====================================================================
#  AUDIO: semua suara dibuat dari kode
# =====================================================================
func _tone(f0: float, f1: float, dur: float, wave := "square", vol := 0.5, decay := 4.0) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / n
		ph += lerpf(f0, f1, t) / RATE
		var s := 0.0
		match wave:
			"square":
				s = 1.0 if fmod(ph, 1.0) < 0.5 else -1.0
			"saw":
				s = fmod(ph, 1.0) * 2.0 - 1.0
			"sine":
				s = sin(TAU * ph)
			"noise":
				s = randf() * 2.0 - 1.0
		out[i] = s * vol * exp(-decay * t) * minf(1.0, i / (RATE * 0.004))
	return out


func _cat(parts: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for p in parts:
		out.append_array(p)
	return out


func _mix(a: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(maxi(a.size(), b.size()))
	for i in out.size():
		var x: float = a[i] if i < a.size() else 0.0
		var y: float = b[i] if i < b.size() else 0.0
		out[i] = x + y
	return out


func _wav(buf: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(buf.size() * 2)
	for i in buf.size():
		bytes.encode_s16(i * 2, int(clampf(buf[i], -1.0, 1.0) * 30000.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = bytes
	if loop:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = buf.size()
	return s


func _note(midi: int) -> float:
	return 440.0 * pow(2.0, (midi - 69) / 12.0)


func _build_audio() -> void:
	sfx["move"] = _wav(_tone(500, 500, 0.04, "square", 0.25, 6.0))
	sfx["rotate"] = _wav(_tone(600, 1100, 0.07, "square", 0.3, 4.0))
	sfx["lock"] = _wav(_mix(_tone(160, 70, 0.14, "sine", 0.8, 5.0), _tone(0, 0, 0.06, "noise", 0.25, 12.0)))
	sfx["drop"] = _wav(_mix(_tone(220, 40, 0.3, "sine", 1.0, 4.0), _tone(0, 0, 0.15, "noise", 0.5, 10.0)))
	sfx["clear"] = _wav(_cat([
		_tone(523, 523, 0.07, "square", 0.3, 3.0), _tone(659, 659, 0.07, "square", 0.3, 3.0),
		_tone(784, 784, 0.07, "square", 0.3, 3.0), _tone(1047, 1047, 0.2, "square", 0.3, 4.0)]))
	sfx["tetris"] = _wav(_mix(_cat([
		_tone(523, 523, 0.06, "square", 0.3, 3.0), _tone(659, 659, 0.06, "square", 0.3, 3.0),
		_tone(784, 784, 0.06, "square", 0.3, 3.0), _tone(1047, 1047, 0.06, "square", 0.3, 3.0),
		_tone(1319, 1319, 0.06, "square", 0.3, 3.0), _tone(1568, 1568, 0.35, "square", 0.3, 4.0)]),
		_tone(3000, 200, 0.6, "noise", 0.25, 3.0)))
	sfx["level"] = _wav(_cat([
		_tone(392, 392, 0.08, "square", 0.3, 3.0), _tone(523, 523, 0.08, "square", 0.3, 3.0),
		_tone(659, 659, 0.08, "square", 0.3, 3.0), _tone(784, 784, 0.25, "square", 0.3, 4.0)]))
	sfx["over"] = _wav(_tone(400, 60, 1.0, "saw", 0.4, 2.0))

	for i in 8:
		var p := AudioStreamPlayer.new()
		add_child(p)
		players.append(p)

	# Musik latar: melodi rakyat Rusia "Korobeiniki" (domain publik), diulang terus
	var mel := [
		[76, 1.0], [71, 0.5], [72, 0.5], [74, 1.0], [72, 0.5], [71, 0.5], [69, 1.0], [69, 0.5], [72, 0.5],
		[76, 1.0], [74, 0.5], [72, 0.5], [71, 1.5], [72, 0.5], [74, 1.0], [76, 1.0], [72, 1.0], [69, 1.0], [69, 2.0],
		[74, 1.5], [77, 0.5], [81, 1.0], [79, 0.5], [77, 0.5], [76, 1.5], [72, 0.5], [76, 1.0], [74, 0.5], [72, 0.5],
		[71, 1.0], [71, 0.5], [72, 0.5], [74, 1.0], [76, 1.0], [72, 1.0], [69, 1.0], [69, 1.0],
	]
	var beat := 0.4
	var buf := PackedFloat32Array()
	var bas := PackedFloat32Array()
	for n in mel:
		var dur: float = n[1] * beat
		var f := _note(n[0])
		buf.append_array(_tone(f, f, dur * 0.92, "square", 0.16, 1.2))
		bas.append_array(_tone(f * 0.25, f * 0.25, dur * 0.92, "sine", 0.2, 1.0))
		var gap := PackedFloat32Array()
		gap.resize(int(dur * 0.08 * RATE))
		buf.append_array(gap)
		bas.append_array(gap)
	music = AudioStreamPlayer.new()
	music.stream = _wav(_mix(buf, bas), true)
	music.volume_db = -10.0
	add_child(music)


func _sfx(id: String, vol := 0.0) -> void:
	if touch_ui and HAPTIC.has(id):
		Input.vibrate_handheld(HAPTIC[id])
	for p in players:
		if not p.playing:
			p.stream = sfx[id]
			p.volume_db = vol
			p.play()
			return
	players[0].stream = sfx[id]
	players[0].volume_db = vol
	players[0].play()


# =====================================================================
#  UI: skor, tombol mulai, tombol sentuh
# =====================================================================
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	lbl_info = Label.new()
	lbl_info.position = Vector2(30, 60)
	lbl_info.add_theme_font_size_override("font_size", 34)
	lbl_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(lbl_info)

	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cc)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 30)
	cc.add_child(vb)

	lbl_msg = Label.new()
	lbl_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_msg.add_theme_font_size_override("font_size", 40)
	lbl_msg.add_theme_constant_override("outline_size", 10)
	lbl_msg.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl_msg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(lbl_msg)

	start_btn = Button.new()
	start_btn.custom_minimum_size = Vector2(360, 120)
	start_btn.add_theme_font_size_override("font_size", 46)
	start_btn.focus_mode = Control.FOCUS_NONE
	start_btn.pressed.connect(_start_game)
	vb.add_child(start_btn)
	ui_btns.append(start_btn)
	rule_btn = Button.new()
	rule_btn.custom_minimum_size = Vector2(700, 130)
	rule_btn.add_theme_font_size_override("font_size", 30)
	rule_btn.focus_mode = Control.FOCUS_NONE
	rule_btn.pressed.connect(_toggle_rule)
	vb.add_child(rule_btn)
	ui_btns.append(rule_btn)

	touch_ui = DisplayServer.is_touchscreen_available() or OS.has_feature("mobile")
	if touch_ui:
		mode_btn = Button.new()
		mode_btn.custom_minimum_size = Vector2(520, 90)
		mode_btn.add_theme_font_size_override("font_size", 34)
		mode_btn.focus_mode = Control.FOCUS_NONE
		mode_btn.pressed.connect(_toggle_mode)
		vb.add_child(mode_btn)
		ui_btns.append(mode_btn)
		var pb := Button.new()
		pb.text = "II"
		pb.focus_mode = Control.FOCUS_NONE
		pb.add_theme_font_size_override("font_size", 40)
		pb.anchor_left = 1.0
		pb.anchor_right = 1.0
		pb.offset_left = -140
		pb.offset_right = -30
		pb.offset_top = 60
		pb.offset_bottom = 170
		pb.pressed.connect(_toggle_pause)
		root.add_child(pb)
		ui_btns.append(pb)
		_add_pad(root, "<", false, 30, 50, 200, 200, "left")
		_add_pad(root, ">", false, 250, 50, 200, 200, "right")
		_add_pad(root, "PUTAR", true, 30, 50, 260, 200, "rotate")
		_add_pad(root, "v", true, 310, 50, 200, 200, "down")
		_add_pad(root, "DROP", true, 30, 270, 480, 130, "drop")
		_set_mode(false)


# Tombol layar: disentuh langsung (multi-touch), bukan lewat emulasi mouse
func _add_pad(parent: Control, txt: String, right: bool, x: float, y: float, w: float, h: float, act: String) -> void:
	var b := Button.new()
	b.text = txt
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_theme_font_size_override("font_size", 46)
	b.anchor_left = 1.0 if right else 0.0
	b.anchor_right = b.anchor_left
	b.anchor_top = 1.0
	b.anchor_bottom = 1.0
	if right:
		b.offset_left = -x - w
		b.offset_right = -x
	else:
		b.offset_left = x
		b.offset_right = x + w
	b.offset_top = -y - h
	b.offset_bottom = -y
	b.modulate = Color(1, 1, 1, 0.55)
	parent.add_child(b)
	pad.append([b, act])


func _set_mode(on: bool) -> void:
	use_pad = on
	for it in pad:
		it[0].visible = on
	mode_btn.text = "KONTROL: TOMBOL" if on else "KONTROL: GESTUR"


func _toggle_mode() -> void:
	_set_mode(not use_pad)


func _on_resize() -> void:
	var ws := DisplayServer.window_get_size()
	var want := Vector2i(1080, 1920) if ws.y > ws.x else Vector2i(1920, 1080)
	if get_window().content_scale_size != want:
		get_window().content_scale_size = want


func _pad_vis(a: String, on: bool) -> void:
	for it in pad:
		if it[1] == a:
			it[0].modulate = Color(1, 1, 1, 1.0 if on else 0.55)


func _over_ui(p: Vector2) -> bool:
	for b in ui_btns:
		if b.is_visible_in_tree() and b.get_global_rect().has_point(p):
			return true
	return false


func _pad_at(p: Vector2) -> String:
	for it in pad:
		if it[0].get_global_rect().has_point(p):
			return it[1]
	return ""


func _input(e: InputEvent) -> void:
	if not touch_ui:
		return
	if e is InputEventScreenTouch:
		var t := e as InputEventScreenTouch
		if t.pressed:
			_touch_down(t.index, t.position)
		else:
			_touch_up(t.index)
	elif e is InputEventScreenDrag:
		var d := e as InputEventScreenDrag
		_touch_move(d.index, d.position, d.relative, d.velocity)


func _touch_down(i: int, p: Vector2) -> void:
	if state != "playing" or _over_ui(p):
		return
	if use_pad:
		var a := _pad_at(p)
		if a != "":
			fingers[i] = a
			_pad_vis(a, true)
			_press(a)
		return
	if g_id == -1:
		g_id = i
		g_total = Vector2.ZERO
		g_acc = Vector2.ZERO
		g_vel = Vector2.ZERO
		g_time = 0.0


func _touch_move(i: int, p: Vector2, rel: Vector2, vel: Vector2) -> void:
	if state != "playing":
		return
	if use_pad:
		if fingers.has(i):
			var a := _pad_at(p)
			var old: String = fingers[i]
			if a != old:
				_pad_vis(old, false)
				_release(old)
				if a != "":
					fingers[i] = a
					_pad_vis(a, true)
					_press(a)
				else:
					fingers.erase(i)
		return
	if i != g_id:
		return
	g_total += rel
	g_vel = vel
	if absf(g_total.y) > absf(g_total.x) * 1.5:
		g_acc.x = 0.0
		g_acc.y = maxf(0.0, g_acc.y + rel.y)
		while g_acc.y >= STEP * 1.1:
			g_acc.y -= STEP * 1.1
			_step_down()
	else:
		g_acc.y = 0.0
		g_acc.x += rel.x
		while absf(g_acc.x) >= STEP:
			var dx := int(signf(g_acc.x))
			g_acc.x -= dx * STEP
			_move(dx)


func _touch_up(i: int) -> void:
	if fingers.has(i):
		var a: String = fingers[i]
		fingers.erase(i)
		_pad_vis(a, false)
		_release(a)
		return
	if i != g_id:
		return
	g_id = -1
	if state != "playing":
		return
	if g_total.length() < 24.0 and g_time < 0.3:
		_do("rotate")
	elif absf(g_total.y) > absf(g_total.x) * 1.5 and g_total.y > 140.0 and g_vel.y > 1600.0:
		_do("drop")


func _step_down() -> void:
	if not _collides(cur_cells, cur_pos + Vector2i(0, -1)):
		cur_pos.y -= 1
		score += 1
		fall_t = 0.0
		_update_hud()
		_refresh()


func _update_hud() -> void:
	lbl_info.text = "SKOR  %d     REKOR  %d\nLEVEL  %d    BARIS  %d" % [score, best, level, lines] + ("\nMODE  GRAVITASI" if rule_gravity else "")


# =====================================================================
#  INPUT
# =====================================================================
func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey):
		return
	var k := e as InputEventKey
	if k.echo:
		return
	var act := ""
	match k.keycode:
		KEY_LEFT, KEY_A:
			act = "left"
		KEY_RIGHT, KEY_D:
			act = "right"
		KEY_DOWN, KEY_S:
			act = "down"
		KEY_UP, KEY_W, KEY_X:
			act = "rotate"
		KEY_SPACE:
			act = "drop"
		KEY_P, KEY_ESCAPE:
			if k.pressed:
				_toggle_pause()
			return
		KEY_M:
			if k.pressed:
				_toggle_rule()
			return
		KEY_ENTER, KEY_KP_ENTER:
			if k.pressed and (state == "menu" or state == "over"):
				_start_game()
			return
	if act == "":
		return
	if k.pressed:
		_press(act)
	else:
		_release(act)


func _press(action: String) -> void:
	if state != "playing":
		return
	if action == "left" or action == "right":
		held = action
		held_t = 0.0
		held_first = true
	_do(action)


func _release(action: String) -> void:
	if held == action:
		held = ""
	if action == "down":
		soft = false


func _do(a: String) -> void:
	if state != "playing":
		return
	match a:
		"left":
			_move(-1)
		"right":
			_move(1)
		"down":
			soft = true
		"rotate":
			_rotate()
		"drop":
			_hard_drop()


# =====================================================================
#  LOGIKA GAME
# =====================================================================
func _reset_grid() -> void:
	for row in blocks:
		for n in row:
			if n:
				n.queue_free()
	grid.clear()
	blocks.clear()
	for y in H:
		var r := []
		r.resize(W)
		r.fill(0)
		grid.append(r)
		var b := []
		b.resize(W)
		b.fill(null)
		blocks.append(b)


func _start_game() -> void:
	_reset_grid()
	for n in cur_nodes:
		n.queue_free()
	cur_nodes.clear()
	score = 0
	lines = 0
	level = 1
	soft = false
	held = ""
	bag.clear()
	next_type = _pull()
	state = "playing"
	lbl_msg.text = ""
	start_btn.visible = false
	rule_btn.visible = false
	if mode_btn:
		mode_btn.visible = false
	music.pitch_scale = 1.0
	music.play()
	_spawn()
	_update_hud()


func _game_over() -> void:
	state = "over"
	_sfx("over")
	music.stop()
	for g in ghost_nodes:
		g.visible = false
	if score > best:
		best = score
		_save_best()
	lbl_msg.text = "GAME OVER\nSkor: %d   Rekor: %d" % [score, best]
	_update_hud()
	start_btn.text = "MAIN LAGI"
	start_btn.visible = true
	rule_btn.visible = true
	if mode_btn:
		mode_btn.visible = true


func _toggle_pause() -> void:
	if state == "playing":
		state = "paused"
		music.stream_paused = true
		lbl_msg.text = "JEDA\nTekan P / ketuk II untuk lanjut"
	elif state == "paused":
		state = "playing"
		music.stream_paused = false
		lbl_msg.text = ""


func _load_best() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f:
			bests[0] = f.get_32()
			if f.get_position() + 5 <= f.get_length():
				bests[1] = f.get_32()
				rule_gravity = f.get_8() == 1
	_refresh_rule()


func _save_best() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_32(bests[0])
		f.store_32(bests[1])
		f.store_8(1 if rule_gravity else 0)


func _refresh_rule() -> void:
	if rule_btn:
		rule_btn.text = "MODE: GRAVITASI\n(lubang diisi balok di atasnya, berantai)" if rule_gravity else "MODE: KLASIK\n(baris penuh dihapus seperti biasa)"


func _toggle_rule() -> void:
	if state != "menu" and state != "over":
		return
	rule_gravity = not rule_gravity
	_save_best()
	_refresh_rule()
	_update_hud()


func _pull() -> String:
	if bag.is_empty():
		bag = KEYS.duplicate()
		bag.shuffle()
	return bag.pop_back()


func _cube(type: String) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = cube_mesh
	m.material_override = mats[type]
	add_child(m)
	return m


func _spawn() -> void:
	cur_type = next_type
	next_type = _pull()
	cur_cells = SHAPES[cur_type].duplicate()
	cur_pos = Vector2i(4, H - 1)
	if _collides(cur_cells, cur_pos):
		_game_over()
		return
	cur_nodes.clear()
	for i in 4:
		var c: Vector2i = cur_cells[i]
		var m := _cube(cur_type)
		m.position = Vector3(cur_pos.x + c.x, cur_pos.y + c.y, 0.0)
		cur_nodes.append(m)
	_refresh_next()
	_refresh()
	fall_t = 0.0


func _refresh_next() -> void:
	var cells: Array = SHAPES[next_type]
	var minx := 99
	var maxx := -99
	for c in cells:
		var v: Vector2i = c
		minx = mini(minx, v.x)
		maxx = maxi(maxx, v.x)
	var cx := (minx + maxx) / 2.0
	for i in 4:
		var c: Vector2i = cells[i]
		var n := next_nodes[i]
		n.material_override = mats[next_type]
		n.scale = Vector3.ONE * 0.75
		n.position = Vector3(4.5 + (c.x - cx) * 0.75, 23.0 + (c.y - 0.5) * 0.75, 0.0)
		n.visible = true


func _refresh() -> void:
	var gp := cur_pos
	while not _collides(cur_cells, gp + Vector2i(0, -1)):
		gp.y -= 1
	for i in 4:
		var c: Vector2i = cur_cells[i]
		ghost_nodes[i].position = Vector3(gp.x + c.x, gp.y + c.y, 0.0)
		ghost_nodes[i].visible = true


func _collides(cells: Array, pos: Vector2i) -> bool:
	for c in cells:
		var v: Vector2i = c
		var x := pos.x + v.x
		var y := pos.y + v.y
		if x < 0 or x >= W or y < 0:
			return true
		if y < H and grid[y][x] != 0:
			return true
	return false


func _move(dx: int) -> void:
	if not _collides(cur_cells, cur_pos + Vector2i(dx, 0)):
		cur_pos.x += dx
		_sfx("move", -6.0)
		_refresh()


func _rotate() -> void:
	if cur_type == "O":
		return
	var nc: Array = []
	for c in cur_cells:
		var v: Vector2i = c
		nc.append(Vector2i(v.y, -v.x))
	var kicks := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 1)]
	for k in kicks:
		var off: Vector2i = k
		if not _collides(nc, cur_pos + off):
			cur_cells = nc
			cur_pos += off
			_sfx("rotate", -4.0)
			_refresh()
			return


func _hard_drop() -> void:
	var count := 0
	while not _collides(cur_cells, cur_pos + Vector2i(0, -1)):
		cur_pos.y -= 1
		count += 1
	score += count * 2
	shake = 0.35
	_sfx("drop")
	for c in cur_cells:
		var v: Vector2i = c
		if cur_pos.y + v.y == cur_pos.y + _lowest():
			_burst(Vector3(cur_pos.x + v.x, cur_pos.y + v.y - 0.4, 0.4), COLORS[cur_type], 14, Vector3(0.4, 0.05, 0.4))
	_lock()


func _lowest() -> int:
	var m := 99
	for c in cur_cells:
		var v: Vector2i = c
		m = mini(m, v.y)
	return m


func _lock() -> void:
	soft = false
	var idx := KEYS.find(cur_type) + 1
	for i in 4:
		var c: Vector2i = cur_cells[i]
		var x := cur_pos.x + c.x
		var y := cur_pos.y + c.y
		if y >= H:
			_game_over()
			return
		grid[y][x] = idx
		var node := cur_nodes[i]
		blocks[y][x] = node
		node.position = Vector3(x, y, 0.0)
		node.scale = Vector3.ONE * 1.3
		create_tween().tween_property(node, "scale", Vector3.ONE, 0.15)
	cur_nodes.clear()
	_sfx("lock", -4.0)

	_resolve()


func _full_rows() -> Array:
	var full: Array = []
	for y in H:
		var row: Array = grid[y]
		if not row.has(0):
			full.append(y)
	return full


# Mode gravitasi: tiap kotak yang punya ruang kosong di bawahnya jatuh mengisinya
func _settle() -> bool:
	var moved := false
	for x in W:
		var wy := 0
		for y in H:
			if grid[y][x] != 0:
				if y != wy:
					grid[wy][x] = grid[y][x]
					grid[y][x] = 0
					var node = blocks[y][x]
					blocks[wy][x] = node
					blocks[y][x] = null
					create_tween().tween_property(node, "position", Vector3(x, wy, 0.0), 0.22).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
					moved = true
				wy += 1
	if moved:
		_sfx("lock", -8.0)
	return moved


func _resolve() -> void:
	var chain := 0
	while true:
		if rule_gravity and _settle():
			state = "clearing"
			for g in ghost_nodes:
				g.visible = false
			await get_tree().create_timer(0.3).timeout
		var full := _full_rows()
		if full.is_empty():
			break
		chain += 1
		if chain >= 2:
			lbl_msg.text = "KOMBO x%d" % chain
		await _clear_rows(full, chain)
		if not rule_gravity:
			break
	if chain >= 2:
		get_tree().create_timer(0.9).timeout.connect(_clear_combo_msg)
	state = "playing"
	_spawn()


func _clear_combo_msg() -> void:
	if lbl_msg.text.begins_with("KOMBO"):
		lbl_msg.text = ""


func _clear_rows(full: Array, chain: int = 1) -> void:
	state = "clearing"
	for g in ghost_nodes:
		g.visible = false
	var n := full.size()
	_sfx("tetris" if n >= 4 else "clear")
	shake = 0.3 + 0.25 * n
	var col := Color(1.0, 0.85, 0.3) if n >= 4 else Color(0.7, 0.95, 1.0)
	for y in full:
		for x in W:
			var node: MeshInstance3D = blocks[y][x]
			node.material_override = flash_mat
			var tw := create_tween()
			tw.tween_property(node, "scale", Vector3.ONE * 0.05, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		_burst(Vector3(4.5, y, 0.5), col, 70, Vector3(4.5, 0.4, 0.4))
	await get_tree().create_timer(0.3).timeout

	for y in full:
		for x in W:
			blocks[y][x].queue_free()
	var sorted := full.duplicate()
	sorted.sort()
	sorted.reverse()
	for y in sorted:
		grid.remove_at(y)
		blocks.remove_at(y)
		var r := []
		r.resize(W)
		r.fill(0)
		grid.append(r)
		var b := []
		b.resize(W)
		b.fill(null)
		blocks.append(b)
	for y in H:
		for x in W:
			var node = blocks[y][x]
			if node:
				var target := Vector3(x, y, 0.0)
				if node.position != target:
					create_tween().tween_property(node, "position", target, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	var pts: int = [0, 100, 300, 500, 800][n] * level * chain
	score += pts
	lines += n
	var new_level := lines / 10 + 1
	if new_level > level:
		level = new_level
		_sfx("level")
		music.pitch_scale = minf(1.0 + (level - 1) * 0.05, 1.5)
	_update_hud()
	if rule_gravity:
		await get_tree().create_timer(0.2).timeout


# =====================================================================
#  EFEK PARTIKEL
# =====================================================================
func _burst(pos: Vector3, col: Color, amount: int, extents: Vector3) -> void:
	var p := CPUParticles3D.new()
	var m := BoxMesh.new()
	m.size = Vector3.ONE * 0.18
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 2.0
	m.material = mat
	p.mesh = m
	p.amount = amount
	p.lifetime = 0.9
	p.one_shot = true
	p.explosiveness = 1.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = extents
	p.direction = Vector3(0, 1, 0.6)
	p.spread = 80.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 9.0
	p.gravity = Vector3(0, -14, 0)
	p.scale_amount_min = 0.4
	p.scale_amount_max = 1.4
	p.color = col
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = g
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = pos
	add_child(p)
	p.emitting = true
	get_tree().create_timer(1.5).timeout.connect(p.queue_free)


# =====================================================================
#  LOOP UTAMA
# =====================================================================
func _process(delta: float) -> void:
	t_total += delta
	if g_id != -1:
		g_time += delta
	_update_camera(delta)
	for i in bg_cubes.size():
		bg_cubes[i].rotate_y(delta * 0.2 * (1 + i % 3))
		bg_cubes[i].rotate_x(delta * 0.1)

	if state != "playing":
		return

	# tahan tombol kiri / kanan = geser berulang
	if held != "":
		held_t += delta
		var th := 0.18 if held_first else 0.06
		if held_t >= th:
			held_t = 0.0
			held_first = false
			_do(held)

	# gravitasi
	fall_t += delta
	var interval := maxf(0.06, 0.8 * pow(0.86, level - 1))
	if soft:
		interval = minf(interval, 0.04)
	if fall_t >= interval:
		fall_t = 0.0
		if not _collides(cur_cells, cur_pos + Vector2i(0, -1)):
			cur_pos.y -= 1
			if soft:
				score += 1
				_update_hud()
			_refresh()
		else:
			_lock()
			return

	# gerakan halus balok yang sedang jatuh
	for i in cur_nodes.size():
		var c: Vector2i = cur_cells[i]
		var tgt := Vector3(cur_pos.x + c.x, cur_pos.y + c.y, 0.0)
		cur_nodes[i].position = cur_nodes[i].position.lerp(tgt, 1.0 - exp(-30.0 * delta))
