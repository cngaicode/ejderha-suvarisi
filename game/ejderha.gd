## ============================================================================
##  EJDERHA SÜVARİSİ — ALP VADİSİ
##  Tek dosyalık açık dünya ejderha uçuş oyunu (Godot 4.7, Forward+)
##  Her şey bu script tarafından prosedürel olarak üretilir:
##  arazi, nehirler, göl, ormanlar, köyler, bulutlar, ejderha, sesler, arayüz.
## ============================================================================
extends Node3D

# ---------------------------------------------------------------- dünya ayarları
const WORLD := 6144.0            # harita kenarı (metre)
const N := 513                   # yükseklik ızgarası çözünürlüğü
const CELL := WORLD / float(N - 1)
const WATER_Y := 110.0           # göl seviyesi
const SNOW_Y := 1700.0           # kar sınırı
const TREE_Y := 1380.0           # orman sınırı
const CHUNKS := 8                # arazi parça sayısı (her eksende)
const CQ := 64                   # parça başına hücre
const SR := 22050                # ses örnekleme hızı
const GRAV := 11.0               # yerçekimi (oyun hissi için biraz güçlü)
const SEED := 1291

# ---------------------------------------------------------------- veri
var hmap := PackedFloat32Array()     # arazi yükseklikleri
var rwh := PackedFloat32Array()      # nehir su seviyesi (-1e9 = yok)
var rmask := PackedFloat32Array()    # nehir/kıyı yakınlığı 0..1
var fmask := PackedFloat32Array()    # orman yoğunluğu 0..1
var n_base: FastNoiseLite
var n_ridge: FastNoiseLite
var n_mask: FastNoiseLite
var n_detail: FastNoiseLite
var n_forest: FastNoiseLite
var n_warp: FastNoiseLite
var rivers: Array = []               # her nehir: {pts:PackedVector3Array, w:PackedFloat32Array}
var village_sites: Array = []        # Vector3
var waterfalls: Array = []           # Vector3
var waterfall_drop := PackedFloat32Array()
var hm_tex: ImageTexture
var map_img: Image
var rng := RandomNumberGenerator.new()

# ---------------------------------------------------------------- sahne düğümleri
var sun: DirectionalLight3D
var env: Environment
var world_env: WorldEnvironment
var sky_mat: ShaderMaterial
var cam: Camera3D
var terrain_mat: ShaderMaterial
var water_mat: ShaderMaterial
var river_mat: ShaderMaterial
var grass_mmi: MultiMeshInstance3D
var tree_mmis: Array = []
var tree_pos := PackedVector3Array()
var tree_chunk := PackedInt32Array()
var tree_idx := PackedInt32Array()
var tree_kind := PackedByteArray()
var tree_burn := PackedFloat32Array()
var tree_size := PackedFloat32Array()
var bld_grid := {}
var tree_grid := {}
var cloud_mmi: MultiMeshInstance3D
var bird_mm: MultiMesh
var birds: Array = []
var cows: Array = []
var rings: Array = []
var burning: Array = []

# ---------------------------------------------------------------- oyun durumu
var loaded := false
var paused := false
var time_of_day := 8.6
var game_time := 0.0
var sun_tick := 0.0
var rings_got := 0
var finished := false
var mode := 0           # 0 = ejderhada uçuş/yürüyüş, 1 = yaya
var settings := {"sens": 0.0023, "invert": false, "quality": 0, "music": true, "vol": 0.85, "species": 0}
const QUALITY_NAMES := ["Ultra", "Yüksek", "Orta", "Düşük"]

# ---------------------------------------------------------------- arayüz
var load_layer: CanvasLayer
var load_bar: ProgressBar
var load_label: Label
var hud: CanvasLayer
var ui := {}

# ============================================================================
func _ready() -> void:
	rng.seed = SEED
	_load_settings()
	_setup_input()
	_setup_touch()
	_build_loading_ui()
	_boot()


func _boot() -> void:
	await _step("Dağlar yükseliyor...", 0.01)
	_init_noise()
	await _gen_heights()
	await _step("Nehirler vadileri oyuyor...", 0.22)
	_gen_rivers()
	await _step("Vadiler şekilleniyor...", 0.28)
	await _carve_rivers()
	await _step("Ormanlar ve çayırlar dağıtılıyor...", 0.36)
	_gen_masks()
	_find_villages()
	_make_heightmap_texture()
	await _step("Arazi örülüyor...", 0.42)
	_make_materials()
	await _build_terrain()
	await _step("Göl ve nehirler dolduruluyor...", 0.55)
	_build_water()
	_build_rivers_mesh()
	await _step("Ağaçlar dikiliyor...", 0.6)
	await _build_trees()
	await _step("Kayalar, köyler, inekler...", 0.68)
	_build_rocks()
	_build_villages()
	_build_cows()
	_build_dancers()
	_build_grass()
	await _step("Gökyüzü ve bulutlar...", 0.72)
	_build_sky_and_light()
	_build_clouds()
	_build_birds()
	_build_rings()
	await _step("Ejderha uyanıyor...", 0.76)
	_build_dragon()
	_build_rider()
	_build_walker()
	_build_effects()
	_build_camera()
	_build_wilds()
	await _step("Sesler sentezleniyor...", 0.8)
	await _build_audio()
	await _step("Son dokunuşlar...", 0.97)
	_build_hud()
	_apply_quality()
	_spawn()
	load_layer.queue_free()
	loaded = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_msg("Ejderhana hoş geldin! %s: kontroller  •  Altın halkaları topla" % ("?" if touch_on else "F1"), 6.0)


func _step(t: String, p: float) -> void:
	load_label.text = t
	load_bar.value = p * 100.0
	await _yield()
	await _yield()


# ============================================================================
#  GİRİŞ (klavye + fare + oyun kolu) — proje ayarına gerek yok
# ============================================================================
func _setup_input() -> void:
	_act("ileri", [KEY_W, KEY_UP], [], [], [[JOY_AXIS_LEFT_Y, -1.0]])
	_act("fren", [KEY_S, KEY_DOWN], [], [], [[JOY_AXIS_LEFT_Y, 1.0]])
	_act("sol", [KEY_A, KEY_LEFT], [], [], [[JOY_AXIS_LEFT_X, -1.0]])
	_act("sag", [KEY_D, KEY_RIGHT], [], [], [[JOY_AXIS_LEFT_X, 1.0]])
	_act("yuksel", [KEY_SPACE], [], [JOY_BUTTON_A], [])
	_act("dalis", [KEY_CTRL, KEY_C], [], [JOY_BUTTON_B], [])
	_act("hiz", [KEY_SHIFT], [], [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_LEFT_STICK], [])
	_act("ates", [], [MOUSE_BUTTON_LEFT], [], [[JOY_AXIS_TRIGGER_RIGHT, 1.0]])
	_act("kukre", [KEY_R], [MOUSE_BUTTON_RIGHT], [], [[JOY_AXIS_TRIGGER_LEFT, 1.0]])
	_act("bin", [KEY_E], [], [JOY_BUTTON_X], [])
	_act("cagir", [KEY_F], [], [JOY_BUTTON_Y], [])
	_act("serbest", [KEY_ALT], [], [JOY_BUTTON_RIGHT_STICK], [])
	_act("yakin", [], [MOUSE_BUTTON_WHEEL_UP], [JOY_BUTTON_DPAD_UP], [])
	_act("uzak", [], [MOUSE_BUTTON_WHEEL_DOWN], [JOY_BUTTON_DPAD_DOWN], [])
	_act("saat", [KEY_T], [], [JOY_BUTTON_DPAD_RIGHT], [])
	_act("muzik", [KEY_M], [], [], [])
	_act("harita", [KEY_TAB], [], [JOY_BUTTON_BACK], [])
	_act("yardim", [KEY_F1], [], [], [])
	_act("menu", [KEY_ESCAPE, KEY_P], [], [JOY_BUTTON_START], [])
	_act("tamekran", [KEY_F11], [], [], [])
	_act("kalite", [KEY_F2], [], [], [])
	_act("tur1", [KEY_1], [], [], [])
	_act("tur2", [KEY_2], [], [], [])
	_act("tur3", [KEY_3], [], [], [])
	_act("tur4", [KEY_4], [], [], [])
	_act("tur_sonraki", [KEY_G], [], [JOY_BUTTON_DPAD_LEFT], [])
	_act("kam_x-", [], [], [], [[JOY_AXIS_RIGHT_X, -1.0]])
	_act("kam_x+", [], [], [], [[JOY_AXIS_RIGHT_X, 1.0]])
	_act("kam_y-", [], [], [], [[JOY_AXIS_RIGHT_Y, -1.0]])
	_act("kam_y+", [], [], [], [[JOY_AXIS_RIGHT_Y, 1.0]])


func _act(name: String, keys: Array, mbs: Array, jbs: Array, axes: Array) -> void:
	if InputMap.has_action(name):
		InputMap.erase_action(name)
	InputMap.add_action(name, 0.25)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(name, e)
	for m in mbs:
		var e := InputEventMouseButton.new()
		e.button_index = m
		InputMap.action_add_event(name, e)
	for j in jbs:
		var e := InputEventJoypadButton.new()
		e.button_index = j
		InputMap.action_add_event(name, e)
	for a in axes:
		var e := InputEventJoypadMotion.new()
		e.axis = a[0]
		e.axis_value = a[1]
		InputMap.action_add_event(name, e)


# ============================================================================
#  AYARLAR
# ============================================================================
func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load("user://ayarlar.cfg") == OK:
		for k in settings.keys():
			settings[k] = cf.get_value("ayar", k, settings[k])
	elif _mob():
		settings.quality = 1
		settings.sens = 0.0035


func _save_settings() -> void:
	var cf := ConfigFile.new()
	for k in settings.keys():
		cf.set_value("ayar", k, settings[k])
	cf.save("user://ayarlar.cfg")


# ============================================================================
#  YÜKLEME EKRANI
# ============================================================================
func _build_loading_ui() -> void:
	load_layer = CanvasLayer.new()
	load_layer.layer = 50
	add_child(load_layer)
	var bg := TextureRect.new()
	var gt := GradientTexture2D.new()
	var gr := Gradient.new()
	gr.set_color(0, Color(0.05, 0.09, 0.07))
	gr.set_color(1, Color(0.16, 0.24, 0.3))
	gt.gradient = gr
	gt.fill_from = Vector2(0, 1)
	gt.fill_to = Vector2(0, 0)
	bg.texture = gt
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	load_layer.add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(900, 300)
	box.position = Vector2(-450, -150)
	box.add_theme_constant_override("separation", 18)
	load_layer.add_child(box)
	var t := _label("EJDERHA SÜVARİSİ  v1.1", 84, Color(1.0, 0.86, 0.55))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_color_override("font_shadow_color", Color(0.6, 0.1, 0.05, 0.8))
	t.add_theme_constant_override("shadow_offset_x", 4)
	t.add_theme_constant_override("shadow_offset_y", 4)
	box.add_child(t)
	var s := _label("— ALP VADİSİ —", 30, Color(0.85, 0.92, 0.9))
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(s)
	load_bar = ProgressBar.new()
	load_bar.custom_minimum_size = Vector2(900, 22)
	load_bar.show_percentage = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 0.62, 0.2)
	sb.set_corner_radius_all(6)
	load_bar.add_theme_stylebox_override("fill", sb)
	var sb2 := StyleBoxFlat.new()
	sb2.bg_color = Color(0, 0, 0, 0.45)
	sb2.set_corner_radius_all(6)
	load_bar.add_theme_stylebox_override("background", sb2)
	box.add_child(load_bar)
	load_label = _label("", 24, Color(0.9, 0.95, 0.9))
	load_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(load_label)
	var tip := _label("İpucu: Fareyle nereye bakarsan ejderha oraya uçar. Dalış (Ctrl) ile hız kazan, W ile kanat çırp.", 20, Color(0.75, 0.82, 0.8))
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(tip)


func _label(t: String, size: int, col := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	l.add_theme_constant_override("outline_size", max(2, size / 10))
	return l

# ============================================================================
#  ARAZİ ÜRETİMİ
# ============================================================================
func _init_noise() -> void:
	n_base = _noise(SEED, 0.00045, FastNoiseLite.FRACTAL_FBM, 4)
	n_ridge = _noise(SEED + 1, 0.0005, FastNoiseLite.FRACTAL_RIDGED, 5)
	n_ridge.fractal_lacunarity = 2.0
	n_ridge.fractal_gain = 0.42
	n_mask = _noise(SEED + 2, 0.00030, FastNoiseLite.FRACTAL_FBM, 2)
	n_detail = _noise(SEED + 3, 0.0065, FastNoiseLite.FRACTAL_FBM, 3)
	n_forest = _noise(SEED + 4, 0.0024, FastNoiseLite.FRACTAL_FBM, 3)
	n_warp = _noise(SEED + 5, 0.0009, FastNoiseLite.FRACTAL_FBM, 2)


func _noise(s: int, f: float, ft: int, oct: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = s
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = f
	n.fractal_type = ft
	n.fractal_octaves = oct
	return n


const LAKE_C := Vector2(3150.0, 3900.0)

func _lake_f(x: float, z: float) -> float:
	var p := Vector2(x, z) - LAKE_C
	p = p.rotated(-0.42)
	var d := Vector2(p.x / 1250.0, p.y / 470.0).length()
	d += n_warp.get_noise_2d(x * 2.0, z * 2.0) * 0.22
	return 1.0 - smoothstep(0.55, 1.0, d)


func _lake_near(x: float, z: float) -> float:
	var p := (Vector2(x, z) - LAKE_C).rotated(-0.42)
	var d := Vector2(p.x / 1250.0, p.y / 470.0).length()
	return 1.0 - smoothstep(1.0, 2.6, d)


func _height_raw(x: float, z: float) -> float:
	var wx := x + n_warp.get_noise_2d(x, z) * 240.0
	var wz := z + n_warp.get_noise_2d(x + 5000.0, z - 3000.0) * 240.0
	var ux := x / WORLD
	var uz := z / WORLD
	var e: float = min(min(ux, 1.0 - ux), min(uz, 1.0 - uz))
	var border := 1.0 - smoothstep(0.015, 0.2, e)
	var lake := _lake_f(x, z)
	var near := _lake_near(x, z)
	var base := n_base.get_noise_2d(wx, wz) * 0.5 + 0.5
	var r: float = clamp(n_ridge.get_noise_2d(wx, wz) * 0.5 + 0.5, 0.0, 1.0)
	r = pow(r, 1.55) * 1.1
	var m := smoothstep(0.36, 0.7, n_mask.get_noise_2d(x, z) * 0.5 + 0.5)
	m = clamp(max(m * (1.0 - near * 0.85), border * 1.1), 0.0, 1.0)
	var h := 170.0 + base * 240.0 * (1.0 - near * 0.6) + m * (r * 1350.0 + base * 420.0)
	h += border * border * 420.0
	h += n_detail.get_noise_2d(x, z) * (6.0 + 30.0 * m)
	h = lerp(h, 48.0, lake)
	return h


func _gen_heights() -> void:
	hmap.resize(N * N)
	rwh.resize(N * N)
	rmask.resize(N * N)
	fmask.resize(N * N)
	rwh.fill(-1.0e9)
	rmask.fill(0.0)
	for z in N:
		var wz := z * CELL
		var row := z * N
		for x in N:
			hmap[row + x] = _height_raw(x * CELL, wz)
		if z % 24 == 0:
			load_bar.value = 1.0 + 20.0 * float(z) / N
			await _yield()


func hg(x: int, z: int) -> float:
	return hmap[clampi(z, 0, N - 1) * N + clampi(x, 0, N - 1)]


# arazinin tam yüksekliği (mesh üçgenleriyle birebir)
func h_at(x: float, z: float) -> float:
	var fx: float = clamp(x / CELL, 0.0, N - 1.0001)
	var fz: float = clamp(z / CELL, 0.0, N - 1.0001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var i := iz * N + ix
	var a := hmap[i]
	var b := hmap[i + 1]
	var c := hmap[i + N]
	var d := hmap[i + N + 1]
	if tx > tz:
		return a + (b - a) * tx + (d - b) * tz
	return a + (d - c) * tx + (c - a) * tz


func n_at(x: float, z: float) -> Vector3:
	var e := 3.0
	return Vector3(h_at(x - e, z) - h_at(x + e, z), 2.0 * e, h_at(x, z - e) - h_at(x, z + e)).normalized()


# su yüzeyi (göl ya da nehir)
func water_at(x: float, z: float) -> float:
	var ix := clampi(int(round(x / CELL)), 0, N - 1)
	var iz := clampi(int(round(z / CELL)), 0, N - 1)
	var r := rwh[iz * N + ix]
	return max(WATER_Y, r)


func _grid_n(x: int, z: int) -> Vector3:
	return Vector3(hg(x - 1, z) - hg(x + 1, z), 2.0 * CELL, hg(x, z - 1) - hg(x, z + 1)).normalized()


# ---------------------------------------------------------------- nehirler
func _gen_rivers() -> void:
	var sources: Array = []
	var tries := 0
	while sources.size() < 7 and tries < 4000:
		tries += 1
		var p := Vector2(rng.randf_range(0.1, 0.9), rng.randf_range(0.08, 0.9)) * WORLD
		var h := h_at(p.x, p.y)
		if h < 800.0 or h > 1500.0:
			continue
		if p.distance_to(LAKE_C) < 1500.0:
			continue
		var ok := true
		for s in sources:
			if p.distance_to(s) < 1100.0:
				ok = false
				break
		if ok:
			sources.append(p)
	for s: Vector2 in sources:
		var pts: Array = [s]
		var dir := (LAKE_C - s).normalized()
		var join := -1
		var join_i := -1
		for step in 260:
			var p: Vector2 = pts[-1]
			var best := Vector2.ZERO
			var best_s := INF
			var best_d := dir
			for k in 9:
				var ang := (k - 4) * 0.2
				var nd := dir.rotated(ang)
				var c := p + nd * 45.0
				var prog := p.distance_to(LAKE_C) - c.distance_to(LAKE_C)
				var sc := h_at(c.x, c.y) - prog * 2.2 + absf(ang) * 9.0 + n_warp.get_noise_2d(c.x * 3.0, c.y * 3.0) * 14.0
				if sc < best_s:
					best_s = sc
					best = c
					best_d = nd
			dir = (dir * 0.55 + best_d * 0.45).normalized()
			pts.append(best)
			if _lake_f(best.x, best.y) > 0.6:
				break
			# başka nehre katıl
			var found := false
			for ri in rivers.size():
				var rp: PackedVector3Array = rivers[ri].pts
				for j in range(0, rp.size(), 2):
					if Vector2(rp[j].x, rp[j].z).distance_to(best) < 55.0:
						pts.append(Vector2(rp[j].x, rp[j].z))
						join = ri
						join_i = j
						found = true
						break
				if found:
					break
			if found:
				break
		if pts.size() < 12:
			continue
		# yumuşat (Chaikin) ve yeniden örnekle
		for it in 3:
			var np: Array = [pts[0]]
			for i in pts.size() - 1:
				var a: Vector2 = pts[i]
				var b: Vector2 = pts[i + 1]
				np.append(a.lerp(b, 0.25))
				np.append(a.lerp(b, 0.75))
			np.append(pts[-1])
			pts = np
		var rs: Array = [pts[0]]
		var acc := 0.0
		for i in range(1, pts.size()):
			acc += (pts[i] as Vector2).distance_to(pts[i - 1])
			if acc >= 30.0:
				rs.append(pts[i])
				acc = 0.0
		rs.append(pts[-1])
		# su seviyesi (hep aşağı akar)
		var out := PackedVector3Array()
		var ws := PackedFloat32Array()
		var floor_h := WATER_Y - 0.4
		if join >= 0:
			floor_h = max(floor_h, rivers[join].pts[join_i].y)
		var wh := h_at(rs[0].x, rs[0].y) - 3.0
		var total := rs.size()
		for i in total:
			var q: Vector2 = rs[i]
			var t := float(i) / float(total - 1)
			wh = min(wh - 0.12, h_at(q.x, q.y) - 2.5)
			var w := 6.0 + 18.0 * pow(t, 1.3)
			if join >= 0:
				w = 5.0 + 11.0 * pow(t, 1.3)
			out.append(Vector3(q.x, max(wh, floor_h), q.y))
			ws.append(w)
		rivers.append({"pts": out, "w": ws})


func _carve_rivers() -> void:
	var carve := PackedFloat32Array()
	carve.resize(N * N)
	carve.fill(1.0e9)
	var bestd := PackedFloat32Array()
	bestd.resize(N * N)
	bestd.fill(1.0e9)
	var R := 330.0
	var cnt := 0
	for rv in rivers:
		var pts: PackedVector3Array = rv.pts
		var ws: PackedFloat32Array = rv.w
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var a2 := Vector2(a.x, a.z)
			var b2 := Vector2(b.x, b.z)
			var ab := b2 - a2
			var l2: float = max(ab.length_squared(), 0.001)
			if a.y - b.y > 16.0:
				waterfalls.append((a + b) * 0.5)
				waterfall_drop.append(a.y - b.y)
			var x0 := clampi(int((min(a.x, b.x) - R) / CELL), 0, N - 1)
			var x1 := clampi(int((max(a.x, b.x) + R) / CELL) + 1, 0, N - 1)
			var z0 := clampi(int((min(a.z, b.z) - R) / CELL), 0, N - 1)
			var z1 := clampi(int((max(a.z, b.z) + R) / CELL) + 1, 0, N - 1)
			for z in range(z0, z1 + 1):
				var row := z * N
				var pz := z * CELL
				for x in range(x0, x1 + 1):
					var p := Vector2(x * CELL, pz)
					var t: float = clamp((p - a2).dot(ab) / l2, 0.0, 1.0)
					var d := p.distance_to(a2 + ab * t)
					if d > R:
						continue
					var wh: float = lerp(a.y, b.y, t)
					var w: float = lerp(ws[i], ws[i + 1], t)
					var hb: float
					if d < w:
						var q := d / w
						hb = wh - 0.7 - (3.0 + w * 0.15) * (1.0 - q * q)
					else:
						var dd := d - w
						hb = wh - 0.7 + dd * 0.2 + pow(dd / R, 2.0) * 1500.0
					var k := row + x
					if hb < carve[k]:
						carve[k] = hb
					if d < bestd[k]:
						bestd[k] = d
						if d < w + 6.0:
							rwh[k] = wh
						rmask[k] = max(rmask[k], 1.0 - smoothstep(w * 0.8, w + 26.0, d))
			cnt += 1
			if cnt % 60 == 0:
				load_bar.value = 28.0 + 7.0 * float(cnt) / 600.0
				await _yield()
	for k in N * N:
		if carve[k] < hmap[k]:
			hmap[k] = carve[k]


# ---------------------------------------------------------------- maskeler
func _gen_masks() -> void:
	for z in N:
		for x in N:
			var k := z * N + x
			var h := hmap[k]
			var nrm := _grid_n(x, z)
			var slope := 1.0 - nrm.y
			var wx := x * CELL
			var wz := z * CELL
			var nf := n_forest.get_noise_2d(wx, wz)
			var tl := TREE_Y + n_detail.get_noise_2d(wx * 0.3, wz * 0.3) * 160.0
			var f := smoothstep(-0.22, 0.12, nf)
			f *= 0.45 + 0.55 * smoothstep(0.04, 0.16, slope)
			f *= 1.0 - smoothstep(0.5, 0.68, slope)
			f *= 1.0 - smoothstep(tl - 120.0, tl, h)
			f *= smoothstep(WATER_Y + 4.0, WATER_Y + 22.0, h)
			f *= 1.0 - smoothstep(0.05, 0.45, rmask[k])
			fmask[k] = clamp(f, 0.0, 1.0)
			if h < WATER_Y + 3.0:
				rmask[k] = max(rmask[k], 1.0 - smoothstep(WATER_Y - 1.0, WATER_Y + 3.0, h))


func _find_villages() -> void:
	var cands: Array = []
	var step := 8
	for z in range(int(N * 0.1), int(N * 0.9), step):
		for x in range(int(N * 0.1), int(N * 0.9), step):
			var h := hg(x, z)
			if h < WATER_Y + 10.0 or h > 460.0:
				continue
			var flat := true
			for o in [Vector2i(-6, 0), Vector2i(6, 0), Vector2i(0, -6), Vector2i(0, 6), Vector2i(0, 0)]:
				if _grid_n(x + o.x, z + o.y).y < 0.965 or rmask[(z + o.y) * N + x + o.x] > 0.05:
					flat = false
					break
			if not flat:
				continue
			var p := Vector3(x * CELL, h, z * CELL)
			var score := Vector2(p.x, p.z).distance_to(LAKE_C) * 0.0012 + rng.randf() * 0.8
			cands.append([score, p])
	cands.sort_custom(func(a, b): return a[0] < b[0])
	for c in cands:
		var p: Vector3 = c[1]
		var ok := true
		for v in village_sites:
			if Vector2(p.x, p.z).distance_to(Vector2(v.x, v.z)) < 950.0:
				ok = false
				break
		if ok:
			village_sites.append(p)
		if village_sites.size() >= 5:
			break
	# köy alanlarını düzleştir, ağaçları temizle
	for v in village_sites:
		var r := 190.0
		var cx := int(v.x / CELL)
		var cz := int(v.z / CELL)
		var rc := int(r / CELL) + 1
		for z in range(cz - rc, cz + rc + 1):
			for x in range(cx - rc, cx + rc + 1):
				if x < 0 or z < 0 or x >= N or z >= N:
					continue
				var d := Vector2(x * CELL - v.x, z * CELL - v.z).length()
				var f := 1.0 - smoothstep(r * 0.45, r, d)
				var k := z * N + x
				hmap[k] = lerp(hmap[k], v.y, f * 0.75)
				fmask[k] *= 1.0 - f


func _make_heightmap_texture() -> void:
	var data := PackedFloat32Array()
	data.resize(N * N * 4)
	for k in N * N:
		data[k * 4] = hmap[k]
		data[k * 4 + 1] = rmask[k]
		data[k * 4 + 2] = fmask[k]
		data[k * 4 + 3] = 1.0
	var img := Image.create_from_data(N, N, false, Image.FORMAT_RGBAF, data.to_byte_array())
	hm_tex = ImageTexture.create_from_image(img)


# ---------------------------------------------------------------- arazi mesh'i
func _grid_indices(n: int) -> PackedInt32Array:
	var idx := PackedInt32Array()
	for z in n - 1:
		for x in n - 1:
			var a := z * n + x
			var b := a + 1
			var c := a + n
			var d := c + 1
			idx.append_array([a, b, d, a, d, c])
	# etek (çatlakları gizler)
	var ring := _ring(n)
	var L := ring.size()
	var base := n * n
	for k in L:
		var a := ring[k]
		var b := ring[(k + 1) % L]
		var a2 := base + k
		var b2 := base + (k + 1) % L
		idx.append_array([a, b, b2, a, b2, a2, a, b2, b, a, a2, b2])
	return idx


func _ring(n: int) -> PackedInt32Array:
	var r := PackedInt32Array()
	for x in n:
		r.append(x)
	for z in range(1, n):
		r.append(z * n + n - 1)
	for x in range(n - 2, -1, -1):
		r.append((n - 1) * n + x)
	for z in range(n - 2, 0, -1):
		r.append(z * n)
	return r


func _build_terrain() -> void:
	var root := Node3D.new()
	root.name = "Arazi"
	add_child(root)
	var nrm_grid := PackedVector3Array()
	nrm_grid.resize(N * N)
	for z in N:
		for x in N:
			nrm_grid[z * N + x] = _grid_n(x, z)
	var idx_hi := _grid_indices(CQ + 1)
	var idx_lo := _grid_indices(CQ / 4 + 1)
	for cz in CHUNKS:
		for cx in CHUNKS:
			for lod in 2:
				var step := 1 if lod == 0 else 4
				var n := CQ / step + 1
				var v := PackedVector3Array()
				var nm := PackedVector3Array()
				var col := PackedColorArray()
				v.resize(n * n)
				nm.resize(n * n)
				col.resize(n * n)
				for z in n:
					for x in n:
						var gx := cx * CQ + x * step
						var gz := cz * CQ + z * step
						var k := gz * N + gx
						var i := z * n + x
						v[i] = Vector3(gx * CELL, hmap[k], gz * CELL)
						nm[i] = nrm_grid[k]
						col[i] = Color(rmask[k], fmask[k], 0.0, 1.0)
				for k in _ring(n):
					v.append(v[k] - Vector3(0, 30.0, 0))
					nm.append(nm[k])
					col.append(col[k])
				var arr := []
				arr.resize(Mesh.ARRAY_MAX)
				arr[Mesh.ARRAY_VERTEX] = v
				arr[Mesh.ARRAY_NORMAL] = nm
				arr[Mesh.ARRAY_COLOR] = col
				arr[Mesh.ARRAY_INDEX] = idx_hi if lod == 0 else idx_lo
				var mesh := ArrayMesh.new()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
				mesh.surface_set_material(0, terrain_mat)
				var mi := MeshInstance3D.new()
				mi.mesh = mesh
				if lod == 0:
					mi.visibility_range_end = 2400.0
					mi.visibility_range_end_margin = 150.0
				else:
					mi.visibility_range_begin = 2400.0
					mi.visibility_range_begin_margin = 150.0
				root.add_child(mi)
		load_bar.value = 42.0 + 12.0 * float(cz + 1) / CHUNKS
		await _yield()

# ============================================================================
#  MALZEMELER (shader'lar)
# ============================================================================
func _ntex(seed_: int, freq: float, normal := false, size := 512, oct := 5, bump := 8.0) -> NoiseTexture2D:
	var t := NoiseTexture2D.new()
	t.width = size
	t.height = size
	t.seamless = true
	t.generate_mipmaps = true
	var n := FastNoiseLite.new()
	n.seed = seed_
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_octaves = oct
	t.noise = n
	if normal:
		t.as_normal_map = true
		t.bump_strength = bump
	return t


const TERRAIN_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform sampler2D nz : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nzn : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float water_y = 110.0;
uniform float snow_y = 1700.0;
uniform float tree_y = 1380.0;
uniform float snow_extra = 0.0;
varying vec3 wp;
varying vec3 wn;
varying vec4 vc;
void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vc = COLOR;
}
vec3 tri(vec3 p, vec3 w) {
	return texture(nz, p.zy).rgb * w.x + texture(nz, p.xz).rgb * w.y + texture(nz, p.xy).rgb * w.z;
}
vec3 trin(vec3 p, vec3 n, vec3 w) {
	vec3 tx = texture(nzn, p.zy).xyz * 2.0 - 1.0;
	vec3 ty = texture(nzn, p.xz).xyz * 2.0 - 1.0;
	vec3 tz = texture(nzn, p.xy).xyz * 2.0 - 1.0;
	tx = vec3(tx.xy + n.zy, abs(tx.z) * n.x);
	ty = vec3(ty.xy + n.xz, abs(ty.z) * n.y);
	tz = vec3(tz.xy + n.xy, abs(tz.z) * n.z);
	return normalize(tx.zyx * w.x + ty.xzy * w.y + tz.xyz * w.z);
}
void fragment() {
	vec3 n = normalize(wn);
	float slope = 1.0 - n.y;
	float n1 = texture(nz, wp.xz * 0.0011).r;
	float n2 = texture(nz, wp.xz * 0.009).r;
	float n3 = texture(nz, wp.xz * 0.061).r;
	vec3 bw = pow(abs(n), vec3(4.0));
	bw /= (bw.x + bw.y + bw.z);
	float rk = tri(wp * 0.031, bw).r;
	float rk2 = tri(wp * 0.13, bw).r;
	float dist = length(VERTEX);

	vec3 g1 = vec3(0.105, 0.27, 0.04);
	vec3 g2 = vec3(0.27, 0.43, 0.075);
	vec3 g3 = vec3(0.34, 0.40, 0.16);
	vec3 grass = mix(g1, g2, smoothstep(0.25, 0.78, n1));
	grass = mix(grass, g3, smoothstep(tree_y - 250.0, tree_y + 320.0, wp.y + (n2 - 0.5) * 240.0));
	grass *= 0.8 + 0.38 * n3;
	vec3 forest = vec3(0.05, 0.11, 0.035) * (0.75 + 0.5 * n2);
	vec3 col = mix(grass, forest, smoothstep(0.12, 0.65, vc.g));

	vec3 pebble = mix(vec3(0.42, 0.40, 0.35), vec3(0.62, 0.60, 0.55), n3);
	float wet = smoothstep(0.3, 0.85, vc.r + (n2 - 0.5) * 0.3);
	col = mix(col, pebble, wet);

	vec3 rock = mix(vec3(0.20, 0.19, 0.18), vec3(0.40, 0.38, 0.35), rk);
	float strata = 0.5 + 0.5 * sin(wp.y * 0.12 + rk * 9.0 + n2 * 6.0);
	rock *= 0.85 + 0.2 * strata * rk2;
	rock = mix(rock, rock * vec3(1.1, 0.95, 0.8), smoothstep(0.45, 0.8, n1) * 0.8);
	float streak = texture(nz, vec2((wp.x + wp.z) * 0.013, wp.y * 0.0016)).r;
	rock *= 0.72 + 0.5 * streak;
	rock *= 0.8 + 0.25 * smoothstep(0.2, 0.5, slope);
	float rock_a = smoothstep(0.40, 0.58, slope + (rk - 0.5) * 0.26);
	rock_a = max(rock_a, smoothstep(snow_y - 300.0, snow_y + 150.0, wp.y) * smoothstep(0.2, 0.35, slope));
	col = mix(col, rock, rock_a);

	float sn = smoothstep(snow_y - 140.0 - snow_extra, snow_y + 110.0 - snow_extra, wp.y + (n1 - 0.5) * 420.0 + (n2 - 0.5) * 90.0);
	sn *= 1.0 - smoothstep(0.44, 0.64, slope + (rk2 - 0.5) * 0.16);
	col = mix(col, vec3(0.92, 0.94, 0.99), sn);
	col *= mix(1.0, 0.5, 1.0 - smoothstep(water_y - 7.0, water_y + 0.5, wp.y));

	ALBEDO = col;
	ROUGHNESS = mix(mix(0.96, 0.84, rock_a), 0.5, sn);
	SPECULAR = mix(0.3, 0.5, sn);
	vec3 pn = trin(wp * mix(0.08, 0.035, rock_a), n, bw);
	pn = normalize(mix(n, pn, mix(0.55, 0.9, rock_a) * (1.0 - sn * 0.6)));
	NORMAL = normalize((VIEW_MATRIX * vec4(pn, 0.0)).xyz);
}
"""


const WATER_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_burley, specular_schlick_ggx;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D wn1 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D wn2 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D foam_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 shallow : source_color = vec3(0.10, 0.50, 0.52);
uniform vec3 deep : source_color = vec3(0.02, 0.17, 0.25);
uniform float river = 0.0;
uniform int ssr_steps = 40;
uniform float lit = 1.0;
varying vec3 wp;
varying vec3 wnrm;
void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
vec3 vpos(vec2 suv, mat4 ip) {
	float d = texture(DEPTH_TEXTURE, suv).r;
	vec4 v = ip * vec4(suv * 2.0 - 1.0, d, 1.0);
	return v.xyz / v.w;
}
void fragment() {
	vec2 uv1;
	vec2 uv2;
	float steep = clamp(1.0 - wnrm.y, 0.0, 1.0);
	if (river > 0.5) {
		float sp = 1.0 + steep * 6.0;
		uv1 = vec2(UV.x * 0.45, UV.y * 0.09 - TIME * 0.5 * sp);
		uv2 = vec2(UV.x * 0.3 + 0.37, UV.y * 0.05 - TIME * 0.32 * sp);
	} else {
		uv1 = wp.xz * 0.011 + TIME * vec2(0.006, 0.004);
		uv2 = wp.xz * 0.029 - TIME * vec2(0.004, 0.0085);
	}
	vec3 a = texture(wn1, uv1).xyz * 2.0 - 1.0;
	vec3 b = texture(wn2, uv2).xyz * 2.0 - 1.0;
	vec2 nxy = (a.xy + b.xy) * mix(0.28, 0.55, river);
	vec3 wN = normalize(wnrm + vec3(nxy.x, 0.0, nxy.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(wN, 0.0)).xyz);
	vec3 bg = vpos(SCREEN_UV, INV_PROJECTION_MATRIX);
	float depth = max(0.0, VERTEX.z - bg.z);
	vec2 ruv = SCREEN_UV + nxy * 0.035 * clamp(depth * 0.25, 0.0, 1.0);
	if (vpos(ruv, INV_PROJECTION_MATRIX).z > VERTEX.z) ruv = SCREEN_UV;
	vec3 refr = texture(SCREEN_TEXTURE, ruv).rgb;
	float ab = 1.0 - exp(-depth * 0.085);
	vec3 wcol = mix(shallow, deep, clamp(ab * 1.25, 0.0, 1.0)) * lit;
	vec3 under = mix(refr * mix(vec3(1.0), shallow * 2.2, clamp(depth * 0.15, 0.0, 1.0)), wcol, ab);
	float fres = 0.02 + 0.98 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	// ekran uzayı yansıma (dağlar göle yansısın)
	vec3 R = normalize(reflect(-VIEW, NORMAL));
	vec3 hitc = vec3(0.0);
	float hit = 0.0;
	if (R.y > -0.2 && ssr_steps > 0) {
		vec3 p = VERTEX;
		float st = 1.5 + length(VERTEX) * 0.02;
		for (int i = 0; i < ssr_steps; i++) {
			p += R * st;
			st *= 1.13;
			vec4 c = PROJECTION_MATRIX * vec4(p, 1.0);
			vec2 suv = c.xy / c.w * 0.5 + 0.5;
			if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0 || p.z > -0.5) break;
			float sz = vpos(suv, INV_PROJECTION_MATRIX).z;
			if (sz > p.z && sz - p.z < st * 2.5) {
				vec2 ed = smoothstep(0.0, 0.12, suv) * (1.0 - smoothstep(0.88, 1.0, suv));
				hit = ed.x * ed.y;
				hitc = texture(SCREEN_TEXTURE, suv).rgb;
				break;
			}
		}
	}
	float foam = (1.0 - smoothstep(0.0, 1.5, depth)) * smoothstep(0.35, 0.7, texture(foam_tex, wp.xz * 0.14 + TIME * 0.015).r);
	foam = max(foam, smoothstep(0.12, 0.45, steep) * (0.55 + 0.45 * texture(foam_tex, vec2(UV.x * 0.5, UV.y * 0.08 - TIME * 1.6)).r));
	foam = max(foam, river * smoothstep(0.7, 0.9, texture(foam_tex, uv1 * 2.0).r) * 0.3 * (1.0 + steep * 3.0));
	ALBEDO = vec3(0.92) * foam;
	EMISSION = (under * (1.0 - fres) + hitc * fres * hit * 0.9) * (1.0 - foam);
	SPECULAR = mix(0.5, 0.05, hit);
	ROUGHNESS = mix(0.02, 0.55, foam);
	ALPHA = 1.0;
}
"""


const TREE_SHADER := """
shader_type spatial;
render_mode diffuse_burley;
uniform float wind = 1.0;
varying float hy;
void vertex() {
	vec3 o = MODEL_MATRIX[3].xyz;
	float ph = o.x * 0.05 + o.z * 0.07;
	float s = (sin(TIME * 1.3 + ph) * 0.6 + sin(TIME * 2.9 + ph * 1.7) * 0.25) * wind * 0.03 * VERTEX.y * VERTEX.y;
	VERTEX.x += s;
	VERTEX.z += s * 0.6;
	hy = VERTEX.y;
}
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.92;
	SPECULAR = 0.25;
	BACKLIGHT = COLOR.rgb * 0.35;
}
"""


func _make_materials() -> void:
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = _shader(TERRAIN_SHADER)
	terrain_mat.set_shader_parameter("nz", _ntex(11, 0.012))
	terrain_mat.set_shader_parameter("nzn", _ntex(12, 0.02, true, 512, 5, 10.0))
	terrain_mat.set_shader_parameter("water_y", WATER_Y)
	terrain_mat.set_shader_parameter("snow_y", SNOW_Y)
	terrain_mat.set_shader_parameter("tree_y", TREE_Y)
	water_mat = ShaderMaterial.new()
	water_mat.shader = _shader(WATER_SHADER)
	water_mat.set_shader_parameter("wn1", _ntex(21, 0.018, true, 512, 4, 4.0))
	water_mat.set_shader_parameter("wn2", _ntex(22, 0.035, true, 512, 3, 3.0))
	water_mat.set_shader_parameter("foam_tex", _ntex(23, 0.05, false, 256, 3))
	water_mat.render_priority = 1
	river_mat = water_mat.duplicate()
	river_mat.set_shader_parameter("river", 1.0)
	river_mat.set_shader_parameter("shallow", Color(0.25, 0.66, 0.62))
	river_mat.set_shader_parameter("deep", Color(0.06, 0.36, 0.38))
	river_mat.render_priority = 0


func _shader(code: String) -> Shader:
	var s := Shader.new()
	s.code = code
	return s


# ============================================================================
#  SU
# ============================================================================
func _build_water() -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(WORLD * 1.2, WORLD * 1.2)
	pm.subdivide_width = 24
	pm.subdivide_depth = 24
	var mi := MeshInstance3D.new()
	mi.name = "Gol"
	mi.mesh = pm
	mi.material_override = water_mat
	mi.position = Vector3(WORLD * 0.5, WATER_Y, WORLD * 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _build_rivers_mesh() -> void:
	for rv in rivers:
		var pts: PackedVector3Array = rv.pts
		var ws: PackedFloat32Array = rv.w
		var v := PackedVector3Array()
		var nm := PackedVector3Array()
		var uv := PackedVector2Array()
		var idx := PackedInt32Array()
		var dist := 0.0
		var cnt := 0
		for i in pts.size():
			var p := pts[i]
			if i > 0:
				dist += Vector2(p.x, p.z).distance_to(Vector2(pts[i - 1].x, pts[i - 1].z))
			var a := pts[max(i - 1, 0)]
			var b := pts[min(i + 1, pts.size() - 1)]
			var f := b - a
			var f2 := Vector2(f.x, f.z).normalized()
			var side := Vector3(-f2.y, 0, f2.x)
			var w := ws[i] + 3.5
			var up := f.normalized().cross(side)
			if up.y < 0.0:
				up = -up
			v.append(p + side * w + Vector3(0, 0.05, 0))
			v.append(p - side * w + Vector3(0, 0.05, 0))
			nm.append(up)
			nm.append(up)
			uv.append(Vector2(0, dist / 25.0))
			uv.append(Vector2(1, dist / 25.0))
			if cnt > 0:
				var k := cnt * 2
				idx.append_array([k - 2, k - 1, k + 1, k - 2, k + 1, k])
			cnt += 1
			if p.y < WATER_Y + 0.05:
				break
		if cnt < 2:
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = nm
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = river_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)


# ============================================================================
#  MESH OLUŞTURUCU (prosedürel modeller için)
# ============================================================================
var mb_v := PackedVector3Array()
var mb_n := PackedVector3Array()
var mb_c := PackedColorArray()
var mb_uv := PackedVector2Array()

func _mb_begin() -> void:
	mb_v = PackedVector3Array()
	mb_n = PackedVector3Array()
	mb_c = PackedColorArray()
	mb_uv = PackedVector2Array()


func _mb_mesh(mat: Material = null) -> ArrayMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = mb_v
	arr[Mesh.ARRAY_NORMAL] = mb_n
	arr[Mesh.ARRAY_COLOR] = mb_c
	if mb_uv.size() == mb_v.size():
		arr[Mesh.ARRAY_TEX_UV] = mb_uv
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if mat:
		m.surface_set_material(0, mat)
	return m


# Üçgen ekle; sarma yönü istenen normale göre otomatik düzeltilir.
func _mb_tri(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3, col: Color, ca := Color(), cb := Color(), cc := Color()) -> void:
	if ca == Color():
		ca = col
		cb = col
		cc = col
	var face := (c - a).cross(b - a)
	if face.dot(na + nb + nc) < 0.0:
		mb_v.append_array([a, c, b])
		mb_n.append_array([na, nc, nb])
		mb_c.append_array([ca, cc, cb])
	else:
		mb_v.append_array([a, b, c])
		mb_n.append_array([na, nb, nc])
		mb_c.append_array([ca, cb, cc])


func _mb_flat(a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
	_mb_tri(a, b, c, n, n, n, col)


func _mb_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color) -> void:
	_mb_flat(a, b, c, n, col)
	_mb_flat(a, c, d, n, col)


func _mb_box(xf: Transform3D, size: Vector3, col: Color, top := Color(), skip_bottom := true) -> void:
	if top == Color():
		top = col
	var h := size * 0.5
	var faces := [
		[Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
		[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
		[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
		[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
	]
	for f in faces:
		var n: Vector3 = f[0]
		if skip_bottom and n.y < -0.5:
			continue
		var u: Vector3 = f[1]
		var w: Vector3 = f[2]
		var c := n * h
		var uu := u * h
		var ww := w * h
		var p0 := xf * (c - uu - ww)
		var p1 := xf * (c + uu - ww)
		var p2 := xf * (c + uu + ww)
		var p3 := xf * (c - uu + ww)
		var nw := (xf.basis * n).normalized()
		_mb_quad(p0, p1, p2, p3, nw, top if n.y > 0.5 else col)


# koni / silindir (r0 alt, r1 üst)
func _mb_cyl(xf: Transform3D, r0: float, r1: float, hgt: float, sides: int, col0: Color, col1: Color, cap := false, droop := 0.0) -> void:
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var slope_n := (r0 - r1) / maxf(hgt, 0.001)
		var n0 := (xf.basis * (d0 + Vector3(0, slope_n, 0))).normalized()
		var n1 := (xf.basis * (d1 + Vector3(0, slope_n, 0))).normalized()
		var b0 := xf * (d0 * r0 - Vector3(0, droop, 0))
		var b1 := xf * (d1 * r0 - Vector3(0, droop, 0))
		var t0 := xf * (d0 * r1 + Vector3(0, hgt, 0))
		var t1 := xf * (d1 * r1 + Vector3(0, hgt, 0))
		if r1 < 0.0001:
			var nt := (xf.basis * ((d0 + d1) * 0.5 + Vector3(0, slope_n, 0))).normalized()
			_mb_tri(b0, b1, t0, n0, n1, nt, col0, col0, col0, col1)
		else:
			_mb_tri(b0, b1, t1, n0, n1, n1, col0, col0, col0, col1)
			_mb_tri(b0, t1, t0, n0, n1, n0, col0, col0, col1, col1)
		if cap:
			var cb := xf * Vector3(0, -droop * 0.3, 0)
			var dn := (xf.basis * Vector3.DOWN).normalized()
			_mb_tri(cb, b1, b0, dn, dn, dn, col0.darkened(0.35))


# yamuk elipsoid (yumuşak normal)
func _mb_ellipsoid(xf: Transform3D, r: Vector3, rings: int, segs: int, col: Color, col_bottom := Color(), noise_amt := 0.0, nseed := 0) -> void:
	if col_bottom == Color():
		col_bottom = col
	var pts := []
	var nrs := []
	var cls := []
	for i in rings + 1:
		var th := PI * i / rings
		var rowp := []
		var rown := []
		var rowc := []
		for j in segs + 1:
			var ph := TAU * j / segs
			var u := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
			var k := 1.0
			if noise_amt > 0.0:
				k += n_detail.get_noise_3d(u.x * 90.0 + nseed * 13.0, u.y * 90.0, u.z * 90.0) * noise_amt
			var p := u * r * k
			rowp.append(xf * p)
			rown.append((xf.basis * Vector3(u.x / r.x, u.y / r.y, u.z / r.z)).normalized())
			rowc.append(col_bottom.lerp(col, clamp(u.y * 0.5 + 0.5, 0.0, 1.0)))
		pts.append(rowp)
		nrs.append(rown)
		cls.append(rowc)
	for i in rings:
		for j in segs:
			var a: Vector3 = pts[i][j]
			var b: Vector3 = pts[i][j + 1]
			var c: Vector3 = pts[i + 1][j + 1]
			var d: Vector3 = pts[i + 1][j]
			if i > 0:
				_mb_tri(a, b, c, nrs[i][j], nrs[i][j + 1], nrs[i + 1][j + 1], col, cls[i][j], cls[i][j + 1], cls[i + 1][j + 1])
			if i < rings - 1:
				_mb_tri(a, c, d, nrs[i][j], nrs[i + 1][j + 1], nrs[i + 1][j], col, cls[i][j], cls[i + 1][j + 1], cls[i + 1][j])


func _xf(pos: Vector3, rot := Vector3.ZERO, sc := Vector3.ONE) -> Transform3D:
	var b := Basis.from_euler(rot).scaled(sc)
	return Transform3D(b, pos)


# ============================================================================
#  AĞAÇLAR
# ============================================================================
func _spruce_mesh(tiers: int, sides: int) -> ArrayMesh:
	_mb_begin()
	var bark := Color(0.23, 0.15, 0.09)
	_mb_cyl(Transform3D.IDENTITY, 0.028, 0.012, 0.3, 5, bark, bark)
	for t in tiers:
		var f := float(t) / float(tiers)
		var y0 := 0.1 + f * 0.78
		var r := 0.3 * (1.0 - f * 0.85) + 0.02
		var hgt := 0.32 - f * 0.12
		var inner := Color(0.04, 0.11, 0.05)
		var outer := Color(0.10, 0.25, 0.10).lerp(Color(0.16, 0.33, 0.13), f)
		_mb_cyl(_xf(Vector3(0, y0, 0), Vector3(0, t * 0.7, 0)), r, 0.0, hgt, sides, inner.lerp(outer, 0.55), outer, true, r * 0.25)
	return _mb_mesh()


func _broadleaf_mesh(detail: int) -> ArrayMesh:
	_mb_begin()
	var bark := Color(0.30, 0.24, 0.18)
	_mb_cyl(Transform3D.IDENTITY, 0.045, 0.02, 0.55, 5, bark, bark)
	var leaf_hi := Color(0.30, 0.50, 0.12)
	var leaf_lo := Color(0.08, 0.20, 0.05)
	if detail > 0:
		_mb_ellipsoid(_xf(Vector3(0, 0.62, 0)), Vector3(0.34, 0.3, 0.34), 5, 8, leaf_hi, leaf_lo, 0.18, 1)
		_mb_ellipsoid(_xf(Vector3(0.12, 0.82, 0.06)), Vector3(0.24, 0.2, 0.24), 4, 7, leaf_hi.lightened(0.08), leaf_lo, 0.2, 2)
		_mb_ellipsoid(_xf(Vector3(-0.14, 0.75, -0.08)), Vector3(0.22, 0.2, 0.22), 4, 7, leaf_hi, leaf_lo, 0.2, 3)
	else:
		_mb_ellipsoid(_xf(Vector3(0, 0.68, 0)), Vector3(0.38, 0.36, 0.38), 3, 6, leaf_hi, leaf_lo)
	return _mb_mesh()


func _build_trees() -> void:
	var tm := ShaderMaterial.new()
	tm.shader = _shader(TREE_SHADER)
	var meshes_near := [_spruce_mesh(6, 8), _broadleaf_mesh(1)]
	var meshes_far := [_spruce_mesh(2, 5), _broadleaf_mesh(0)]
	for m in meshes_near + meshes_far:
		m.surface_set_material(0, tm)
	var per_chunk := []   # [kind] -> Array of [Transform3D, Color, tree_id]
	per_chunk.resize(CHUNKS * CHUNKS * 2)
	for i in per_chunk.size():
		per_chunk[i] = []
	var sp := 10.5
	var cnt := int(WORLD / sp)
	for gz in cnt:
		for gx in cnt:
			var x := (gx + rng.randf()) * sp
			var z := (gz + rng.randf()) * sp
			var ix := clampi(int(x / CELL), 0, N - 1)
			var iz := clampi(int(z / CELL), 0, N - 1)
			var f := fmask[iz * N + ix]
			if f < 0.12:
				f = 0.004 if (rmask[iz * N + ix] < 0.05 and hmap[iz * N + ix] < TREE_Y - 150.0) else 0.0
			if rng.randf() > f:
				continue
			var h := h_at(x, z)
			if h < WATER_Y + 3.0 or water_at(x, z) > h - 0.5:
				continue
			if n_at(x, z).y < 0.55:
				continue
			var near_v := false
			for v in village_sites:
				if Vector2(x - v.x, z - v.z).length() < 120.0:
					near_v = true
					break
			if near_v:
				continue
			var kind := 0
			if h < 760.0 and n_forest.get_noise_2d(x * 3.0, z * 3.0) > 0.05:
				kind = 1
			var s := rng.randf_range(15.0, 27.0) if kind == 0 else rng.randf_range(11.0, 17.0)
			s *= lerp(1.0, 0.55, smoothstep(TREE_Y - 300.0, TREE_Y, h))
			var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s * rng.randf_range(0.85, 1.15), s, s * rng.randf_range(0.85, 1.15)))
			b = Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.05)) * b
			var t := Transform3D(b, Vector3(x, h - 0.4, z))
			var tint := Color(rng.randf_range(0.8, 1.15), rng.randf_range(0.85, 1.15), rng.randf_range(0.8, 1.1))
			var ch := clampi(int(z / (CQ * CELL)), 0, CHUNKS - 1) * CHUNKS + clampi(int(x / (CQ * CELL)), 0, CHUNKS - 1)
			var key := ch * 2 + kind
			var id := tree_pos.size()
			tree_pos.append(Vector3(x, h, z))
			tree_chunk.append(key)
			tree_idx.append(per_chunk[key].size())
			tree_kind.append(kind)
			tree_burn.append(0.0)
			tree_size.append(s)
			var gk := Vector2i(int(x / 32.0), int(z / 32.0))
			if not tree_grid.has(gk):
				tree_grid[gk] = PackedInt32Array()
			tree_grid[gk].append(id)
			per_chunk[key].append([t, tint])
		if gz % 40 == 0:
			load_bar.value = 60.0 + 7.0 * float(gz) / cnt
			await _yield()
	tree_mmis.resize(per_chunk.size())
	for key in per_chunk.size():
		var list: Array = per_chunk[key]
		if list.is_empty():
			tree_mmis[key] = null
			continue
		var kind := key % 2
		var pair := []
		for lod in 2:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = meshes_near[kind] if lod == 0 else meshes_far[kind]
			mm.instance_count = list.size()
			for i in list.size():
				mm.set_instance_transform(i, list[i][0])
				mm.set_instance_color(i, list[i][1])
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			if lod == 0:
				mmi.visibility_range_end = 1150.0
				mmi.visibility_range_end_margin = 100.0
			else:
				mmi.visibility_range_begin = 1150.0
				mmi.visibility_range_begin_margin = 100.0
				mmi.visibility_range_end = 3600.0
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mmi)
			pair.append(mmi)
		tree_mmis[key] = pair


func _tree_set_color(id: int, c: Color) -> void:
	var pair = tree_mmis[tree_chunk[id]]
	if pair == null:
		return
	for mmi in pair:
		mmi.multimesh.set_instance_color(tree_idx[id], c)


# ============================================================================
#  KAYALAR
# ============================================================================
func _build_rocks() -> void:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _ntex(31, 0.03, false, 256, 4)
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3(0.25, 0.25, 0.25)
	mat.normal_enabled = true
	mat.normal_texture = _ntex(32, 0.05, true, 256, 4, 12.0)
	mat.roughness = 0.9
	var meshes := []
	for k in 3:
		_mb_begin()
		_mb_ellipsoid(Transform3D.IDENTITY, Vector3(1.0, 0.7, 0.9), 6, 9, Color(0.62, 0.6, 0.57), Color(0.4, 0.39, 0.36), 0.35, 40 + k)
		meshes.append(_mb_mesh(mat))
	var lists := [[], [], []]
	for i in 5200:
		var x := rng.randf_range(80.0, WORLD - 80.0)
		var z := rng.randf_range(80.0, WORLD - 80.0)
		var h := h_at(x, z)
		var nrm := n_at(x, z)
		var ix := clampi(int(x / CELL), 0, N - 1)
		var iz := clampi(int(z / CELL), 0, N - 1)
		var want := (1.0 - nrm.y) * 2.2 + rmask[iz * N + ix] * 0.8 + 0.05
		if rng.randf() > want or h < WATER_Y - 3.0:
			continue
		var s := rng.randf_range(0.7, 4.5) * (2.2 if rng.randf() < 0.08 else 1.0)
		var b := Basis(Vector3.UP, rng.randf() * TAU) * Basis(Vector3.RIGHT, rng.randf_range(-0.3, 0.3))
		b = b.scaled(Vector3(s, s * rng.randf_range(0.6, 1.1), s))
		lists[i % 3].append(Transform3D(b, Vector3(x, h - s * 0.25, z)))
	for k in 3:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[k]
		mm.instance_count = lists[k].size()
		for i in lists[k].size():
			mm.set_instance_transform(i, lists[k][i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.visibility_range_end = 1800.0
		add_child(mmi)

# ============================================================================
#  KÖYLER (İsviçre dağ evleri, kilise)
# ============================================================================
const VILLAGE_SHADER := """
shader_type spatial;
render_mode diffuse_burley;
uniform float night = 0.0;
uniform sampler2D grain : hint_default_white, filter_linear_mipmap, repeat_enable;
varying vec3 wp;
varying vec3 ln;
void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ln = NORMAL;
}
void fragment() {
	float g = texture(grain, wp.xz * 0.35 + wp.yy * 0.9).r;
	vec3 c = COLOR.rgb * (0.85 + 0.3 * g);
	ALBEDO = c;
	ROUGHNESS = 0.82;
	if (COLOR.a < 0.5) {
		ALBEDO = vec3(0.08, 0.1, 0.12);
		ROUGHNESS = 0.15;
		SPECULAR = 0.8;
		EMISSION = vec3(1.0, 0.62, 0.28) * night * 1.5 * (0.6 + 0.4 * fract(sin(dot(floor(wp.xz), vec2(12.9, 78.2))) * 437.5));
	}
}
"""

var village_mat: ShaderMaterial

func _build_villages() -> void:
	village_mat = ShaderMaterial.new()
	village_mat.shader = _shader(VILLAGE_SHADER)
	village_mat.set_shader_parameter("grain", _ntex(51, 0.08, false, 256, 3))
	for vi in village_sites.size():
		var c: Vector3 = village_sites[vi]
		_mb_begin()
		var placed: Array = []
		var to_lake := Vector2(LAKE_C.x - c.x, LAKE_C.y - c.z).normalized()
		# kilise
		var cy := atan2(to_lake.x, to_lake.y)
		_church(Transform3D(Basis(Vector3.UP, cy), Vector3(c.x, h_at(c.x, c.z) - 0.3, c.z)))
		_add_bld(Vector3(c.x, h_at(c.x, c.z), c.z), 12.0, 16.0)
		_add_bld(Vector3(c.x, h_at(c.x, c.z), c.z) + Basis(Vector3.UP, cy) * Vector3(0, 0, 12.5), 4.0, 34.0)
		placed.append(Vector2(c.x, c.z))
		var count := rng.randi_range(9, 15)
		var tries := 0
		while placed.size() < count + 1 and tries < 300:
			tries += 1
			var ang := rng.randf() * TAU
			var r := rng.randf_range(28.0, 150.0)
			var p := Vector2(c.x, c.z) + Vector2(cos(ang), sin(ang)) * r
			var ok := true
			for q in placed:
				if p.distance_to(q) < 24.0:
					ok = false
					break
			if not ok or n_at(p.x, p.y).y < 0.93 or water_at(p.x, p.y) > h_at(p.x, p.y) - 1.0:
				continue
			placed.append(p)
			var yaw := atan2(to_lake.x, to_lake.y) + rng.randf_range(-0.5, 0.5)
			var hy: float = min(min(h_at(p.x - 5, p.y - 5), h_at(p.x + 5, p.y + 5)), min(h_at(p.x + 5, p.y - 5), h_at(p.x - 5, p.y + 5)))
			var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, hy, p.y))
			_add_bld(Vector3(p.x, hy, p.y), 7.5, 11.0)
			if rng.randf() < 0.22:
				_barn(xf)
			else:
				_chalet(xf, rng.randf_range(8.0, 12.0), rng.randf_range(8.0, 11.0))
		_festival(c, placed, to_lake)
		var mi := MeshInstance3D.new()
		mi.mesh = _mb_mesh(village_mat)
		mi.visibility_range_end = 4500.0
		add_child(mi)


func _chalet(xf: Transform3D, w: float, d: float) -> void:
	var plaster := Color(0.92, 0.89, 0.83).darkened(rng.randf_range(0.0, 0.08))
	var stone := Color(0.52, 0.5, 0.47)
	var wood := Color(0.36, 0.21, 0.11).darkened(rng.randf_range(0.0, 0.2))
	var roof := Color(0.26, 0.22, 0.21) if rng.randf() < 0.6 else Color(0.48, 0.22, 0.15)
	var shut := Color(0.13, 0.36, 0.2) if rng.randf() < 0.5 else Color(0.62, 0.12, 0.1)
	var win := Color(0.1, 0.1, 0.1, 0.2)
	_mb_box(xf * _xf(Vector3(0, -1.0, 0)), Vector3(w + 0.4, 4.2, d + 0.4), stone)
	_mb_box(xf * _xf(Vector3(0, 2.7, 0)), Vector3(w, 3.2, d), plaster)
	_mb_box(xf * _xf(Vector3(0, 5.75, 0)), Vector3(w + 0.15, 2.9, d + 0.15), wood)
	var rh := w * 0.26
	var ov := 1.5
	var top := 7.2
	# kalkan duvarları
	for s in [-1.0, 1.0]:
		var z: float = s * (d * 0.5 + 0.075)
		var nn := (xf.basis * Vector3(0, 0, s)).normalized()
		_mb_flat(xf * Vector3(-w * 0.5, top, z), xf * Vector3(w * 0.5, top, z), xf * Vector3(0, top + rh, z), nn, wood.darkened(0.1))
	# çatı
	var half := w * 0.5 + ov
	var slope_len := Vector2(half, rh * half / (w * 0.5)).length()
	var ang := atan2(rh, w * 0.5)
	for s in [-1.0, 1.0]:
		var cxf := xf * Transform3D(Basis(Vector3(0, 0, 1), -s * ang), Vector3(s * half * 0.5, top + rh - rh * half / (w * 0.5) * 0.5 + 0.2, 0))
		_mb_box(cxf, Vector3(slope_len, 0.35, d + ov * 2.0), roof.darkened(0.25), roof, false)
	# baca
	_mb_box(xf * _xf(Vector3(w * 0.22, top + rh * 0.7, -d * 0.2)), Vector3(0.9, 2.4, 0.9), stone)
	# pencereler + panjurlar
	for floor_y in [2.9, 5.9]:
		for k in 3:
			var x := (k - 1) * w * 0.3
			_mb_box(xf * _xf(Vector3(x, floor_y, d * 0.5 + 0.1)), Vector3(1.1, 1.3, 0.12), win)
			_mb_box(xf * _xf(Vector3(x - 0.95, floor_y, d * 0.5 + 0.12)), Vector3(0.55, 1.4, 0.1), shut)
			_mb_box(xf * _xf(Vector3(x + 0.95, floor_y, d * 0.5 + 0.12)), Vector3(0.55, 1.4, 0.1), shut)
		for s in [-1.0, 1.0]:
			_mb_box(xf * _xf(Vector3(s * (w * 0.5 + 0.1), floor_y, 0)), Vector3(0.12, 1.3, 1.1), win)
	# balkon + çiçek kutuları
	_mb_box(xf * _xf(Vector3(0, 4.35, d * 0.5 + 0.8)), Vector3(w - 1.0, 0.2, 1.5), wood)
	_mb_box(xf * _xf(Vector3(0, 5.0, d * 0.5 + 1.5)), Vector3(w - 1.0, 1.0, 0.12), wood.lightened(0.1))
	_mb_box(xf * _xf(Vector3(0, 5.65, d * 0.5 + 1.55)), Vector3(w - 1.4, 0.35, 0.35), Color(0.85, 0.1, 0.16), Color(0.9, 0.2, 0.3))
	_mb_box(xf * _xf(Vector3(0, 0.0, d * 0.5 + 1.0)), Vector3(1.4, 2.4, 0.1), wood.darkened(0.3))


func _barn(xf: Transform3D) -> void:
	var wood := Color(0.33, 0.2, 0.11).darkened(rng.randf_range(0.0, 0.25))
	var w := rng.randf_range(9.0, 13.0)
	var d := rng.randf_range(12.0, 16.0)
	_mb_box(xf * _xf(Vector3(0, -0.5, 0)), Vector3(w + 0.3, 3.0, d + 0.3), Color(0.5, 0.48, 0.45))
	_mb_box(xf * _xf(Vector3(0, 3.0, 0)), Vector3(w, 5.0, d), wood)
	var rh := w * 0.3
	for s in [-1.0, 1.0]:
		var z: float = s * d * 0.5
		_mb_flat(xf * Vector3(-w * 0.5, 5.5, z), xf * Vector3(w * 0.5, 5.5, z), xf * Vector3(0, 5.5 + rh, z), (xf.basis * Vector3(0, 0, s)).normalized(), wood)
	var half := w * 0.5 + 1.2
	var ang := atan2(rh, w * 0.5)
	var sl := half / cos(ang)
	for s in [-1.0, 1.0]:
		var cxf := xf * Transform3D(Basis(Vector3(0, 0, 1), -s * ang), Vector3(s * half * 0.5, 5.5 + rh - tan(ang) * half * 0.5 + 0.2, 0))
		_mb_box(cxf, Vector3(sl, 0.3, d + 2.0), Color(0.2, 0.18, 0.17), Color(0.32, 0.3, 0.28), false)
	_mb_box(xf * _xf(Vector3(0, 2.0, d * 0.5 + 0.05)), Vector3(3.5, 4.0, 0.12), wood.darkened(0.35))


func _church(xf: Transform3D) -> void:
	var white := Color(0.95, 0.94, 0.9)
	var roof := Color(0.25, 0.22, 0.21)
	_mb_box(xf * _xf(Vector3(0, -1.0, 0)), Vector3(11.4, 4.0, 22.4), Color(0.52, 0.5, 0.47))
	_mb_box(xf * _xf(Vector3(0, 4.5, 0)), Vector3(11.0, 9.0, 22.0), white)
	var rh := 6.0
	for s in [-1.0, 1.0]:
		var z: float = s * 11.0
		_mb_flat(xf * Vector3(-5.5, 9.0, z), xf * Vector3(5.5, 9.0, z), xf * Vector3(0, 9.0 + rh, z), (xf.basis * Vector3(0, 0, s)).normalized(), white)
	var ang := atan2(rh, 5.5)
	var half := 6.5
	for s in [-1.0, 1.0]:
		var cxf := xf * Transform3D(Basis(Vector3(0, 0, 1), -s * ang), Vector3(s * half * 0.5, 9.0 + rh - tan(ang) * half * 0.5 + 0.2, 0))
		_mb_box(cxf, Vector3(half / cos(ang), 0.35, 23.0), roof.darkened(0.2), roof, false)
	# kule
	var tz := 12.5
	_mb_box(xf * _xf(Vector3(0, 10.0, tz)), Vector3(5.2, 20.0, 5.2), white)
	for k in 4:
		var b := Basis(Vector3.UP, k * PI * 0.5)
		_mb_box(xf * _xf(Vector3(0, 16.5, tz) + b * Vector3(0, 0, 2.66), Vector3(0, k * PI * 0.5, 0)), Vector3(1.6, 2.6, 0.1), Color(0.1, 0.1, 0.1, 0.2))
		_mb_box(xf * _xf(Vector3(0, 13.0, tz) + b * Vector3(0, 0, 2.66), Vector3(0, k * PI * 0.5, 0)), Vector3(2.2, 2.2, 0.08), Color(0.85, 0.7, 0.3))
	_mb_cyl(xf * _xf(Vector3(0, 20.0, tz), Vector3(0, PI * 0.25, 0)), 3.9, 0.0, 12.0, 4, Color(0.22, 0.38, 0.33), Color(0.3, 0.5, 0.42))
	_mb_cyl(xf * _xf(Vector3(0, 31.5, tz)), 0.12, 0.05, 2.5, 4, Color(0.85, 0.7, 0.3), Color(0.9, 0.8, 0.4))


# ============================================================================
#  İNEKLER (çanlarıyla)
# ============================================================================
func _cow_mesh() -> ArrayMesh:
	_mb_begin()
	var brown := Color(0.42, 0.26, 0.14)
	var white := Color(0.92, 0.9, 0.86)
	_mb_ellipsoid(_xf(Vector3(0, 1.3, 0)), Vector3(0.7, 0.62, 1.25), 6, 10, brown, brown.darkened(0.2))
	_mb_ellipsoid(_xf(Vector3(0.25, 1.45, 0.3)), Vector3(0.5, 0.5, 0.7), 4, 8, white, white.darkened(0.1))
	_mb_ellipsoid(_xf(Vector3(0, 1.55, -1.35), Vector3(0.45, 0, 0)), Vector3(0.32, 0.34, 0.5), 5, 8, white, white.darkened(0.15))
	_mb_ellipsoid(_xf(Vector3(0, 1.35, -1.75)), Vector3(0.25, 0.2, 0.18), 4, 6, Color(0.85, 0.6, 0.58), Color(0.6, 0.4, 0.4))
	for s in [-1.0, 1.0]:
		_mb_ellipsoid(_xf(Vector3(s * 0.38, 1.78, -1.25), Vector3(0, 0, s * 0.4)), Vector3(0.2, 0.06, 0.12), 3, 6, brown, brown)
		_mb_cyl(_xf(Vector3(s * 0.2, 1.9, -1.3), Vector3(0, 0, -s * 0.9)), 0.05, 0.0, 0.3, 5, Color(0.9, 0.85, 0.7), Color(0.4, 0.35, 0.3))
	for p in [Vector3(-0.42, 0, -0.85), Vector3(0.42, 0, -0.85), Vector3(-0.42, 0, 0.85), Vector3(0.42, 0, 0.85)]:
		_mb_box(_xf(p + Vector3(0, 0.45, 0)), Vector3(0.24, 0.9, 0.26), white.darkened(0.1))
		_mb_box(_xf(p + Vector3(0, 0.06, 0)), Vector3(0.26, 0.12, 0.3), Color(0.15, 0.13, 0.12))
	_mb_ellipsoid(_xf(Vector3(0, 0.75, 0.55)), Vector3(0.28, 0.2, 0.3), 4, 6, Color(0.9, 0.65, 0.65), Color(0.8, 0.5, 0.5))
	_mb_cyl(_xf(Vector3(0, 0.95, -1.25)), 0.16, 0.11, 0.32, 8, Color(0.85, 0.65, 0.2), Color(0.95, 0.8, 0.35), true)
	_mb_box(_xf(Vector3(0, 1.3, -1.15), Vector3(0.4, 0, 0)), Vector3(0.66, 0.14, 0.12), Color(0.2, 0.15, 0.12))
	_mb_cyl(_xf(Vector3(0, 1.45, 1.2), Vector3(-0.3, 0, 0)), 0.05, 0.03, 1.0, 4, brown, brown)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	return _mb_mesh(mat)


func _build_cows() -> void:
	var mesh := _cow_mesh()
	for v in village_sites:
		for herd in 2:
			var hc := Vector2(v.x, v.z) + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(220.0, 420.0)
			if n_at(hc.x, hc.y).y < 0.9 or h_at(hc.x, hc.y) < WATER_Y + 3.0:
				continue
			for i in rng.randi_range(4, 7):
				var p := hc + Vector2(rng.randf_range(-30, 30), rng.randf_range(-30, 30))
				var mi := MeshInstance3D.new()
				mi.mesh = mesh
				mi.visibility_range_end = 900.0
				add_child(mi)
				var cw := {"node": mi, "pos": p, "yaw": rng.randf() * TAU, "home": hc, "target": p, "speed": 0.0, "flee": 0.0, "bell": rng.randf_range(1.0, 8.0), "t": rng.randf() * 10.0}
				cows.append(cw)
				_cow_place(cw)


func _cow_place(cw: Dictionary) -> void:
	var p: Vector2 = cw.pos
	var h := h_at(p.x, p.y)
	var n := n_at(p.x, p.y)
	var fwd := Vector3(sin(cw.yaw), 0, cos(cw.yaw)) * -1.0
	var right := n.cross(fwd).normalized() * -1.0
	fwd = right.cross(n).normalized() * -1.0
	var bob: float = abs(sin(cw.t * 9.0)) * 0.15 * clamp(cw.speed / 6.0, 0.0, 1.0)
	cw.node.global_transform = Transform3D(Basis(right, n, -fwd), Vector3(p.x, h + bob, p.y))


func _update_cows(delta: float, threat: Vector3) -> void:
	for cw in cows:
		var p: Vector2 = cw.pos
		var tp := Vector2(threat.x, threat.z)
		var dd := p.distance_to(tp)
		if dd > 1400.0:
			continue
		cw.t += delta
		if dd < 70.0 and threat.y - h_at(p.x, p.y) < 60.0:
			if cw.flee <= 0.0:
				cw.bell = 0.0
			cw.flee = 4.0
			cw.target = p + (p - tp).normalized() * 80.0
		cw.flee -= delta
		var want := 9.0 if cw.flee > 0.0 else 1.1
		var to: Vector2 = cw.target - p
		if to.length() < 2.0:
			if cw.flee <= 0.0 and rng.randf() < delta * 0.25:
				cw.target = cw.home + Vector2(rng.randf_range(-45, 45), rng.randf_range(-45, 45))
			want = 0.0
		cw.speed = move_toward(cw.speed, want, delta * 6.0)
		if cw.speed > 0.05 and to.length() > 0.5:
			var ty := atan2(-to.x, -to.y)
			cw.yaw = lerp_angle(cw.yaw, ty, delta * 3.0)
			var np: Vector2 = p + Vector2(-sin(cw.yaw), -cos(cw.yaw)) * cw.speed * delta
			if h_at(np.x, np.y) > WATER_Y + 1.5 and n_at(np.x, np.y).y > 0.8:
				cw.pos = np
			else:
				cw.target = cw.home
		cw.bell -= delta
		if cw.bell <= 0.0:
			cw.bell = rng.randf_range(0.35, 0.8) if cw.speed > 3.0 else rng.randf_range(3.0, 9.0)
			if dd < 260.0:
				_play3d("cowbell", Vector3(p.x, h_at(p.x, p.y) + 1.0, p.y), -6.0, rng.randf_range(0.92, 1.1))
		if dd < 900.0:
			_cow_place(cw)


# ============================================================================
#  ÇİMEN (GPU — yükseklik haritasını shader içinde okur)
# ============================================================================
const GRASS_SHADER := """
shader_type spatial;
render_mode skip_vertex_transform, cull_disabled, diffuse_burley;
uniform sampler2D hm : filter_nearest;
uniform sampler2D nz : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float cell;
uniform float nres;
uniform float spacing;
uniform float radius = 90.0;
uniform float water_y;
uniform float tree_y;
uniform vec3 push_pos;
uniform float push_amt = 0.0;
varying vec3 gcol;
varying float tip;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec4 fe(ivec2 c) { return texelFetch(hm, clamp(c, ivec2(0), ivec2(int(nres) - 1)), 0); }
void vertex() {
	vec3 o = MODEL_MATRIX[3].xyz;
	vec2 cid = floor(o.xz / spacing + 0.5);
	float r1 = hash(cid);
	float r2 = hash(cid + 17.3);
	float r3 = hash(cid + 41.7);
	vec2 wp = cid * spacing + (vec2(r1, r2) - 0.5) * spacing * 0.95;
	vec2 f = wp / cell;
	ivec2 i = ivec2(floor(f));
	vec2 t = fract(f);
	vec4 a = fe(i);
	vec4 b = fe(i + ivec2(1, 0));
	vec4 c = fe(i + ivec2(0, 1));
	vec4 d = fe(i + ivec2(1, 1));
	float h = (t.x > t.y) ? a.r + (b.r - a.r) * t.x + (d.r - b.r) * t.y : a.r + (d.r - c.r) * t.x + (c.r - a.r) * t.y;
	vec4 m = mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
	float grad = length(vec2(b.r - a.r, c.r - a.r)) / cell;
	vec3 camp = INV_VIEW_MATRIX[3].xyz;
	float dist = length(vec3(wp.x, h, wp.y) - camp);
	float sc = 1.0 - smoothstep(radius * 0.65, radius, dist);
	sc *= 1.0 - smoothstep(0.45, 0.75, grad);
	sc *= smoothstep(water_y + 0.6, water_y + 1.8, h);
	sc *= 1.0 - smoothstep(0.12, 0.35, m.g);
	sc *= 1.0 - smoothstep(tree_y + 60.0, tree_y + 380.0, h);
	float ang = r3 * 6.2831;
	vec3 v = VERTEX;
	float hgt = v.y;
	v.xz = mat2(vec2(cos(ang), -sin(ang)), vec2(sin(ang), cos(ang))) * v.xz;
	v *= sc * (0.38 + 0.5 * r1) * mix(1.0, 0.6, smoothstep(tree_y - 300.0, tree_y + 200.0, h));
	float w = sin(TIME * 1.6 + wp.x * 0.07 + wp.y * 0.045) * 0.55 + sin(TIME * 3.3 + wp.x * 0.23) * 0.18;
	v.x += w * hgt * hgt * 0.32;
	v.z += w * hgt * hgt * 0.18;
	vec2 dd = wp - push_pos.xz;
	float pd = length(dd);
	v.xz += normalize(dd + 0.001) * hgt * hgt * push_amt * (1.0 - smoothstep(0.0, 22.0, pd));
	v.y *= 1.0 - 0.6 * push_amt * (1.0 - smoothstep(0.0, 22.0, pd));
	vec3 world = vec3(wp.x, h - 0.05, wp.y) + v;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	float n1 = texture(nz, wp * 0.0011).r;
	vec3 g = mix(vec3(0.105, 0.27, 0.04), vec3(0.27, 0.43, 0.075), smoothstep(0.25, 0.78, n1));
	g = mix(g, vec3(0.40, 0.42, 0.20), smoothstep(tree_y - 250.0, tree_y + 320.0, h));
	gcol = g * (0.8 + 0.4 * r2) * mix(1.0, 0.65, m.b);
	tip = hgt;
}
void fragment() {
	ALBEDO = gcol * mix(0.42, 1.25, tip);
	ROUGHNESS = 0.8;
	SPECULAR = 0.25;
	BACKLIGHT = gcol * 0.6;
}
"""

var grass_mat: ShaderMaterial
var grass_spacing := 0.72
var grass_extent := 92.0

func _grass_mesh() -> ArrayMesh:
	_mb_begin()
	for b in 6:
		var ang := rng.randf() * TAU
		var off := Vector3(rng.randf_range(-0.25, 0.25), 0, rng.randf_range(-0.25, 0.25))
		var dir := Vector3(cos(ang), 0, sin(ang))
		var lean := Vector3(-dir.z, 0, dir.x) * rng.randf_range(0.05, 0.25)
		var w := 0.055
		var hh := rng.randf_range(0.7, 1.0)
		var prev_l := off - dir * w
		var prev_r := off + dir * w
		for s in 3:
			var t := float(s + 1) / 3.0
			var c := off + lean * t * t + Vector3(0, t * hh, 0)
			var ww := w * (1.0 - t)
			var l := c - dir * ww
			var r := c + dir * ww
			var nn := Vector3.UP
			if s < 2:
				_mb_tri(prev_l, prev_r, r, nn, nn, nn, Color.WHITE)
				_mb_tri(prev_l, r, l, nn, nn, nn, Color.WHITE)
			else:
				_mb_tri(prev_l, prev_r, c, nn, nn, nn, Color.WHITE)
			prev_l = l
			prev_r = r
	return _mb_mesh()


func _build_grass() -> void:
	grass_mat = ShaderMaterial.new()
	grass_mat.shader = _shader(GRASS_SHADER)
	grass_mat.set_shader_parameter("hm", hm_tex)
	grass_mat.set_shader_parameter("nz", terrain_mat.get_shader_parameter("nz"))
	grass_mat.set_shader_parameter("cell", CELL)
	grass_mat.set_shader_parameter("nres", float(N))
	grass_mat.set_shader_parameter("spacing", grass_spacing)
	grass_mat.set_shader_parameter("water_y", WATER_Y)
	grass_mat.set_shader_parameter("tree_y", TREE_Y)
	var mesh := _grass_mesh()
	mesh.surface_set_material(0, grass_mat)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	if _mob():
		grass_spacing = 0.85
		grass_extent = 72.0
		grass_mat.set_shader_parameter("spacing", grass_spacing)
	var g := int(2.0 * grass_extent / grass_spacing)
	mm.instance_count = g * g
	var k := 0
	for z in g:
		for x in g:
			mm.set_instance_transform(k, Transform3D(Basis(), Vector3((x - g * 0.5) * grass_spacing, 0, (z - g * 0.5) * grass_spacing)))
			k += 1
	grass_mmi = MultiMeshInstance3D.new()
	grass_mmi.multimesh = mm
	grass_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	grass_mmi.custom_aabb = AABB(Vector3(-200, -100, -200), Vector3(400, 4000, 400))
	add_child(grass_mmi)


# ============================================================================
#  GÖKYÜZÜ, GÜNEŞ, ATMOSFER
# ============================================================================
const SKY_SHADER := """
shader_type sky;
uniform sampler2D cn : filter_linear_mipmap, repeat_enable;
uniform float cover = 0.42;
uniform float ctime = 0.0;
uniform float day = 1.0;
float hash(vec3 p) { return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453); }
void sky() {
	vec3 d = EYEDIR;
	vec3 L = LIGHT0_DIRECTION;
	float sh = L.y;
	float dayf = day;
	vec3 zen = mix(vec3(0.004, 0.008, 0.025), vec3(0.11, 0.30, 0.68), dayf);
	vec3 hz = mix(vec3(0.02, 0.035, 0.07), vec3(0.58, 0.73, 0.90), dayf);
	float sunset = (1.0 - smoothstep(0.0, 0.32, sh)) * smoothstep(-0.18, 0.02, sh);
	float tow = pow(max(dot(normalize(vec3(d.x, 0.0, d.z) + 1e-4), normalize(vec3(L.x, 0.0, L.z) + 1e-4)), 0.0), 3.0);
	hz = mix(hz, vec3(1.0, 0.48, 0.22), sunset * (0.3 + 0.7 * tow));
	zen = mix(zen, vec3(0.25, 0.25, 0.45), sunset * 0.35);
	float hor = pow(1.0 - clamp(d.y, 0.0, 1.0), 5.0);
	vec3 col = mix(zen, hz, hor);
	if (d.y < 0.0) col = mix(hz, hz * 0.55, smoothstep(0.0, 0.25, -d.y));
	float sd = dot(d, L);
	vec3 sunc = mix(vec3(1.0, 0.55, 0.3), vec3(1.0, 0.96, 0.88), smoothstep(0.0, 0.4, sh));
	float disk = smoothstep(0.99975, 0.9999, sd);
	col += sunc * (disk * 40.0 + pow(max(sd, 0.0), 600.0) * 3.0 + pow(max(sd, 0.0), 10.0) * 0.22 * dayf) * smoothstep(-0.06, 0.02, sh);
	// ay
	float md = dot(d, -L);
	col += vec3(0.8, 0.85, 1.0) * smoothstep(0.9997, 0.99985, md) * 3.0 * (1.0 - dayf);
	// yıldızlar
	if (dayf < 0.6 && d.y > 0.0) {
		vec3 g = floor(d * 300.0);
		float s = hash(g);
		col += vec3(0.9, 0.92, 1.0) * step(0.9975, s) * (1.0 - dayf / 0.6) * (0.5 + 0.5 * sin(TIME * 2.0 + s * 50.0)) * 1.5;
	}
	// bulutlar
	if (d.y > 0.0) {
		vec2 uv = d.xz / (d.y + 0.1) * 0.55 + vec2(ctime * 0.004, ctime * 0.0015);
		float n = texture(cn, uv * 0.3).r * 0.62 + texture(cn, uv * 0.9 + 0.31).r * 0.28 + texture(cn, uv * 2.7 + 0.7).r * 0.1;
		float c = smoothstep(1.0 - cover, 1.0 - cover + 0.28, n) * smoothstep(0.0, 0.18, d.y);
		vec2 uv2 = uv + L.xz * 0.03;
		float n2 = texture(cn, uv2 * 0.3).r * 0.62 + texture(cn, uv2 * 0.9 + 0.31).r * 0.28;
		float lit = clamp(0.55 + (n - n2) * 5.0, 0.0, 1.0);
		vec3 cc = mix(vec3(0.42, 0.47, 0.56), vec3(1.05, 1.02, 0.98), lit);
		cc = mix(cc, cc * vec3(1.3, 0.75, 0.55), sunset);
		cc *= mix(0.04, 1.0, dayf);
		col = mix(col, cc, c * 0.92);
	}
	COLOR = col;
}
"""

func _build_sky_and_light() -> void:
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = _shader(SKY_SHADER)
	sky_mat.set_shader_parameter("cn", _ntex(61, 0.006, false, 512, 5))
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.05
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.06
	env.glow_hdr_threshold = 1.3
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.ssao_enabled = true
	env.ssao_radius = 2.0
	env.ssao_intensity = 1.6
	env.ssao_power = 1.4
	env.fog_enabled = true
	env.fog_light_color = Color(0.62, 0.73, 0.88)
	env.fog_density = 0.00008
	env.fog_sun_scatter = 0.25
	env.fog_aerial_perspective = 0.45
	env.fog_sky_affect = 0.15
	env.fog_height = 380.0
	env.fog_height_density = 0.0005
	env.volumetric_fog_density = 0.0004
	env.volumetric_fog_albedo = Color(0.92, 0.94, 1.0)
	env.volumetric_fog_length = 900.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_anisotropy = 0.35
	env.volumetric_fog_ambient_inject = 0.15
	env.volumetric_fog_sky_affect = 0.0
	env.sdfgi_cascades = 6
	env.sdfgi_min_cell_size = 1.2
	env.sdfgi_use_occlusion = true
	env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_50_PERCENT
	env.sdfgi_energy = 0.9
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.12
	env.adjustment_contrast = 1.04
	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 1600.0
	sun.directional_shadow_split_1 = 0.03
	sun.directional_shadow_split_2 = 0.1
	sun.directional_shadow_split_3 = 0.3
	sun.directional_shadow_blend_splits = true
	sun.light_angular_distance = 0.6
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.4
	sun.shadow_blur = 1.2
	add_child(sun)
	_update_sun(0.0)


func _update_sun(delta: float) -> void:
	var a := (time_of_day - 6.0) / 12.0 * PI
	var L := Vector3(cos(a), sin(a) * 0.86, 0.42).normalized()
	var day: float = smoothstep(-0.14, 0.1, L.y)
	var light_dir := L if L.y > -0.06 else -L
	sun.global_transform = Transform3D(Basis.looking_at(-light_dir, Vector3.UP if abs(light_dir.y) < 0.98 else Vector3.FORWARD), Vector3.ZERO)
	var warm: float = smoothstep(0.0, 0.42, L.y)
	if L.y > -0.06:
		sun.light_color = Color(1.0, 0.52, 0.28).lerp(Color(1.0, 0.95, 0.88), warm)
		sun.light_energy = 1.55 * smoothstep(-0.06, 0.12, L.y)
	else:
		sun.light_color = Color(0.55, 0.65, 0.95)
		sun.light_energy = 0.13
	sky_mat.set_shader_parameter("day", day)
	env.ambient_light_energy = lerp(0.35, 1.0, day)
	var fogc := Color(0.04, 0.05, 0.09).lerp(Color(0.62, 0.73, 0.88), day)
	var sunset: float = (1.0 - smoothstep(0.0, 0.3, L.y)) * smoothstep(-0.18, 0.02, L.y)
	env.fog_light_color = fogc.lerp(Color(0.95, 0.6, 0.45), sunset * 0.6)
	env.volumetric_fog_albedo = Color(0.92, 0.94, 1.0).lerp(Color(1.0, 0.75, 0.6), sunset * 0.6)
	if village_mat:
		village_mat.set_shader_parameter("night", 1.0 - day)
	var lk: float = lerpf(0.07, 1.0, day) * (1.0 - sunset * 0.3)
	water_mat.set_shader_parameter("lit", lk)
	river_mat.set_shader_parameter("lit", lk)
	if cloud_mat:
		cloud_mat.set_shader_parameter("sun_dir", L)
		cloud_mat.set_shader_parameter("day", day)
		cloud_mat.set_shader_parameter("sunset", sunset)


# ============================================================================
#  3B BULUTLAR (yumuşak billboard kümeleri — içinden uçulabilir)
# ============================================================================
const CLOUD_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform, fog_disabled;
uniform sampler2D tex : source_color, filter_linear_mipmap;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform vec3 sun_dir = vec3(0.3, 0.8, 0.3);
uniform float day = 1.0;
uniform float sunset = 0.0;
uniform float world = 6144.0;
varying float shade;
varying float rot;
varying float fade;
void vertex() {
	vec3 o = MODEL_MATRIX[3].xyz;
	o.x = mod(o.x + TIME * 3.0 + world * 0.15, world * 1.3) - world * 0.15;
	float sc = length(MODEL_MATRIX[0].xyz);
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	rot = INSTANCE_CUSTOM.y * 6.28;
	vec2 q = mat2(vec2(cos(rot), -sin(rot)), vec2(sin(rot), cos(rot))) * VERTEX.xy;
	vec3 w = o + (right * q.x + up * q.y) * sc;
	VERTEX = (VIEW_MATRIX * vec4(w, 1.0)).xyz;
	float cd = length(VERTEX);
	fade = smoothstep(sc * 0.25, sc * 0.9, cd) * (1.0 - smoothstep(7000.0, 9000.0, cd));
	vec3 tocam = normalize(INV_VIEW_MATRIX[3].xyz - o);
	shade = clamp(INSTANCE_CUSTOM.x * 0.75 + 0.25 + dot(tocam, sun_dir) * 0.25, 0.0, 1.0);
}
void fragment() {
	vec4 t = texture(tex, UV);
	float d = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	v.xyz /= v.w;
	float soft = clamp((VERTEX.z - v.z) / 60.0, 0.0, 1.0);
	vec3 lit = mix(vec3(1.0, 0.99, 0.96), vec3(1.0, 0.72, 0.52), sunset);
	vec3 dark = mix(vec3(0.5, 0.56, 0.66), vec3(0.45, 0.35, 0.42), sunset);
	vec3 c = mix(dark, lit, shade * (0.75 + 0.25 * t.r));
	ALBEDO = mix(c * vec3(0.16, 0.18, 0.26), c, day);
	ALPHA = t.a * soft * fade * 0.85;
}
"""

var cloud_mat: ShaderMaterial

func _cloud_texture() -> ImageTexture:
	var s := 128
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var nz := _noise(77, 0.045, FastNoiseLite.FRACTAL_FBM, 4)
	for y in s:
		for x in s:
			var p := Vector2(x, y) / s * 2.0 - Vector2.ONE
			var r := p.length()
			var n := nz.get_noise_2d(x, y) * 0.5 + 0.5
			var a: float = clamp((1.0 - smoothstep(0.35, 1.0, r + (n - 0.5) * 0.6)) * (0.55 + n * 0.8), 0.0, 1.0)
			img.set_pixel(x, y, Color(n, n, n, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _build_clouds() -> void:
	cloud_mat = ShaderMaterial.new()
	cloud_mat.shader = _shader(CLOUD_SHADER)
	cloud_mat.set_shader_parameter("tex", _cloud_texture())
	cloud_mat.set_shader_parameter("world", WORLD)
	cloud_mat.render_priority = -1
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	q.material = cloud_mat
	var list := []
	for c in 60:
		var cp := Vector3(rng.randf_range(-500, WORLD + 500), rng.randf_range(1900, 2700), rng.randf_range(-500, WORLD + 500))
		var ext := Vector3(rng.randf_range(180, 420), rng.randf_range(50, 110), rng.randf_range(150, 330))
		for i in rng.randi_range(9, 18):
			var o := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.6, 1), rng.randf_range(-1, 1)) * ext
			var s := rng.randf_range(150, 290) * (1.0 - o.length() / ext.length() * 0.35)
			list.append([Transform3D(Basis().scaled(Vector3(s, s, s)), cp + o), Color((o.y / ext.y) * 0.5 + 0.5, rng.randf(), 0, 0)])
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = q
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i][0])
		mm.set_instance_custom_data(i, list[i][1])
	cloud_mmi = MultiMeshInstance3D.new()
	cloud_mmi.multimesh = mm
	cloud_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cloud_mmi.custom_aabb = AABB(Vector3(-3000, 1000, -3000), Vector3(WORLD + 6000, 3000, WORLD + 6000))
	add_child(cloud_mmi)


# ============================================================================
#  KUŞ SÜRÜLERİ
# ============================================================================
const BIRD_SHADER := """
shader_type spatial;
render_mode cull_disabled;
void vertex() {
	float ph = float(INSTANCE_ID) * 1.7;
	VERTEX.y += abs(VERTEX.x) * sin(TIME * 11.0 + ph) * 0.9;
}
void fragment() {
	ALBEDO = vec3(0.08, 0.07, 0.07);
	ROUGHNESS = 0.9;
}
"""

func _build_birds() -> void:
	_mb_begin()
	var c := Color(0.1, 0.1, 0.1)
	_mb_tri(Vector3(0, 0, -0.5), Vector3(-1.1, 0.05, 0.1), Vector3(0, 0, 0.2), Vector3.UP, Vector3.UP, Vector3.UP, c)
	_mb_tri(Vector3(0, 0, -0.5), Vector3(1.1, 0.05, 0.1), Vector3(0, 0, 0.2), Vector3.UP, Vector3.UP, Vector3.UP, c)
	_mb_tri(Vector3(0, 0, 0.2), Vector3(-0.2, 0, 0.6), Vector3(0.2, 0, 0.6), Vector3.UP, Vector3.UP, Vector3.UP, c)
	var bm := ShaderMaterial.new()
	bm.shader = _shader(BIRD_SHADER)
	var mesh := _mb_mesh(bm)
	bird_mm = MultiMesh.new()
	bird_mm.transform_format = MultiMesh.TRANSFORM_3D
	bird_mm.mesh = mesh
	var flocks := 5
	var per := 16
	bird_mm.instance_count = flocks * per
	for f in flocks:
		var center := Vector2(rng.randf_range(0.2, 0.8), rng.randf_range(0.2, 0.8)) * WORLD
		if f < village_sites.size():
			center = Vector2(village_sites[f].x, village_sites[f].z)
		birds.append({"c": center, "r": rng.randf_range(150, 350), "sp": rng.randf_range(0.05, 0.09) * (1 if rng.randf() < 0.5 else -1), "ph": rng.randf() * TAU, "n": per, "scat": 0.0, "off": rng.randf() * 100.0})
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = bird_mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-100, 0, -100), Vector3(WORLD + 200, 3000, WORLD + 200))
	add_child(mmi)


func _update_birds(delta: float, threat: Vector3) -> void:
	var k := 0
	for fl in birds:
		fl.ph += fl.sp * delta
		var cp: Vector2 = fl.c + Vector2(cos(fl.ph), sin(fl.ph * 1.3)) * fl.r
		var base_h := h_at(cp.x, cp.y) + 45.0
		var center := Vector3(cp.x, base_h + 15.0 * sin(fl.ph * 3.0), cp.y)
		if center.distance_to(threat) < 90.0:
			fl.scat = 1.0
		fl.scat = max(0.0, fl.scat - delta * 0.15)
		var tang := Vector3(-sin(fl.ph), 0, cos(fl.ph) * 1.3).normalized() * signf(fl.sp)
		for i in fl.n:
			var t: float = game_time * 0.6 + i * 2.1 + fl.off
			var o := Vector3(sin(t * 0.9 + i) * 14.0, sin(t * 1.3 + i * 0.7) * 5.0, cos(t * 0.7 + i * 1.3) * 14.0)
			o *= 1.0 + fl.scat * 5.0
			var p := center + o
			var b := Basis.looking_at(tang + Vector3(sin(t) * 0.2, 0, cos(t) * 0.2), Vector3.UP).scaled(Vector3(0.9, 0.9, 0.9))
			bird_mm.set_instance_transform(k, Transform3D(b, p))
			k += 1


# ============================================================================
#  ALTIN HALKALAR (görev)
# ============================================================================
func _build_rings() -> void:
	var tm := TorusMesh.new()
	tm.inner_radius = 11.0
	tm.outer_radius = 12.8
	tm.rings = 48
	tm.ring_segments = 12
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.75, 0.25)
	mat.metallic = 0.9
	mat.roughness = 0.25
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.6, 0.15)
	mat.emission_energy_multiplier = 2.2
	tm.material = mat
	var spots: Array = []
	var tries := 0
	while spots.size() < 25 and tries < 6000:
		tries += 1
		var p: Vector3
		var fwd := Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized()
		var kind := spots.size() % 4
		if kind == 0 and not rivers.is_empty():
			var rv = rivers[rng.randi() % rivers.size()]
			var i := rng.randi_range(4, rv.pts.size() - 5)
			p = rv.pts[i] + Vector3(0, rng.randf_range(16, 30), 0)
			fwd = (rv.pts[i + 1] - rv.pts[i - 1]).normalized()
			fwd.y = 0
		elif kind == 1:
			var x := rng.randf_range(0.15, 0.85) * WORLD
			var z := rng.randf_range(0.15, 0.85) * WORLD
			p = Vector3(x, h_at(x, z) + rng.randf_range(35, 70), z)
			if p.y < 900.0:
				continue
		elif kind == 2:
			var a := rng.randf() * TAU
			var q := LAKE_C + Vector2(cos(a), sin(a)) * rng.randf_range(0, 900)
			p = Vector3(q.x, max(WATER_Y, h_at(q.x, q.y)) + rng.randf_range(12, 25), q.y)
		else:
			var x := rng.randf_range(0.1, 0.9) * WORLD
			var z := rng.randf_range(0.1, 0.9) * WORLD
			p = Vector3(x, h_at(x, z) + rng.randf_range(60, 200), z)
		var ok := true
		for s in spots:
			if s[0].distance_to(p) < 450.0:
				ok = false
				break
		if not ok:
			continue
		for k in 8:
			var o := Vector3.RIGHT.rotated(Vector3.UP, k * TAU / 8.0) * 20.0
			if h_at(p.x + o.x, p.z + o.z) > p.y - 10.0:
				ok = false
		if ok and fwd.length() > 0.1:
			spots.append([p, fwd.normalized()])
	for s in spots:
		var mi := MeshInstance3D.new()
		mi.mesh = tm
		add_child(mi)
		var b := Basis.looking_at(s[1], Vector3.UP) * Basis(Vector3.RIGHT, PI * 0.5)
		mi.global_transform = Transform3D(b, s[0])
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.7, 0.3)
		light.light_energy = 2.0
		light.omni_range = 25.0
		mi.add_child(light)
		rings.append({"node": mi, "pos": s[0], "fwd": s[1], "got": false, "t": rng.randf() * 10.0})

# ============================================================================
#  EJDERHA MODELİ (prosedürel) — pullar, kanat zarı, boyun, kuyruk, bacaklar
# ============================================================================
const DRAGON_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform vec3 top_a : source_color = vec3(0.50, 0.06, 0.035);
uniform vec3 top_b : source_color = vec3(0.17, 0.02, 0.015);
uniform vec3 belly : source_color = vec3(0.86, 0.58, 0.26);
uniform float scale_size = 4.0;
uniform float burn = 0.0;
varying vec3 lp;
varying vec3 ln;
vec3 h3(vec3 p) {
	p = vec3(dot(p, vec3(127.1, 311.7, 74.7)), dot(p, vec3(269.5, 183.3, 246.1)), dot(p, vec3(113.5, 271.9, 124.6)));
	return fract(sin(p) * 43758.5453);
}
vec2 vor(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	float d1 = 8.0;
	float d2 = 8.0;
	for (int z = -1; z <= 1; z++)
	for (int y = -1; y <= 1; y++)
	for (int x = -1; x <= 1; x++) {
		vec3 g = vec3(float(x), float(y), float(z));
		vec3 o = h3(i + g);
		vec3 r = g + o - f;
		float d = dot(r, r);
		if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
	}
	return vec2(sqrt(d1), sqrt(d2));
}
void vertex() {
	lp = VERTEX;
	ln = NORMAL;
}
void fragment() {
	if (COLOR.a < 0.5) {
		ALBEDO = COLOR.rgb;
		ROUGHNESS = 0.45;
		SPECULAR = 0.5;
	} else {
		vec2 v = vor(lp * scale_size);
		float edge = v.y - v.x;
		float sc = smoothstep(0.0, 0.22, edge);
		float blur = clamp(length(fwidth(lp * scale_size)) * 1.2, 0.0, 1.0);
		sc = mix(sc, 0.7, blur);
		float bel = 1.0 - smoothstep(-0.55, 0.15, normalize(ln).y);
		vec3 c = mix(top_b, top_a, 0.35 + 0.65 * sc * (0.75 + 0.25 * h3(floor(lp * scale_size)).x));
		float plates = smoothstep(0.1, 0.25, abs(fract(lp.z * 2.4) - 0.5));
		vec3 bc = belly * mix(0.7, 1.0, plates);
		c = mix(c, bc, bel);
		c *= COLOR.rgb;
		ALBEDO = c;
		ROUGHNESS = mix(0.62, 0.32, sc) ;
		METALLIC = 0.12 * (1.0 - bel);
		SPECULAR = 0.55;
		float hgt = mix(sc, plates, bel);
		vec3 dpx = dFdx(VERTEX);
		vec3 dpy = dFdy(VERTEX);
		float dhx = dFdx(hgt);
		float dhy = dFdy(hgt);
		vec3 r1 = cross(dpy, NORMAL);
		vec3 r2 = cross(NORMAL, dpx);
		float det = dot(dpx, r1);
		vec3 grad = sign(det) * (dhx * r1 + dhy * r2);
		NORMAL = normalize(abs(det) * NORMAL - grad * 0.9);
		RIM = 0.35;
		RIM_TINT = 0.6;
	}
	EMISSION = vec3(1.0, 0.35, 0.05) * burn;
}
"""

const MEMBRANE_SHADER := """
shader_type spatial;
render_mode cull_disabled, diffuse_burley;
uniform vec3 mcol : source_color = vec3(0.42, 0.07, 0.045);
uniform vec3 vcol : source_color = vec3(0.13, 0.02, 0.015);
uniform vec3 glow : source_color = vec3(1.0, 0.38, 0.14);
void fragment() {
	float s = UV.x;
	float t = UV.y;
	float v1 = 1.0 - smoothstep(0.0, 0.018, abs(fract(t * 3.0) - 0.5) - 0.47);
	float v2 = 1.0 - smoothstep(0.0, 0.03, abs(fract(s * 5.0 + t * 0.7) - 0.5) - 0.465);
	float ve = clamp(max(v1 * 0.8, v2 * 0.45 * s), 0.0, 1.0);
	float edge = smoothstep(0.82, 1.0, s);
	vec3 c = mix(mcol, vcol, ve) * (0.75 + 0.35 * s);
	c = mix(c, vcol, edge * 0.5);
	ALBEDO = c;
	ROUGHNESS = 0.55;
	SPECULAR = 0.35;
	BACKLIGHT = glow * (1.0 - ve * 0.75) * 0.9;
}
"""

var dragon: Node3D
var dbody: Node3D
var dragon_mat: ShaderMaterial
var membrane_mat: ShaderMaterial
var bone_mat: ShaderMaterial
var neck: Array = []
var dhead: Node3D
var djaw: Node3D
var dmouth: Node3D
var saddle: Node3D
var tail_nodes: Array = []
var tail_p: Array = []
var tail_pp: Array = []
var legs: Array = []
var wing_mi: MeshInstance3D
var wing_mesh: ImmediateMesh
var D := {}                 # oyuncunun ejderhası (düğümler)
var _wm: ImmediateMesh      # kanat üretilirken hedef mesh
const TAIL_N := 14
const TAIL_L := 0.88
var DS := 2.2               # ejderha ölçeği (türe göre değişir)
var SK := 1.0               # DS / 2.2 — boyuta bağlı mesafeler için

# ---------------------------------------------------------------- ejderha türleri
var cur_species := 0
var SPECIES: Array = [
	{"name": "Kızıl Alev", "desc": "Dengeli, ateş püskürtür",
	 "top_a": Color(0.50, 0.06, 0.035), "top_b": Color(0.17, 0.02, 0.015), "belly": Color(0.86, 0.58, 0.26),
	 "mem": Color(0.42, 0.07, 0.045), "vein": Color(0.13, 0.02, 0.015), "horn": Color(0.85, 0.8, 0.68),
	 "eye": Color(1.0, 0.65, 0.1), "glow": Color(1.0, 0.38, 0.14),
	 "scale": 2.2, "span": 1.0, "bulk": 1.0, "neck": 7, "horn_k": 1.0, "spike": 1.0,
	 "lift": 1.0, "thrust": 1.0, "drag": 1.0, "turn": 1.0, "stam": 1.0, "run": 1.0, "roar": 1.0,
	 "breath": "fire", "fire": [Color(6.0, 5.0, 3.0), Color(5.0, 2.4, 0.5), Color(2.4, 0.6, 0.08)], "light": Color(1.0, 0.55, 0.2)},
	{"name": "Buz Rüzgârı", "desc": "En hızlı ve çevik, buz nefesi ağaçları dondurur",
	 "top_a": Color(0.55, 0.72, 0.85), "top_b": Color(0.13, 0.22, 0.38), "belly": Color(0.9, 0.95, 1.0),
	 "mem": Color(0.45, 0.65, 0.85), "vein": Color(0.12, 0.2, 0.35), "horn": Color(0.95, 0.97, 1.0),
	 "eye": Color(0.3, 0.85, 1.0), "glow": Color(0.35, 0.75, 1.0),
	 "scale": 1.85, "span": 1.15, "bulk": 0.82, "neck": 8, "horn_k": 1.25, "spike": 0.8,
	 "lift": 1.08, "thrust": 1.3, "drag": 0.85, "turn": 1.35, "stam": 0.85, "run": 1.15, "roar": 1.3,
	 "breath": "ice", "fire": [Color(4.0, 5.0, 6.0), Color(1.6, 3.0, 5.0), Color(0.6, 1.2, 2.4)], "light": Color(0.5, 0.8, 1.0)},
	{"name": "Zümrüt Dev", "desc": "Dev ve güçlü, yavaş ama dayanıklı, zehirli yeşil alev",
	 "top_a": Color(0.16, 0.42, 0.12), "top_b": Color(0.04, 0.12, 0.04), "belly": Color(0.78, 0.72, 0.38),
	 "mem": Color(0.2, 0.36, 0.12), "vein": Color(0.05, 0.12, 0.04), "horn": Color(0.55, 0.45, 0.3),
	 "eye": Color(1.0, 0.9, 0.2), "glow": Color(0.55, 0.9, 0.25),
	 "scale": 2.9, "span": 0.92, "bulk": 1.25, "neck": 6, "horn_k": 0.8, "spike": 1.5,
	 "lift": 0.95, "thrust": 0.85, "drag": 1.12, "turn": 0.7, "stam": 0.6, "run": 0.9, "roar": 0.7,
	 "breath": "fire", "fire": [Color(4.0, 6.0, 3.0), Color(1.6, 4.0, 0.6), Color(0.5, 1.8, 0.15)], "light": Color(0.5, 1.0, 0.3)},
	{"name": "Gölge Gece", "desc": "Gece renkli, çok çevik, mor alev",
	 "top_a": Color(0.20, 0.12, 0.32), "top_b": Color(0.03, 0.02, 0.05), "belly": Color(0.45, 0.3, 0.55),
	 "mem": Color(0.18, 0.08, 0.28), "vein": Color(0.04, 0.02, 0.06), "horn": Color(0.25, 0.22, 0.28),
	 "eye": Color(0.85, 0.3, 1.0), "glow": Color(0.6, 0.25, 1.0),
	 "scale": 2.35, "span": 1.08, "bulk": 0.92, "neck": 7, "horn_k": 1.4, "spike": 1.2,
	 "lift": 1.02, "thrust": 1.12, "drag": 0.95, "turn": 1.2, "stam": 0.9, "run": 1.05, "roar": 0.85,
	 "breath": "fire", "fire": [Color(5.0, 4.0, 6.0), Color(3.0, 1.0, 5.0), Color(1.2, 0.2, 2.4)], "light": Color(0.7, 0.35, 1.0)},
]

func sp() -> Dictionary:
	return SPECIES[cur_species]

# animasyon durumu
var flap_ph := 0.0
var flap_amp := 0.15
var flap_freq := 1.0
var wing_fold := 0.0
var wing_sweep := 0.0
var leg_tuck := 1.0
var walk_ph := 0.0
var walk_amt := 0.0
var jaw_open := 0.0
var look_yaw := 0.0
var look_pitch := 0.0
var neck_raise := 0.0


func _plain(c: Color) -> Color:
	return Color(c.r, c.g, c.b, 0.0)


func _species_mats(s: Dictionary) -> Array:
	var dm := ShaderMaterial.new()
	dm.shader = _dragon_shader
	dm.set_shader_parameter("top_a", s.top_a)
	dm.set_shader_parameter("top_b", s.top_b)
	dm.set_shader_parameter("belly", s.belly)
	var mm := ShaderMaterial.new()
	mm.shader = _membrane_shader
	mm.set_shader_parameter("mcol", s.mem)
	mm.set_shader_parameter("vcol", s.vein)
	mm.set_shader_parameter("glow", s.glow)
	return [dm, mm]


var _dragon_shader: Shader
var _membrane_shader: Shader

func _build_dragon() -> void:
	cur_species = clampi(int(settings.species), 0, SPECIES.size() - 1)
	_dragon_shader = _shader(DRAGON_SHADER)
	_membrane_shader = _shader(MEMBRANE_SHADER)
	_apply_dragon(_make_dragon(cur_species, false))
	for i in TAIL_N + 1:
		tail_p.append(Vector3.ZERO)
		tail_pp.append(Vector3.ZERO)


func _apply_dragon(d: Dictionary) -> void:
	D = d
	dragon = d.root
	dbody = d.body
	dragon_mat = d.mat
	membrane_mat = d.mem
	bone_mat = d.mat
	neck = d.neck
	dhead = d.head
	djaw = d.jaw
	dmouth = d.mouth
	saddle = d.saddle
	tail_nodes = d.tail
	legs = d.legs
	wing_mi = d.wing_mi
	wing_mesh = d.wing
	var s := sp()
	DS = s.scale
	SK = DS / 2.2
	STAND_H = 2.7 * DS


# Ejderha düğüm ağacını kurar. wild=true: kuyruk hiyerarşik (fizik yok), gökte uçan yabani ejderhalar için.
func _make_dragon(si: int, wild: bool) -> Dictionary:
	var s: Dictionary = SPECIES[si]
	var mats := _species_mats(s)
	var mat: ShaderMaterial = mats[0]
	var d := {"mat": mat, "mem": mats[1], "species": si, "span": s.span, "neck": [], "tail": [], "legs": []}
	var root := Node3D.new()
	root.name = "Ejderha"
	add_child(root)
	var body := Node3D.new()
	root.add_child(body)
	d.root = root
	d.body = body
	var bk: float = s.bulk
	var hk: float = s.horn_k
	var spk: float = s.spike
	var skin := Color(1, 1, 1, 1)
	var horn := _plain(s.horn)
	var dark := _plain(s.top_b.darkened(0.3))
	# --- gövde
	_mb_begin()
	_mb_ellipsoid(_xf(Vector3(0, 0, 0.2)), Vector3(1.25 * bk, 1.12 * bk, 2.45), 12, 18, skin)
	_mb_ellipsoid(_xf(Vector3(0, 0.22, -1.45)), Vector3(1.32 * bk, 1.3 * bk, 1.55), 10, 16, skin)
	_mb_ellipsoid(_xf(Vector3(0, 0.06, 1.95)), Vector3(1.05 * bk, 1.0 * bk, 1.45), 10, 16, skin)
	for side in [-1.0, 1.0]:
		_mb_ellipsoid(_xf(Vector3(side * 0.95 * bk, 0.6, -1.15), Vector3(0, 0, side * 0.4)), Vector3(0.55, 0.5, 0.7) * bk, 6, 10, skin)
		_mb_ellipsoid(_xf(Vector3(side * 0.85 * bk, -0.25, 1.75)), Vector3(0.55, 0.75, 0.85) * bk, 6, 10, skin)
		_mb_ellipsoid(_xf(Vector3(side * 0.9 * bk, -0.2, -1.35)), Vector3(0.45, 0.6, 0.6) * bk, 6, 10, skin)
	for i in 11:
		var z := -2.3 + i * 0.52
		var top := (1.1 - absf(z + 0.5) * 0.1) * bk
		var sz := (0.42 - absf(z - 0.2) * 0.05) * spk
		if z < -1.7 and z > -2.4 and not wild:
			continue
		_mb_cyl(_xf(Vector3(0, top, z), Vector3(0.55, 0, 0)), sz * 0.45, 0.0, sz * 1.5, 5, dark, horn)
	if not wild:
		var leather := _plain(Color(0.33, 0.18, 0.08))
		var sy := 1.38 * bk
		_mb_box(_xf(Vector3(0, sy, -1.85), Vector3(-0.15, 0, 0)), Vector3(1.0, 0.25, 1.25), leather)
		_mb_box(_xf(Vector3(0, sy + 0.24, -2.42), Vector3(-0.15, 0, 0)), Vector3(0.5, 0.45, 0.2), leather)
		_mb_box(_xf(Vector3(0, sy + 0.17, -1.25), Vector3(-0.15, 0, 0)), Vector3(0.9, 0.35, 0.18), leather)
		for side in [-1.0, 1.0]:
			_mb_box(_xf(Vector3(side * 1.15 * bk, 0.7 * bk, -1.85), Vector3(0, 0, side * 0.45)), Vector3(0.12, 1.4 * bk, 0.18), leather)
			_mb_box(_xf(Vector3(side * 1.25 * bk, 0.05, -1.75)), Vector3(0.18, 0.3, 0.5), _plain(Color(0.7, 0.6, 0.35)))
	var body_mi := MeshInstance3D.new()
	body_mi.mesh = _mb_mesh(mat)
	body.add_child(body_mi)
	var sad := Node3D.new()
	sad.position = Vector3(0, 1.5 * bk, -1.85)
	body.add_child(sad)
	d.saddle = sad
	# --- boyun
	var parent: Node3D = body
	var off := Vector3(0, 0.75 * bk, -2.45)
	var nn: int = s.neck
	for i in nn:
		var j := Node3D.new()
		j.position = off
		parent.add_child(j)
		var r := (0.78 - i * 0.055 * 7.0 / nn) * lerpf(1.0, bk, 0.6)
		_mb_begin()
		_mb_ellipsoid(_xf(Vector3(0, 0, -0.4)), Vector3(r, r * 0.95, 0.62), 8, 12, skin)
		_mb_cyl(_xf(Vector3(0, r * 0.85, -0.4), Vector3(0.6, 0, 0)), 0.14 * spk, 0.0, (0.42 - i * 0.03) * spk, 5, dark, horn)
		var mi := MeshInstance3D.new()
		mi.mesh = _mb_mesh(mat)
		j.add_child(mi)
		d.neck.append(j)
		parent = j
		off = Vector3(0, 0, -0.78)
	# --- kafa
	var head := Node3D.new()
	head.position = Vector3(0, 0.05, -0.75)
	head.scale = Vector3(1.3, 1.3, 1.3)
	parent.add_child(head)
	d.head = head
	_mb_begin()
	_mb_ellipsoid(_xf(Vector3(0, 0.1, -0.35)), Vector3(0.55, 0.46, 0.75), 10, 14, skin)
	_mb_ellipsoid(_xf(Vector3(0, 0.0, -1.1)), Vector3(0.38, 0.28, 0.75), 8, 12, skin)
	for side in [-1.0, 1.0]:
		_mb_ellipsoid(_xf(Vector3(side * 0.3, 0.32, -0.55)), Vector3(0.15, 0.1, 0.35), 5, 8, skin)
		_mb_cyl(_xf(Vector3(side * 0.28, 0.35, -0.05), Vector3(1.9, 0, side * 0.35)), 0.11 * hk, 0.0, 1.35 * hk, 6, horn.darkened(0.2), horn)
		_mb_cyl(_xf(Vector3(side * 0.38, 0.15, 0.05), Vector3(2.0, 0, side * 0.9)), 0.07 * hk, 0.0, 0.7 * hk, 5, horn.darkened(0.2), horn)
		_mb_cyl(_xf(Vector3(side * 0.15, 0.12, -1.75), Vector3(-0.3, 0, 0)), 0.04, 0.0, 0.14, 4, dark, dark)
		for k in 3:
			_mb_cyl(_xf(Vector3(side * 0.5, -0.05 - k * 0.12, -0.15), Vector3(1.6, 0, side * (1.3 + k * 0.2))), 0.06 * spk, 0.0, (0.5 - k * 0.1) * spk, 4, dark, horn)
	if si == 1:
		# buz ejderhasına taç gibi ek boynuzlar
		for k in 5:
			var a := -0.6 + k * 0.3
			_mb_cyl(_xf(Vector3(sin(a) * 0.35, 0.42, -0.2 + cos(a) * 0.05), Vector3(1.4, 0, a * 0.6)), 0.05, 0.0, 0.55, 4, horn, horn)
	for k in 6:
		_mb_cyl(_xf(Vector3(0.25 if k % 2 == 0 else -0.25, -0.12, -1.75 + k * 0.12), Vector3(PI, 0, 0)), 0.035, 0.0, 0.12, 4, horn, horn)
	var head_mi := MeshInstance3D.new()
	head_mi.mesh = _mb_mesh(mat)
	head.add_child(head_mi)
	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = s.eye
	eye_mat.emission_enabled = true
	eye_mat.emission = s.eye
	eye_mat.emission_energy_multiplier = 3.0
	for side in [-1.0, 1.0]:
		var e := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.085
		sm.height = 0.13
		sm.material = eye_mat
		e.mesh = sm
		e.position = Vector3(side * 0.4, 0.22, -0.55)
		head.add_child(e)
	var jaw := Node3D.new()
	jaw.position = Vector3(0, -0.18, -0.15)
	head.add_child(jaw)
	d.jaw = jaw
	_mb_begin()
	_mb_ellipsoid(_xf(Vector3(0, -0.12, -0.85)), Vector3(0.32, 0.14, 0.85), 6, 10, skin)
	for k in 6:
		_mb_cyl(_xf(Vector3(0.22 if k % 2 == 0 else -0.22, 0.0, -1.45 + k * 0.13)), 0.03, 0.0, 0.11, 4, horn, horn)
	_mb_ellipsoid(_xf(Vector3(0, -0.02, -0.75)), Vector3(0.14, 0.04, 0.6), 4, 6, _plain(Color(0.5, 0.08, 0.12)))
	var jaw_mi := MeshInstance3D.new()
	jaw_mi.mesh = _mb_mesh(mat)
	jaw.add_child(jaw_mi)
	var mouth := Node3D.new()
	mouth.position = Vector3(0, -0.12, -1.85)
	head.add_child(mouth)
	d.mouth = mouth
	# --- kuyruk
	var tparent: Node3D = body
	for i in TAIL_N:
		var r: float = lerpf(0.85 * bk, 0.12, float(i) / TAIL_N)
		_mb_begin()
		_mb_ellipsoid(_xf(Vector3(0, 0, -TAIL_L * 0.5)), Vector3(r, r * 0.92, TAIL_L * 0.68), 6, 10, skin)
		_mb_cyl(_xf(Vector3(0, r * 0.85, -TAIL_L * 0.5), Vector3(-0.6, 0, 0)), r * 0.25 * spk, 0.0, (r * 0.75 + 0.1) * spk, 4, dark, horn)
		if i == TAIL_N - 1:
			_mb_ellipsoid(_xf(Vector3(0, 0, -TAIL_L - 0.5)), Vector3(0.7, 0.07, 0.65), 4, 8, dark.lightened(0.15))
		var mi := MeshInstance3D.new()
		mi.mesh = _mb_mesh(mat)
		if wild:
			# kuyruk düğümleri zincir: her biri arkaya bakar
			var tn := Node3D.new()
			tn.position = Vector3(0, 0.2, 3.05) if i == 0 else Vector3(0, 0, TAIL_L)
			tparent.add_child(tn)
			mi.rotation = Vector3(0, PI, 0)
			tn.add_child(mi)
			d.tail.append(tn)
			tparent = tn
		else:
			mi.top_level = true
			root.add_child(mi)
			d.tail.append(mi)
	# --- bacaklar
	var hips_p := [Vector3(-0.95, -0.5, -1.35), Vector3(0.95, -0.5, -1.35), Vector3(-0.9, -0.4, 1.75), Vector3(0.9, -0.4, 1.75)]
	for li in 4:
		var front := li < 2
		var l1 := 1.25 if front else 1.4
		var l2 := 1.15 if front else 1.3
		var hip := Node3D.new()
		hip.position = Vector3(hips_p[li].x * bk, hips_p[li].y * bk, hips_p[li].z)
		body.add_child(hip)
		_mb_begin()
		_mb_ellipsoid(_xf(Vector3(0, -l1 * 0.45, 0)), Vector3(0.36 * bk, l1 * 0.6, 0.42 * bk), 6, 10, skin)
		var m1 := MeshInstance3D.new()
		m1.mesh = _mb_mesh(mat)
		hip.add_child(m1)
		var knee := Node3D.new()
		knee.position = Vector3(0, -l1, 0)
		hip.add_child(knee)
		_mb_begin()
		_mb_ellipsoid(_xf(Vector3(0, -l2 * 0.5, 0)), Vector3(0.22 * bk, l2 * 0.58, 0.25 * bk), 6, 8, skin)
		_mb_ellipsoid(_xf(Vector3(0, -l2 - 0.05, -0.25)), Vector3(0.3, 0.15, 0.45) * bk, 5, 8, skin)
		for k in 3:
			_mb_cyl(_xf(Vector3((k - 1) * 0.16 * bk, -l2 - 0.08, -0.6), Vector3(-1.6, 0, 0)), 0.06, 0.0, 0.32, 4, dark, horn)
		var m2 := MeshInstance3D.new()
		m2.mesh = _mb_mesh(mat)
		knee.add_child(m2)
		d.legs.append({"hip": hip, "knee": knee, "front": front, "side": -1.0 if li % 2 == 0 else 1.0})
	# --- kanatlar
	var wm := ImmediateMesh.new()
	var wmi := MeshInstance3D.new()
	wmi.mesh = wm
	wmi.custom_aabb = AABB(Vector3(-28, -18, -18), Vector3(56, 36, 36))
	body.add_child(wmi)
	d.wing = wm
	d.wing_mi = wmi
	return d


func _reset_tail() -> void:
	var b := d_basis
	for i in TAIL_N + 1:
		var p := d_pos + b * (Vector3(0, 0.2, 3.1 + i * TAIL_L) * DS)
		tail_p[i] = p
		tail_pp[i] = p


# ---------------------------------------------------------------- kanat kinematiği
func _wing_pts(ph: float, amp: float, f: float, sweep: float, span: float) -> Dictionary:
	var e := sin(ph + 0.35 * sin(ph)) * amp
	var e_lag := sin(ph - 0.7 + 0.35 * sin(ph - 0.7)) * amp
	var e_lag2 := sin(ph - 1.3) * amp
	var dihedral := 0.1 * (1.0 - f)
	var S := Vector3(0.95, 0.95, -1.15)
	var a_el: float = lerpf(e + dihedral, 0.4, f)
	var a_sw: float = lerpf(0.12 + sweep * 0.6, -1.15, f)
	var arm := Vector3(1, 0, 0).rotated(Vector3(0, 0, 1), a_el).rotated(Vector3.UP, a_sw)
	var E := S + arm * 3.0 * span
	var f_el: float = lerpf(e_lag * 0.9 + dihedral, -0.35, f)
	var f_sw: float = lerpf(-0.05 + sweep * 0.5, 1.6, f)
	var fore := Vector3(1, 0, 0).rotated(Vector3(0, 0, 1), f_el).rotated(Vector3.UP, f_sw)
	var W := E + fore * 4.2 * span
	var fa_open := [0.28, -0.12, -0.55, -1.0]
	var fl := [7.0, 6.6, 5.6, 4.4]
	var F := []
	for k in 4:
		var ang: float = lerpf(fa_open[k] + sweep * 0.4, -1.5 - k * 0.05, f)
		var el: float = lerpf(e_lag2 * 0.8 - 0.04 * k + dihedral * 0.5, -0.25 - k * 0.04, f)
		var dd := Vector3(1, 0, 0).rotated(Vector3(0, 0, 1), el).rotated(Vector3.UP, ang)
		F.append(W + dd * fl[k] * span * lerpf(1.0, 0.92, f))
	var H := Vector3(0.75, 0.55, 2.05)
	var lift: float = (0.6 - 0.9 * cos(ph)) * (1.0 - f) * amp + 0.15 * (1.0 - f)
	return {"S": S, "E": E, "W": W, "F": F, "H": H, "lift": lift}


func _wing_emit_tri(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3, ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	var face := (c - a).cross(b - a)
	if face.dot(na + nb + nc) < 0.0:
		var t := b
		b = c
		c = t
		var tn := nb
		nb = nc
		nc = tn
		var tu := ub
		ub = uc
		uc = tu
	_wm.surface_set_normal(na)
	_wm.surface_set_uv(ua)
	_wm.surface_add_vertex(a)
	_wm.surface_set_normal(nb)
	_wm.surface_set_uv(ub)
	_wm.surface_add_vertex(b)
	_wm.surface_set_normal(nc)
	_wm.surface_set_uv(uc)
	_wm.surface_add_vertex(c)


func _panel(W: Vector3, A: Vector3, B: Vector3, bulge: float, mir: float, scallop := 0.2, R := 4, C := 4) -> void:
	var span := A.distance_to(B)
	var up := Vector3(0, 1, 0)
	var g := []
	for i in R + 1:
		var row := []
		for j in C + 1:
			var s := float(i) / R
			var t := float(j) / C
			var spf := s * (1.0 - scallop * sin(PI * t) * s)
			var p := W + (A.lerp(B, t) - W) * spf
			p += up * sin(PI * t) * pow(sin(PI * minf(s, 0.999) * 0.5 + 0.0001), 0.8) * bulge * span * 0.13
			row.append(p)
		g.append(row)
	var nrm := []
	for i in R + 1:
		var row := []
		for j in C + 1:
			var a: Vector3 = g[mini(i + 1, R)][j] - g[maxi(i - 1, 0)][j]
			var b: Vector3 = g[i][mini(j + 1, C)] - g[i][maxi(j - 1, 0)]
			var n := a.cross(b).normalized()
			if n.dot(up) < 0.0:
				n = -n
			row.append(n)
		nrm.append(row)
	var m := Vector3(mir, 1, 1)
	for i in R:
		for j in C:
			var p00: Vector3 = g[i][j]
			var p10: Vector3 = g[i + 1][j]
			var p11: Vector3 = g[i + 1][j + 1]
			var p01: Vector3 = g[i][j + 1]
			var u00 := Vector2(float(i) / R, float(j) / C)
			var u10 := Vector2(float(i + 1) / R, float(j) / C)
			var u11 := Vector2(float(i + 1) / R, float(j + 1) / C)
			var u01 := Vector2(float(i) / R, float(j + 1) / C)
			var n00: Vector3 = nrm[i][j]
			var n10: Vector3 = nrm[i + 1][j]
			var n11: Vector3 = nrm[i + 1][j + 1]
			var n01: Vector3 = nrm[i][j + 1]
			_wing_emit_tri(p00 * m, p10 * m, p11 * m, n00 * m, n10 * m, n11 * m, u00, u10, u11)
			_wing_emit_tri(p00 * m, p11 * m, p01 * m, n00 * m, n11 * m, n01 * m, u00, u11, u01)


func _bone(a: Vector3, b: Vector3, r0: float, r1: float, mir: float, n := 6) -> void:
	var d := (b - a).normalized()
	var side := d.cross(Vector3.UP)
	if side.length() < 0.01:
		side = d.cross(Vector3.RIGHT)
	side = side.normalized()
	var up := side.cross(d).normalized()
	var m := Vector3(mir, 1, 1)
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		var o0 := side * cos(a0) + up * sin(a0)
		var o1 := side * cos(a1) + up * sin(a1)
		var q0 := (a + o0 * r0) * m
		var q1 := (a + o1 * r0) * m
		var q2 := (b + o1 * r1) * m
		var q3 := (b + o0 * r1) * m
		var nn0 := o0 * m
		var nn1 := o1 * m
		_wing_emit_tri(q0, q1, q2, nn0, nn1, nn1, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
		_wing_emit_tri(q0, q2, q3, nn0, nn1, nn0, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)


func _wings_build(d: Dictionary, ph: float, amp: float, fold: float, sweep: float, lod := 0) -> void:
	var wp := _wing_pts(ph, amp, fold, sweep, d.span)
	var S: Vector3 = wp.S
	var E: Vector3 = wp.E
	var W: Vector3 = wp.W
	var F: Array = wp.F
	var H: Vector3 = wp.H
	var bul: float = wp.lift
	var q := 4 if lod == 0 else 2
	_wm = d.wing
	_wm.clear_surfaces()
	_wm.surface_begin(Mesh.PRIMITIVE_TRIANGLES, d.mem)
	for mir in [1.0, -1.0]:
		_panel(W, F[0], F[1], bul, mir, 0.2, q, q)
		_panel(W, F[1], F[2], bul, mir, 0.2, q, q)
		_panel(W, F[2], F[3], bul, mir, 0.2, q, q)
		_panel(W, F[3], H, bul * 1.2, mir, 0.12, q, q)
		_panel(W, H, E, bul * 0.5, mir, 0.05, q, q)
		_panel(S, E, H, bul * 0.3, mir, 0.0, 2, 2)
		_panel(S, W, E, 0.0, mir, 0.0, 2, 2)
	_wm.surface_end()
	_wm.surface_begin(Mesh.PRIMITIVE_TRIANGLES, d.mat)
	var bn := 6 if lod == 0 else 4
	for mir in [1.0, -1.0]:
		_bone(S, E, 0.36, 0.24, mir, bn)
		_bone(E, W, 0.24, 0.17, mir, bn)
		for k in 4:
			_bone(W, F[k], 0.12, 0.035, mir, bn)
		_bone(W, W + (W - E).normalized() * 0.9 + Vector3(0, 0.3, 0), 0.13, 0.02, mir, bn)
	_wm.surface_end()


func _update_wings() -> void:
	_wings_build(D, flap_ph, flap_amp, wing_fold, wing_sweep)


# ---------------------------------------------------------------- tür değiştirme
func _set_species(si: int) -> void:
	if si == cur_species or calling:
		return
	var old: Node3D = dragon
	fire_p.get_parent().remove_child(fire_p)
	fire_light.get_parent().remove_child(fire_light)
	cur_species = si
	_apply_dragon(_make_dragon(si, false))
	dmouth.add_child(fire_p)
	dmouth.add_child(fire_light)
	old.queue_free()
	_apply_breath()
	if d_state != "ucus":
		d_pos.y = max(h_at(d_pos.x, d_pos.z), water_at(d_pos.x, d_pos.z)) + STAND_H
	dragon.global_transform = Transform3D(d_basis.scaled(Vector3(DS, DS, DS)), d_pos)
	_reset_tail()
	wing_fold = 1.0 if d_state == "yer" else 0.0
	neck_raise = 1.0 if d_state == "yer" else 0.0
	cam_dist = clampf(34.0 * SK, 16.0, 90.0)
	_dust(Vector3(d_pos.x, h_at(d_pos.x, d_pos.z), d_pos.z), 1.0)
	_play2d("roar", 0.0, sp().roar)
	_msg("%s  —  %s" % [sp().name, sp().desc], 3.0)
	settings.species = si
	_save_settings()


func _apply_breath() -> void:
	var s := sp()
	var pm: ParticleProcessMaterial = fire_p.process_material
	var c: Array = s.fire
	pm.color_ramp = _ramp([
		[0.0, Color(c[0].r, c[0].g, c[0].b, 1.0)],
		[0.12, Color(c[1].r, c[1].g, c[1].b, 1.0)],
		[0.38, Color(c[2].r, c[2].g, c[2].b, 0.85)],
		[0.6, Color(0.25, 0.22, 0.25, 0.5) if s.breath == "fire" else Color(0.8, 0.9, 1.0, 0.4)],
		[1.0, Color(0.08, 0.08, 0.08, 0.0) if s.breath == "fire" else Color(0.9, 0.95, 1.0, 0.0)]])
	pm.gravity = Vector3(0, 5.0, 0) if s.breath == "fire" else Vector3(0, -3.0, 0)
	fire_light.light_color = s.light
	pm.initial_velocity_min = 56.0 * SK
	pm.initial_velocity_max = 70.0 * SK
	pm.scale_min = 1.6 * SK
	pm.scale_max = 3.2 * SK


# ============================================================================
#  YABANİ EJDERHALAR — gökyüzünde süzülen diğer türler
# ============================================================================
var wilds: Array = []

func _build_wilds() -> void:
	var order := [1, 2, 3, 0, 1, 2]
	for i in order.size():
		var si: int = order[i]
		var d := _make_dragon(si, true)
		var s: Dictionary = SPECIES[si]
		var sc: float = s.scale * 1.05
		d.root.scale = Vector3(sc, sc, sc)
		# sabit uçuş pozu
		for j in d.neck.size():
			d.neck[j].rotation = Vector3([0.16, 0.1, 0.04, -0.02, -0.06, -0.1, -0.06, -0.06, -0.04][j], 0, 0)
		d.head.rotation = Vector3(-0.1, 0, 0)
		for L in d.legs:
			L.hip.rotation.x = -1.25 if L.front else -1.05
			L.knee.rotation.x = 1.6 if L.front else -0.93
		var c := Vector2(rng.randf_range(0.2, 0.8), rng.randf_range(0.2, 0.8)) * WORLD
		var w := {"d": d, "c": c, "rx": rng.randf_range(450, 1100), "rz": rng.randf_range(450, 1100),
			"ph": rng.randf() * TAU, "sp": rng.randf_range(0.022, 0.035) * (1.0 if rng.randf() < 0.5 else -1.0),
			"alt": rng.randf_range(180, 420), "flap": rng.randf() * TAU, "pos": Vector3.ZERO, "prev": Vector3.ZERO,
			"bank": 0.0, "roar_t": rng.randf_range(5, 20), "seen": false, "lod_t": 0.0, "amp": 0.6, "y": 0.0}
		wilds.append(w)
		_update_wild(w, 0.0, true)


func _update_wild(w: Dictionary, delta: float, force := false) -> void:
	w.ph += w.sp * delta * (2.2 / w.d.root.scale.x)
	var t: float = w.ph
	var c: Vector2 = w.c
	var p := Vector3(c.x + cos(t) * w.rx, 0, c.y + sin(t * 1.0) * w.rz + sin(t * 2.0) * w.rz * 0.25)
	p.x = clampf(p.x, 200.0, WORLD - 200.0)
	p.z = clampf(p.z, 200.0, WORLD - 200.0)
	var gh: float = maxf(maxf(h_at(p.x, p.z), h_at(p.x + 120.0, p.z)), maxf(h_at(p.x, p.z + 120.0), h_at(p.x - 120.0, p.z - 120.0)))
	var ty: float = maxf(gh, WATER_Y) + w.alt + sin(t * 3.0) * 60.0
	if force:
		w.y = ty
	w.y = lerpf(w.y, ty, clampf(delta * 0.6, 0.0, 1.0))
	p.y = w.y
	var vel: Vector3 = (p - w.pos) / maxf(delta, 0.001)
	w.prev = w.pos
	w.pos = p
	if force or vel.length() < 0.5:
		vel = Vector3(-sin(t) * w.rx, 0, cos(t) * w.rz) * w.sp
	var fwd := vel.normalized()
	if fwd.length() < 0.5:
		fwd = Vector3(0, 0, -1)
	var yaw_rate: float = w.sp * 2.0
	w.bank = lerpf(w.bank, clampf(-yaw_rate * 25.0, -0.6, 0.6), clampf(delta, 0.0, 1.0))
	var climb := clampf(vel.y / 25.0, -1.0, 1.0)
	var b := Basis.looking_at(fwd, Vector3.UP) * Basis(Vector3(0, 0, 1), w.bank)
	var sc: float = w.d.root.scale.x
	w.d.root.global_transform = Transform3D(b.scaled(Vector3(sc, sc, sc)), p)
	# görünürlük ve kanat LOD
	var cd := cam.global_position.distance_to(p) if cam else 0.0
	w.d.root.visible = cd < 5200.0
	if not w.d.root.visible:
		return
	w.amp = lerpf(w.amp, 0.95 if climb > 0.15 else (0.35 + 0.25 * sin(t * 5.0)), clampf(delta, 0.0, 1.0))
	w.flap += delta * TAU * (1.1 if w.amp > 0.6 else 0.6)
	w.lod_t -= delta
	if force or w.lod_t <= 0.0:
		var lod := 0 if cd < 700.0 else 1
		w.lod_t = 0.0 if cd < 700.0 else (0.05 if cd < 1800.0 else 0.15)
		_wings_build(w.d, w.flap, w.amp, 0.0, 0.0, lod)
	if cd < 1500.0:
		for i in w.d.tail.size():
			w.d.tail[i].rotation = Vector3(0.02, sin(game_time * 2.2 - i * 0.5) * 0.06, 0)
	w.roar_t -= delta
	if w.roar_t <= 0.0:
		w.roar_t = rng.randf_range(12, 30)
		if cd < 900.0:
			_play3d("roar", p, -2.0, SPECIES[w.d.species].roar * 0.95)
	if not w.seen and cd < 260.0:
		w.seen = true
		_msg("Yabani bir %s gördün!  (1-4 tuşlarıyla tür seçebilirsin)" % SPECIES[w.d.species].name, 3.5)


# ---------------------------------------------------------------- kuyruk fiziği (verlet)
func _update_tail(delta: float, sway: float) -> void:
	var b := (dragon.global_transform.basis * dbody.transform.basis).orthonormalized()
	var root := dbody.global_transform * Vector3(0, 0.2, 3.05)
	tail_p[0] = root
	tail_pp[0] = root
	var back := b * Vector3(0, 0, 1)
	var dt2: float = delta * delta
	for i in range(1, TAIL_N + 1):
		var p: Vector3 = tail_p[i]
		var v: Vector3 = (p - tail_pp[i]) * 0.94
		tail_pp[i] = p
		p += v + Vector3(0, -6.0, 0) * dt2
		var prev: Vector3 = tail_p[i - 1]
		var pdir: Vector3 = back if i == 1 else (prev - tail_p[i - 2]).normalized()
		var wave := b * Vector3(1, 0, 0) * sin(game_time * 3.0 - i * 0.45) * sway
		var rest: Vector3 = (pdir.lerp(back, 0.25) + wave).normalized()
		p = p.lerp(prev + rest * TAIL_L * DS, clamp(delta * 14.0, 0.0, 1.0))
		var gh := h_at(p.x, p.z) + 0.25
		if p.y < gh:
			p.y = gh
		p = prev + (p - prev).normalized() * TAIL_L * DS
		tail_p[i] = p
	var upv := b * Vector3.UP
	for i in TAIL_N:
		var a: Vector3 = tail_p[i]
		var c: Vector3 = tail_p[i + 1]
		var d := c - a
		if d.length() < 0.001:
			continue
		var dn := d.normalized()
		var uh := upv
		if absf(dn.dot(uh)) > 0.9:
			uh = b * Vector3(0, 0, -1)
		var bas := Basis.looking_at(dn, uh).scaled(Vector3(DS, DS, DS))
		tail_nodes[i].global_transform = Transform3D(bas, a)


# ---------------------------------------------------------------- iskelet pozları
func _update_pose(delta: float) -> void:
	var tall := [0.62, 0.42, 0.2, 0.0, -0.22, -0.36, -0.3]
	var flat := [0.16, 0.1, 0.04, -0.02, -0.06, -0.1, -0.06]
	var nr := neck_raise * (1.0 - 0.35 * clampf(walk_amt, 0.0, 1.0))
	var breath := sin(game_time * 1.3) * 0.02
	for i in neck.size():
		var j: Node3D = neck[i]
		var bob: float = sin(flap_ph - 0.9 - i * 0.25) * flap_amp * 0.06 * (1.0 - wing_fold)
		var ii := int(round(i * 6.0 / maxf(neck.size() - 1, 1)))
		var kk := 7.0 / neck.size()
		j.rotation = Vector3(lerpf(flat[ii], tall[ii], nr) * kk + look_pitch / neck.size() + bob + breath, look_yaw / neck.size(), 0.0)
	dhead.rotation = Vector3(-0.1 - look_pitch * 0.2 - nr * 0.1, 0, 0)
	djaw.rotation.x = -jaw_open * 0.55
	for L in legs:
		var hip: Node3D = L.hip
		var knee: Node3D = L.knee
		var ph: float = walk_ph + (0.0 if (L.side < 0) == L.front else PI)
		var swing := sin(ph) * 0.55 * walk_amt
		var lift: float = max(0.0, cos(ph)) * 0.7 * walk_amt
		var tuck_h := -1.25 if L.front else -1.05
		var tuck_k := 1.6 if L.front else 1.7
		hip.rotation.x = lerp(swing + (0.1 if L.front else -0.15), tuck_h, leg_tuck)
		knee.rotation.x = lerp(lift * (1.0 if L.front else -1.0) + (-0.25 if L.front else 0.3), tuck_k * (1.0 if L.front else -0.55), leg_tuck)
		hip.rotation.z = L.side * 0.08

# ============================================================================
#  SÜVARİ (binicinin kendisi — ejderhada oturur ya da yürür)
# ============================================================================
var hero: Node3D
var hp := {}
var cape_mesh: ImmediateMesh
var cape_sway := Vector3.ZERO

func _build_rider() -> void:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.7
	hero = Node3D.new()
	hero.name = "Suvari"
	hero.top_level = true
	add_child(hero)
	var skin := Color(0.86, 0.66, 0.52)
	var leather := Color(0.32, 0.2, 0.11)
	var cloth := Color(0.12, 0.25, 0.42)
	var metal := Color(0.62, 0.62, 0.65)
	var pelvis := _hnode(hero, Vector3(0, 0.95, 0), mat, func():
		_mb_ellipsoid(_xf(Vector3(0, 0, 0)), Vector3(0.19, 0.13, 0.13), 5, 8, leather)
		_mb_box(_xf(Vector3(0, 0.06, 0)), Vector3(0.4, 0.08, 0.28), Color(0.2, 0.12, 0.06))
		_mb_box(_xf(Vector3(0, 0.06, -0.14)), Vector3(0.1, 0.08, 0.02), Color(0.85, 0.7, 0.3)))
	var torso := _hnode(pelvis, Vector3(0, 0.08, 0), mat, func():
		_mb_ellipsoid(_xf(Vector3(0, 0.3, 0)), Vector3(0.21, 0.3, 0.14), 6, 10, cloth, cloth.darkened(0.3))
		_mb_ellipsoid(_xf(Vector3(0, 0.38, -0.03)), Vector3(0.2, 0.2, 0.13), 5, 8, metal, metal.darkened(0.3))
		for s in [-1.0, 1.0]:
			_mb_ellipsoid(_xf(Vector3(s * 0.24, 0.55, 0)), Vector3(0.1, 0.07, 0.1), 4, 6, metal, metal.darkened(0.3))
		_mb_cyl(_xf(Vector3(0, 0.58, 0)), 0.06, 0.055, 0.1, 6, skin, skin))
	var head := _hnode(torso, Vector3(0, 0.7, 0), mat, func():
		_mb_ellipsoid(_xf(Vector3(0, 0.08, 0)), Vector3(0.11, 0.13, 0.12), 6, 10, skin)
		_mb_ellipsoid(_xf(Vector3(0, 0.12, 0.01)), Vector3(0.125, 0.11, 0.13), 5, 10, metal, metal.darkened(0.2))
		_mb_box(_xf(Vector3(0, 0.08, -0.12)), Vector3(0.03, 0.1, 0.02), metal)
		for s in [-1.0, 1.0]:
			_mb_cyl(_xf(Vector3(s * 0.11, 0.17, 0), Vector3(0, 0, -s * 1.1)), 0.035, 0.0, 0.16, 5, Color(0.9, 0.86, 0.75), Color(0.9, 0.86, 0.75)))
	hp = {"pelvis": pelvis, "torso": torso, "head": head}
	for s in [-1.0, 1.0]:
		var sh := _hnode(torso, Vector3(s * 0.26, 0.55, 0), mat, func():
			_mb_ellipsoid(_xf(Vector3(0, -0.15, 0)), Vector3(0.065, 0.17, 0.065), 4, 8, cloth))
		var el := _hnode(sh, Vector3(0, -0.31, 0), mat, func():
			_mb_ellipsoid(_xf(Vector3(0, -0.13, 0)), Vector3(0.055, 0.15, 0.055), 4, 8, leather)
			_mb_ellipsoid(_xf(Vector3(0, -0.3, 0)), Vector3(0.05, 0.06, 0.05), 4, 6, leather.darkened(0.3)))
		var hip := _hnode(pelvis, Vector3(s * 0.11, -0.04, 0), mat, func():
			_mb_ellipsoid(_xf(Vector3(0, -0.22, 0)), Vector3(0.085, 0.24, 0.09), 5, 8, leather.lightened(0.15)))
		var kn := _hnode(hip, Vector3(0, -0.45, 0), mat, func():
			_mb_ellipsoid(_xf(Vector3(0, -0.2, 0)), Vector3(0.07, 0.22, 0.072), 5, 8, leather)
			_mb_ellipsoid(_xf(Vector3(0, -0.43, -0.05)), Vector3(0.075, 0.07, 0.14), 4, 8, Color(0.14, 0.09, 0.05)))
		var k := "r" if s > 0 else "l"
		hp["sh_" + k] = sh
		hp["el_" + k] = el
		hp["hip_" + k] = hip
		hp["kn_" + k] = kn
	cape_mesh = ImmediateMesh.new()
	var cm := MeshInstance3D.new()
	cm.mesh = cape_mesh
	cm.custom_aabb = AABB(Vector3(-2, -3, -2), Vector3(4, 5, 4))
	torso.add_child(cm)
	hp["cape_mat"] = StandardMaterial3D.new()
	hp.cape_mat.albedo_color = Color(0.55, 0.06, 0.06)
	hp.cape_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	hp.cape_mat.roughness = 0.85
	hp.cape_mat.backlight_enabled = true
	hp.cape_mat.backlight = Color(0.4, 0.05, 0.05)


func _hnode(parent: Node3D, pos: Vector3, mat: Material, builder: Callable) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	_mb_begin()
	builder.call()
	var mi := MeshInstance3D.new()
	mi.mesh = _mb_mesh(mat)
	n.add_child(mi)
	return n


func _build_walker() -> void:
	pass  # yaya karakter = aynı süvari modeli (hero), poz ve konum fiziği _update_foot içinde


func _pose_hero(sit: bool, ph: float, amt: float, wind: Vector3, delta: float) -> void:
	var pel: Node3D = hp.pelvis
	var tor: Node3D = hp.torso
	if sit:
		pel.position = Vector3(0, 0.0, 0)
		tor.rotation = Vector3(-0.3 - amt * 0.15, 0, 0)
		for k in ["l", "r"]:
			var s := 1.0 if k == "r" else -1.0
			hp["hip_" + k].rotation = Vector3(1.25, 0, s * 0.62)
			hp["kn_" + k].rotation = Vector3(-1.5, 0, 0)
			hp["sh_" + k].rotation = Vector3(0.85, 0, s * 0.15)
			hp["el_" + k].rotation = Vector3(0.6, 0, 0)
	else:
		pel.position = Vector3(0, 0.95 + abs(sin(ph)) * 0.05 * amt, 0)
		tor.rotation = Vector3(-0.08 * amt, sin(ph) * 0.06 * amt, 0)
		for k in ["l", "r"]:
			var s := 1.0 if k == "r" else -1.0
			var p := ph + (0.0 if k == "r" else PI)
			hp["hip_" + k].rotation = Vector3(sin(p) * 0.6 * amt, 0, s * 0.04)
			hp["kn_" + k].rotation = Vector3(-max(0.0, sin(p + 1.3)) * 1.0 * amt - 0.05, 0, 0)
			hp["sh_" + k].rotation = Vector3(-sin(p) * 0.5 * amt, 0, s * 0.12)
			hp["el_" + k].rotation = Vector3(0.25 + 0.3 * amt, 0, 0)
	# pelerin
	var local_wind: Vector3 = tor.global_transform.basis.inverse() * wind
	cape_sway = cape_sway.lerp(local_wind, clamp(delta * 4.0, 0.0, 1.0))
	cape_mesh.clear_surfaces()
	cape_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, hp.cape_mat)
	var rows := 6
	var cols := 4
	var g := []
	for i in rows + 1:
		var t := float(i) / rows
		var row := []
		for j in cols + 1:
			var u := float(j) / cols * 2.0 - 1.0
			var w: float = lerp(0.24, 0.36, t)
			var p := Vector3(u * w, 0.58 - t * 1.05, 0.13 + t * 0.06)
			var flow := Vector3(cape_sway.x * 0.02, cape_sway.y * 0.01, clampf(cape_sway.z * 0.03, -0.6, 2.2))
			p += flow * t * t * 0.6
			p.y += t * t * clamp(cape_sway.z * 0.012, 0.0, 0.9)
			p.x += sin(game_time * 9.0 + t * 5.0 + u) * 0.04 * t * clamp(cape_sway.length() * 0.04, 0.2, 1.5)
			p.z += sin(game_time * 7.0 + t * 4.0 + u * 2.0) * 0.05 * t * clamp(cape_sway.length() * 0.04, 0.2, 1.5)
			row.append(p)
		g.append(row)
	for i in rows:
		for j in cols:
			var a: Vector3 = g[i][j]
			var b: Vector3 = g[i][j + 1]
			var c: Vector3 = g[i + 1][j + 1]
			var d: Vector3 = g[i + 1][j]
			var n := (c - a).cross(b - a).normalized()
			for v in [a, b, c, a, c, d]:
				cape_mesh.surface_set_normal(n)
				cape_mesh.surface_add_vertex(v)
	cape_mesh.surface_end()


# ============================================================================
#  EFEKTLER (ateş, su sıçraması, toz, hız çizgileri, şelale buharı, yangın)
# ============================================================================
var fire_p: GPUParticles3D
var fire_light: OmniLight3D
var spray_p: GPUParticles3D
var splash_p: GPUParticles3D
var dust_p: GPUParticles3D
var speed_p: GPUParticles3D
var spark_p: GPUParticles3D
var burn_pool: Array = []
var soft_tex: GradientTexture2D

func _soft_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.45, Color(1, 1, 1, 0.55))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	return t


func _pmat(add := false, size := 1.0) -> QuadMesh:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if add:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = soft_tex
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.proximity_fade_enabled = true
	m.proximity_fade_distance = 1.5
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	q.material = m
	return q


func _ramp(stops: Array) -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array()
	g.colors = PackedColorArray()
	for s in stops:
		g.add_point(s[0], s[1])
	var t := GradientTexture1D.new()
	t.gradient = g
	t.use_hdr = true
	return t


func _curve(pts: Array) -> CurveTexture:
	var c := Curve.new()
	for p in pts:
		c.add_point(p)
	var t := CurveTexture.new()
	t.curve = c
	return t


func _particles(amount: int, life: float, pm: ParticleProcessMaterial, mesh: Mesh, local := false) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.process_material = pm
	p.draw_pass_1 = mesh
	p.local_coords = local
	p.emitting = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-80, -80, -80), Vector3(160, 160, 160))
	return p


func _fire_pm(vel: float, spread: float, scale_max: float) -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0, -1)
	pm.spread = spread
	pm.initial_velocity_min = vel * 0.8
	pm.initial_velocity_max = vel
	pm.gravity = Vector3(0, 5.0, 0)
	pm.damping_min = vel * 0.45
	pm.damping_max = vel * 0.6
	pm.scale_min = scale_max * 0.5
	pm.scale_max = scale_max
	pm.angle_min = 0.0
	pm.angle_max = 360.0
	pm.angular_velocity_min = -90.0
	pm.angular_velocity_max = 90.0
	pm.scale_curve = _curve([Vector2(0, 0.25), Vector2(0.3, 1.0), Vector2(1, 2.2)])
	pm.color_ramp = _ramp([
		[0.0, Color(6.0, 5.0, 3.0, 1.0)],
		[0.12, Color(5.0, 2.4, 0.5, 1.0)],
		[0.38, Color(2.4, 0.6, 0.08, 0.85)],
		[0.6, Color(0.25, 0.12, 0.08, 0.55)],
		[1.0, Color(0.08, 0.08, 0.08, 0.0)]])
	return pm


func _build_effects() -> void:
	soft_tex = _soft_texture()
	# ejderha ateşi
	var fpm := _fire_pm(70.0, 6.0, 3.2)
	fpm.inherit_velocity_ratio = 1.0
	fire_p = _particles(900, 1.1, fpm, _pmat(false, 1.4))
	fire_p.fixed_fps = 0
	dmouth.add_child(fire_p)
	fire_light = OmniLight3D.new()
	fire_light.light_color = Color(1.0, 0.55, 0.2)
	fire_light.omni_range = 40.0
	fire_light.light_energy = 0.0
	fire_light.position = Vector3(0, 0, -8)
	dmouth.add_child(fire_light)
	_apply_breath()
	# su püskürtme
	var spm := ParticleProcessMaterial.new()
	spm.direction = Vector3(0, 1, 0)
	spm.spread = 35.0
	spm.initial_velocity_min = 5.0
	spm.initial_velocity_max = 14.0
	spm.gravity = Vector3(0, -9.8, 0)
	spm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	spm.emission_box_extents = Vector3(6, 0.2, 6)
	spm.scale_min = 0.8
	spm.scale_max = 2.5
	spm.scale_curve = _curve([Vector2(0, 0.4), Vector2(1, 1.6)])
	spm.color_ramp = _ramp([[0.0, Color(0.95, 0.97, 1.0, 0.7)], [1.0, Color(0.9, 0.95, 1.0, 0.0)]])
	spray_p = _particles(500, 1.3, spm, _pmat(false, 1.0))
	spray_p.top_level = true
	add_child(spray_p)
	# büyük sıçrama
	var bpm: ParticleProcessMaterial = spm.duplicate()
	bpm.spread = 25.0
	bpm.initial_velocity_min = 10.0
	bpm.initial_velocity_max = 26.0
	bpm.emission_box_extents = Vector3(5, 0.5, 5)
	bpm.scale_max = 4.0
	splash_p = _particles(260, 2.0, bpm, _pmat(false, 1.4))
	splash_p.one_shot = true
	splash_p.explosiveness = 0.9
	add_child(splash_p)
	# toz
	var dpm := ParticleProcessMaterial.new()
	dpm.direction = Vector3(0, 0.3, 0)
	dpm.spread = 90.0
	dpm.flatness = 0.6
	dpm.initial_velocity_min = 6.0
	dpm.initial_velocity_max = 15.0
	dpm.damping_min = 4.0
	dpm.damping_max = 6.0
	dpm.gravity = Vector3(0, 0.5, 0)
	dpm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	dpm.emission_sphere_radius = 3.0
	dpm.scale_min = 2.0
	dpm.scale_max = 5.0
	dpm.scale_curve = _curve([Vector2(0, 0.5), Vector2(1, 2.0)])
	dpm.color_ramp = _ramp([[0.0, Color(0.55, 0.5, 0.42, 0.55)], [1.0, Color(0.6, 0.56, 0.5, 0.0)]])
	dust_p = _particles(120, 2.5, dpm, _pmat(false, 1.0))
	dust_p.one_shot = true
	dust_p.explosiveness = 0.85
	add_child(dust_p)
	# kıvılcım (halka toplama)
	var kpm := ParticleProcessMaterial.new()
	kpm.direction = Vector3(0, 0, 1)
	kpm.spread = 180.0
	kpm.initial_velocity_min = 8.0
	kpm.initial_velocity_max = 22.0
	kpm.damping_min = 6.0
	kpm.damping_max = 9.0
	kpm.gravity = Vector3(0, -2, 0)
	kpm.scale_min = 0.3
	kpm.scale_max = 0.9
	kpm.color_ramp = _ramp([[0.0, Color(6, 4.5, 1.5, 1)], [1.0, Color(2, 0.8, 0.2, 0)]])
	spark_p = _particles(200, 1.5, kpm, _pmat(true, 1.0))
	spark_p.one_shot = true
	spark_p.explosiveness = 1.0
	add_child(spark_p)
	# yanan ağaç havuzu
	for i in 14:
		var bp := _fire_pm(4.0, 25.0, 4.0)
		bp.direction = Vector3(0, 1, 0)
		bp.gravity = Vector3(0, 6, 0)
		bp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		bp.emission_box_extents = Vector3(2.5, 6, 2.5)
		bp.color_ramp = _ramp([
			[0.0, Color(4.0, 2.2, 0.5, 0.9)],
			[0.3, Color(2.0, 0.5, 0.06, 0.7)],
			[0.5, Color(0.12, 0.1, 0.09, 0.6)],
			[1.0, Color(0.15, 0.15, 0.15, 0.0)]])
		var p := _particles(140, 4.0, bp, _pmat(false, 3.0))
		p.visibility_aabb = AABB(Vector3(-20, -10, -20), Vector3(40, 80, 40))
		add_child(p)
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.5, 0.15)
		l.omni_range = 28.0
		l.light_energy = 0.0
		p.add_child(l)
		burn_pool.append({"p": p, "l": l, "t": 0.0, "tree": -1})
	# şelale buharı
	var mist := ParticleProcessMaterial.new()
	mist.direction = Vector3(0, 1, 0)
	mist.spread = 70.0
	mist.initial_velocity_min = 2.0
	mist.initial_velocity_max = 6.0
	mist.gravity = Vector3(0, 0.6, 0)
	mist.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mist.emission_sphere_radius = 6.0
	mist.scale_min = 4.0
	mist.scale_max = 9.0
	mist.color_ramp = _ramp([[0.0, Color(1, 1, 1, 0.0)], [0.2, Color(1, 1, 1, 0.35)], [1.0, Color(1, 1, 1, 0.0)]])
	var order := range(waterfalls.size())
	order.sort_custom(func(a, b): return waterfall_drop[a] > waterfall_drop[b])
	for oi in min(16, order.size()):
		var w: Vector3 = waterfalls[order[oi]]
		var p := _particles(50, 4.0, mist, _pmat(false, 1.0))
		p.emitting = true
		p.position = w
		p.visibility_range_end = 1500.0
		add_child(p)
	# hız çizgileri
	var lpm := ParticleProcessMaterial.new()
	lpm.direction = Vector3(0, 0, 1)
	lpm.spread = 0.0
	lpm.initial_velocity_min = 140.0
	lpm.initial_velocity_max = 190.0
	lpm.gravity = Vector3.ZERO
	lpm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	lpm.emission_box_extents = Vector3(22, 14, 8)
	lpm.particle_flag_align_y = true
	lpm.color_ramp = _ramp([[0.0, Color(1, 1, 1, 0)], [0.3, Color(1, 1, 1, 0.22)], [1.0, Color(1, 1, 1, 0)]])
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	lm.vertex_color_use_as_albedo = true
	lm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	lm.billboard_keep_scale = true
	var lq := QuadMesh.new()
	lq.size = Vector2(0.05, 3.5)
	lq.material = lm
	speed_p = _particles(90, 0.35, lpm, lq, true)
	speed_p.position = Vector3(0, 0, -45)


func _ignite(id: int) -> void:
	if tree_burn[id] > 0.0:
		return
	tree_burn[id] = 0.01
	var slot = null
	for b in burn_pool:
		if b.t <= 0.0:
			slot = b
			break
	if slot == null:
		slot = burn_pool[0]
		for b in burn_pool:
			if b.t < slot.t:
				slot = b
	slot.t = 22.0
	slot.tree = id
	var s := 18.0 if tree_kind[id] == 0 else 13.0
	slot.p.global_position = tree_pos[id] + Vector3(0, s * 0.45, 0)
	slot.p.restart()
	slot.p.emitting = true
	_play3d("fire", tree_pos[id] + Vector3(0, 6, 0), -4.0, rng.randf_range(0.8, 1.1))


func _update_burning(delta: float) -> void:
	for b in burn_pool:
		if b.t <= 0.0:
			continue
		b.t -= delta
		var k: float = clamp(b.t / 4.0, 0.0, 1.0)
		b.l.light_energy = (2.5 + sin(game_time * 23.0) * 0.6 + sin(game_time * 13.0) * 0.4) * k
		if b.tree >= 0:
			var burnt: float = clamp(1.0 - b.t / 22.0, 0.0, 1.0)
			_tree_set_color(b.tree, Color(1, 1, 1).lerp(Color(0.12, 0.1, 0.09), smoothstep(0.0, 0.6, burnt)))
		if b.t <= 3.0:
			b.p.emitting = false


func _build_camera() -> void:
	cam = Camera3D.new()
	cam.fov = 72.0
	cam.near = 0.2
	cam.far = 14000.0
	add_child(cam)
	cam.current = true
	cam.add_child(speed_p)

# ============================================================================
#  UÇUŞ FİZİĞİ + YER/SU HAREKETİ + YAYA + KAMERA
# ============================================================================
var d_pos := Vector3.ZERO
var d_vel := Vector3.ZERO
var d_basis := Basis()
var d_angv := Vector3.ZERO
var d_state := "ucus"        # ucus | yer | su
var stamina := 1.0
var fire_fuel := 1.0
var fire_lock := false
var firing := false
var fire_tick := 0.0
var takeoff_t := 0.0
var hover_mix := 0.0
var flap_power := 0.0
var aoa := 0.0
var stalled := false
var air_speed := 0.0
var roar_cd := 0.0
var land_cd := 0.0
var aim_dir := Vector3.FORWARD
var cam_yaw := 0.0
var cam_pitch := -0.12
var cam_dist := 34.0 * 1.0
var cam_off := Vector3(0, 6, 26)
var shake := 0.0
var fov_cur := 72.0
var prev_ph := 0.0
var skim_t := 0.0
var STAND_H := 2.7 * 2.2

# yaya
var f_pos := Vector3.ZERO
var f_vel := Vector3.ZERO
var f_yaw := 0.0
var f_ground := true
var f_ph := 0.0
var f_amt := 0.0
var foot_cam_dist := 6.0
var step_t := 0.0

# çağırma
var calling := false
var call_t := 0.0
var call_dur := 1.0
var call_a := Vector3.ZERO
var call_b := Vector3.ZERO
var call_c := Vector3.ZERO


func _spawn() -> void:
	var v: Vector3 = village_sites[0] if not village_sites.is_empty() else Vector3(LAKE_C.x, 300, LAKE_C.y)
	var to_lake := (Vector3(LAKE_C.x, 0, LAKE_C.y) - Vector3(v.x, 0, v.z)).normalized()
	d_pos = Vector3(v.x, 0, v.z) - to_lake * 250.0
	d_pos.y = max(h_at(d_pos.x, d_pos.z), WATER_Y) + 160.0
	d_basis = Basis.looking_at(to_lake, Vector3.UP)
	d_vel = to_lake * 38.0
	d_state = "ucus"
	cam_yaw = atan2(-to_lake.x, -to_lake.z)
	cam_pitch = -0.12
	aim_dir = to_lake
	dragon.global_transform = Transform3D(d_basis.scaled(Vector3(DS, DS, DS)), d_pos)
	_reset_tail()
	mode = 0


# ---------------------------------------------------------------- ana döngü
func _process(delta: float) -> void:
	if not loaded:
		return
	delta = min(delta, 1.0 / 20.0)
	_update_ui(delta)
	_touch_process()
	if paused:
		return
	game_time += delta
	var hours := 1.0 / 120.0
	if Input.is_action_pressed("saat"):
		hours = 1.6
	time_of_day = fmod(time_of_day + delta * hours, 24.0)
	sun_tick -= delta
	if sun_tick <= 0.0:
		sun_tick = 0.05 if hours > 1.0 else 0.4
		_update_sun(delta)
		sky_mat.set_shader_parameter("ctime", game_time)
	_read_camera_input(delta)
	if calling:
		_update_call(delta)
	elif mode == 0:
		var steps := 2
		for i in steps:
			_dragon_step(delta / steps)
	else:
		_dragon_idle(delta)
	if mode == 1:
		_update_foot(delta)
	_dragon_visual(delta)
	_update_fire(delta)
	_update_camera(delta)
	_update_world(delta)
	_update_audio(delta)
	_check_rings()


func _read_camera_input(delta: float) -> void:
	var jx := Input.get_action_strength("kam_x+") - Input.get_action_strength("kam_x-")
	var jy := Input.get_action_strength("kam_y+") - Input.get_action_strength("kam_y-")
	cam_yaw -= jx * 2.6 * delta
	cam_pitch -= jy * 1.8 * delta * (-1.0 if settings.invert else 1.0)
	cam_pitch = clamp(cam_pitch, -1.4, 1.25)
	if not Input.is_action_pressed("serbest"):
		aim_dir = Vector3(0, 0, -1).rotated(Vector3.RIGHT, cam_pitch).rotated(Vector3.UP, cam_yaw)


func _input(event: InputEvent) -> void:
	if not loaded:
		return
	if _touch_input(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not paused:
		cam_yaw -= event.relative.x * settings.sens
		cam_pitch -= event.relative.y * settings.sens * (-1.0 if settings.invert else 1.0)
		cam_pitch = clamp(cam_pitch, -1.4, 1.25)
	if event.is_action_pressed("menu"):
		_toggle_pause()
	if paused:
		return
	if event.is_action_pressed("tamekran"):
		var m := DisplayServer.window_get_mode()
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if m >= DisplayServer.WINDOW_MODE_FULLSCREEN else DisplayServer.WINDOW_MODE_FULLSCREEN)
	if event.is_action_pressed("yardim"):
		ui.help.visible = not ui.help.visible
	if event.is_action_pressed("harita"):
		ui.bigmap.visible = not ui.bigmap.visible
	if event.is_action_pressed("muzik"):
		settings.music = not settings.music
		_msg("Müzik: " + ("Açık" if settings.music else "Kapalı"), 1.5)
		_save_settings()
	for k in 4:
		if event.is_action_pressed("tur%d" % (k + 1)) and mode == 0:
			_set_species(k)
	if event.is_action_pressed("tur_sonraki") and mode == 0:
		_set_species((cur_species + 1) % SPECIES.size())
	if event.is_action_pressed("kalite"):
		settings.quality = (settings.quality + 1) % 4
		_apply_quality()
		_msg("Grafik kalitesi: " + QUALITY_NAMES[settings.quality], 2.0)
		_save_settings()
	if event.is_action_pressed("yakin"):
		if mode == 0:
			cam_dist = maxf(16.0 * SK, cam_dist - 2.5 * SK)
		else:
			foot_cam_dist = max(2.5, foot_cam_dist - 0.6)
	if event.is_action_pressed("uzak"):
		if mode == 0:
			cam_dist = minf(80.0 * SK, cam_dist + 2.5 * SK)
		else:
			foot_cam_dist = min(14.0, foot_cam_dist + 0.6)
	if event.is_action_pressed("bin"):
		_toggle_mount()
	if event.is_action_pressed("cagir") and mode == 1:
		_call_dragon()
	if event.is_action_pressed("kukre") and roar_cd <= 0.0 and mode == 0:
		_roar()
	if event.is_action_pressed("yuksel") and mode == 0 and not calling:
		if d_state != "ucus":
			_takeoff()
		elif stamina > 0.08:
			# güçlü kanat vuruşu
			d_vel += d_basis.y * 7.0 + Vector3(0, 3.0, 0)
			stamina -= 0.06
			flap_ph = PI * 0.3
			_play2d("flap", 2.0, 0.8)


func _toggle_pause() -> void:
	paused = not paused
	ui.pause.visible = paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED
	if fire_p:
		fire_p.emitting = false


# ---------------------------------------------------------------- ejderha: uçuş
func _dragon_step(dt: float) -> void:
	land_cd = max(0.0, land_cd - dt)
	takeoff_t = max(0.0, takeoff_t - dt)
	if d_state == "ucus":
		_air_step(dt)
	else:
		_ground_step(dt)
	_bounds(dt)


func _air_step(dt: float) -> void:
	var thr := Input.get_action_strength("ileri")
	var brake := Input.get_action_strength("fren")
	var roll_in := Input.get_action_strength("sag") - Input.get_action_strength("sol")
	var climb := Input.get_action_strength("yuksel")
	var dive := Input.get_action_strength("dalis")
	var boost := Input.is_action_pressed("hiz") and stamina > 0.02
	var fwd := -d_basis.z
	var up := d_basis.y
	var right := d_basis.x
	var v := d_vel
	var spd := v.length()
	air_speed = spd
	var vdir := v / maxf(spd, 0.01)
	var vl := d_basis.inverse() * v
	aoa = atan2(-vl.y, max(-vl.z, 0.5))
	var adeg := rad_to_deg(aoa)
	var cl: float
	if abs(adeg) < 15.0:
		cl = adeg * 0.105
	else:
		cl = sign(adeg) * max(0.35, 1.58 - (abs(adeg) - 15.0) * 0.045)
	cl = clamp(cl, -1.1, 1.6)
	stalled = abs(adeg) > 17.0 and spd < 30.0
	var fold := wing_fold
	var area := 1.0 - fold * 0.8
	var rho: float = clamp(1.0 - (d_pos.y - 1600.0) / 4200.0, 0.4, 1.0)
	var q := spd * spd * rho
	# hover (S ile yavaşken asılı kal)
	var want_hover := brake > 0.3 and spd < 26.0
	hover_mix = move_toward(hover_mix, 1.0 if want_hover else 0.0, dt * 1.8)
	# kanat gücü
	var p := 0.0
	if thr > 0.1:
		p = 0.62 * thr
	if boost and thr > 0.1:
		p = 1.3
	if climb > 0.1:
		p = max(p, 0.9)
	if takeoff_t > 0.0:
		p = 1.4
	var slow_k: float = clampf(1.0 - spd / 18.0, 0.0, 1.0) * (1.0 - hover_mix) * (1.0 - dive) * (1.0 if brake < 0.3 else 0.0)
	p = maxf(p, slow_k)
	if hover_mix > 0.01:
		p = max(p, hover_mix)
	if fold > 0.5:
		p = 0.0
	flap_power = move_toward(flap_power, p, dt * 3.0)
	# stamina
	var use := 0.0
	if boost and thr > 0.1:
		use += 0.11
	if climb > 0.1:
		use += 0.05
	if hover_mix > 0.5:
		use += 0.035
	stamina = clamp(stamina - use * sp().stam * dt + (0.07 if use == 0.0 else 0.0) * dt, 0.0, 1.0)
	var pulse := 1.0 + 0.65 * -cos(flap_ph)
	var acc := Vector3(0, -GRAV, 0)
	var lift_dir := right.cross(vdir).normalized()
	acc += lift_dir * clampf(0.0146 * sp().lift * q * cl * area, -25.0, 46.0)
	var cd: float = lerpf(0.0004, 0.0011, fold) + 0.0003 * area + 0.0002 * cl * cl * area
	if brake > 0.1 and hover_mix < 0.5:
		cd += 0.0035 * brake
	cd *= sp().drag
	acc -= vdir * q * cd
	acc -= right * vl.x * spd * 0.012
	var thrust_fwd: float = flap_power * 200.0 * sp().thrust / maxf(spd, 12.0) * (1.0 - hover_mix)
	var thrust_up := (flap_power * 2.5 + climb * 4.0) * (1.0 - hover_mix)
	acc += (fwd * thrust_fwd + up * thrust_up) * pulse
	acc.y += GRAV * 0.8 * slow_k * pulse
	if hover_mix > 0.0:
		var hv := Vector3(v.x, 0, v.z)
		var vy_des: float = clampf(aim_dir.y * 14.0, -9.0, 6.0) + climb * 7.0 - dive * 9.0
		if stamina <= 0.0:
			vy_des = -7.0
		acc.y += (GRAV * (0.85 + 0.15 * pulse) + (vy_des - v.y) * 2.2) * hover_mix
		acc -= hv * 1.4 * hover_mix
		acc += Vector3(aim_dir.x, 0, aim_dir.z).normalized() * thr * 9.0 * hover_mix
	d_vel += acc * dt
	# --- dönüş: hedef yöne PD kontrol + yatış
	var tgt_fwd := aim_dir
	var stall_f: float = clampf((absf(adeg) - 15.0) / 15.0, 0.0, 1.0) * clampf(1.0 - spd / 30.0, 0.0, 1.0) * (1.0 - hover_mix)
	if stall_f > 0.0 and spd > 1.0:
		tgt_fwd = tgt_fwd.slerp(vdir, 0.6 * stall_f).normalized()
	if hover_mix > 0.3:
		var hf := Vector3(aim_dir.x, 0, aim_dir.z).normalized()
		tgt_fwd = (hf + Vector3(0, 0.3, 0)).normalized()
	var hf0 := Vector3(fwd.x, 0, fwd.z).normalized()
	var ht := Vector3(tgt_fwd.x, 0, tgt_fwd.z).normalized()
	var yaw_err := hf0.signed_angle_to(ht, Vector3.UP)
	var roll_t: float = clamp(yaw_err * 2.1, -1.2, 1.2) * (1.0 - hover_mix) - roll_in * 1.25
	var tb := Basis.looking_at(tgt_fwd, Vector3.UP) * Basis(Vector3(0, 0, 1), roll_t)
	var qe := Quaternion((tb * d_basis.inverse()).orthonormalized())
	if qe.w < 0.0:
		qe = -qe
	var axis := Vector3(qe.x, qe.y, qe.z)
	var ang := 2.0 * asin(clampf(axis.length(), 0.0, 1.0))
	var err := axis.normalized() * ang if axis.length() > 0.0001 else Vector3.ZERO
	var auth: float = (clampf(spd / 26.0, 0.45, 1.25) + hover_mix * 0.6) * sp().turn
	var ang_acc := err * 7.5 * auth - d_angv * 4.8
	ang_acc += fwd.cross(vdir) * clamp(spd * 0.06, 0.0, 3.0)
	if stalled:
		ang_acc += right * -0.8 + up * sin(game_time * 7.0) * 0.4
		shake = max(shake, 0.25)
	d_angv += ang_acc * dt
	if d_angv.length() > 0.0001:
		d_basis = Basis(d_angv.normalized(), d_angv.length() * dt) * d_basis
	d_basis = d_basis.orthonormalized()
	d_pos += d_vel * dt
	# --- yer / su teması
	var th := h_at(d_pos.x, d_pos.z)
	var wl := water_at(d_pos.x, d_pos.z)
	if wl > th + 1.5 and d_pos.y < wl + 1.2:
		if spd > 22.0 and d_vel.y > -25.0:
			d_pos.y = wl + 1.2
			d_vel.y = max(d_vel.y, 0.0)
			d_vel *= 1.0 - 0.35 * dt
			if skim_t <= 0.0:
				_splash(Vector3(d_pos.x, wl, d_pos.z), 0.7)
				skim_t = 0.6
		else:
			_splash(Vector3(d_pos.x, wl, d_pos.z), 1.0)
			d_state = "su"
			d_vel *= 0.3
			shake = 0.4
	elif d_pos.y < th + STAND_H:
		var n := n_at(d_pos.x, d_pos.z)
		var vdown := -d_vel.dot(n)
		if spd < 30.0 and vdown < 16.0 and n.y > 0.72 and land_cd <= 0.0:
			d_state = "yer"
			d_pos.y = th + STAND_H
			d_vel = Vector3(d_vel.x, 0, d_vel.z) * 0.5
			_dust(Vector3(d_pos.x, th, d_pos.z), 0.7)
			_play2d("thud", -4.0, 1.0)
			shake = 0.35
			_msg("İniş yapıldı  •  Boşluk: kalkış   E: in", 2.5)
		elif spd < 30.0 and vdown < 16.0:
			d_pos.y = th + STAND_H
			if vdown > 0.0:
				d_vel += n * vdown
			d_vel += Vector3(n.x, 0.0, n.z).normalized() * 8.0 * dt
			if not ui.has("steep_t") or game_time - ui.steep_t > 4.0:
				ui.steep_t = game_time
				_msg("Burası inmek için çok dik", 1.5)
		else:
			d_pos.y = th + STAND_H
			if vdown > 0.0:
				d_vel += n * vdown * 1.25
			d_vel *= 0.55
			shake = clamp(vdown / 25.0, 0.35, 1.0)
			_dust(Vector3(d_pos.x, th, d_pos.z), 1.0)
			_play2d("thud", 2.0, 0.8)
			d_angv += Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)) * 1.5
	skim_t -= dt
	var ob := _obstacle_at(d_pos, true, 2.0 * SK)
	if ob.z >= 0.0:
		d_vel *= 1.0 - 2.5 * dt
		shake = max(shake, 0.35)
		if skim_t <= -0.5:
			skim_t = 0.0
			_play2d("thud", -6.0, 1.4)
			_dust(d_pos, 0.4)
		if d_pos.y < ob.w and Vector2(d_pos.x - ob.x, d_pos.z - ob.y).length() < ob.z * 0.6:
			d_vel.y = max(d_vel.y, 4.0)


# ---------------------------------------------------------------- ejderha: yerde / suda
func _ground_step(dt: float) -> void:
	var swim := d_state == "su"
	var mv := Vector2(Input.get_action_strength("sag") - Input.get_action_strength("sol"), Input.get_action_strength("fren") - Input.get_action_strength("ileri"))
	var run := Input.is_action_pressed("hiz")
	var dir := Vector3(mv.x, 0, mv.y).rotated(Vector3.UP, cam_yaw)
	var top: float = ((14.0 if swim else 26.0) if run else (6.0 if swim else 9.0)) * sp().run * sqrt(SK)
	var hv := Vector3(d_vel.x, 0, d_vel.z)
	var want := dir.normalized() * top * minf(1.0, dir.length())
	hv = hv.move_toward(want, dt * (12.0 if swim else 22.0))
	stamina = clamp(stamina + 0.12 * dt, 0.0, 1.0)
	var fwd := -d_basis.z
	var hf := Vector3(fwd.x, 0, fwd.z).normalized()
	if hv.length() > 0.5:
		var tf := hv.normalized()
		var a := hf.signed_angle_to(tf, Vector3.UP)
		hf = hf.rotated(Vector3.UP, clamp(a, -2.6 * dt, 2.6 * dt))
	var th := h_at(d_pos.x, d_pos.z)
	var wl := water_at(d_pos.x, d_pos.z)
	var n := n_at(d_pos.x, d_pos.z)
	var np := d_pos + hv * dt
	var nn := n_at(np.x, np.z)
	if not swim and nn.y < 0.6:
		hv *= 0.2
		np = d_pos + hv * dt
	d_pos = _push_out(np, 2.2 * SK)
	th = h_at(d_pos.x, d_pos.z)
	wl = water_at(d_pos.x, d_pos.z)
	if wl > th + 2.4:
		if not swim:
			d_state = "su"
			_splash(Vector3(d_pos.x, wl, d_pos.z), 0.6)
		swim = true
		d_pos.y = lerp(d_pos.y, wl + 0.4 + sin(game_time * 1.7) * 0.15, clamp(dt * 3.0, 0.0, 1.0))
		n = Vector3.UP
	else:
		if swim:
			d_state = "yer"
			swim = false
		d_pos.y = lerp(d_pos.y, th + STAND_H, clamp(dt * 12.0, 0.0, 1.0))
	d_vel = Vector3(hv.x, 0, hv.z)
	air_speed = hv.length()
	var up := n.lerp(Vector3.UP, 0.45).normalized()
	var tb := Basis.looking_at(hf, up)
	d_basis = d_basis.slerp(tb.orthonormalized(), clamp(dt * 6.0, 0.0, 1.0)).orthonormalized()
	d_angv = Vector3.ZERO
	hover_mix = 0.0
	flap_power = 0.0


func _takeoff() -> void:
	if stamina < 0.1:
		_msg("Ejderhan çok yorgun — biraz dinlensin", 2.0)
		return
	var fwd := -d_basis.z
	var hf := Vector3(fwd.x, 0, fwd.z).normalized()
	d_state = "ucus"
	d_vel = hf * 12.0 + Vector3(0, 16.0, 0)
	takeoff_t = 2.0
	land_cd = 1.5
	stamina -= 0.08
	flap_ph = PI * 0.5
	_dust(Vector3(d_pos.x, h_at(d_pos.x, d_pos.z), d_pos.z), 1.0)
	var wl := water_at(d_pos.x, d_pos.z)
	if wl > h_at(d_pos.x, d_pos.z) + 1.0:
		_splash(Vector3(d_pos.x, wl, d_pos.z), 1.0)
	_play2d("flap", 4.0, 0.7)
	shake = 0.3


func _bounds(dt: float) -> void:
	var m := 120.0
	var push := Vector3.ZERO
	if d_pos.x < m:
		push.x = m - d_pos.x
	if d_pos.x > WORLD - m:
		push.x = WORLD - m - d_pos.x
	if d_pos.z < m:
		push.z = m - d_pos.z
	if d_pos.z > WORLD - m:
		push.z = WORLD - m - d_pos.z
	if push.length() > 0.0:
		d_vel += push * 2.5 * dt
		d_pos += push * dt
		if not ui.has("bound_t") or game_time - ui.bound_t > 4.0:
			ui.bound_t = game_time
			_msg("Vadinin sınırına ulaştın — geri dön", 2.0)
	if d_pos.y > 3700.0:
		d_vel.y -= (d_pos.y - 3700.0) * 0.5 * dt


# ---------------------------------------------------------------- ejderha: görünüm & animasyon
func _dragon_visual(delta: float) -> void:
	dragon.global_transform = Transform3D(d_basis.scaled(Vector3(DS, DS, DS)), d_pos)
	var spd := d_vel.length()
	var fold_t := 0.0
	var amp_t := 0.08
	var freq_t := 0.45
	var sweep_t := 0.0
	var tuck_t := 1.0
	var walk_t := 0.0
	if calling:
		amp_t = 0.9
		freq_t = 1.5
	elif d_state == "ucus":
		var dive := Input.get_action_strength("dalis") if mode == 0 else 0.0
		fold_t = 0.82 * dive
		if flap_power > 0.05:
			amp_t = lerp(0.55, 1.05, clamp(flap_power, 0.0, 1.0))
			freq_t = lerp(1.25, 2.1, clamp(flap_power - 0.3, 0.0, 1.0))
		if hover_mix > 0.1:
			amp_t = max(amp_t, 1.0)
			freq_t = max(freq_t, 1.8)
			sweep_t = 0.5 * hover_mix
		if Input.get_action_strength("fren") > 0.2 and hover_mix < 0.3 and mode == 0:
			sweep_t = 0.35
			amp_t = max(amp_t, 0.25)
		var alt := d_pos.y - h_at(d_pos.x, d_pos.z)
		tuck_t = clamp((alt - 5.0) / 12.0, 0.0, 1.0) if spd < 32.0 else 1.0
	elif d_state == "yer":
		fold_t = 1.0
		amp_t = 0.0
		tuck_t = 0.0
		walk_t = clamp(spd / 9.0, 0.0, 1.6)
	else:
		fold_t = 0.55
		amp_t = 0.12
		freq_t = 0.7
		tuck_t = 0.3
		walk_t = clamp(spd / 6.0, 0.0, 1.2)
	wing_fold = move_toward(wing_fold, fold_t, delta * 2.2)
	flap_amp = move_toward(flap_amp, amp_t, delta * 2.0)
	flap_freq = lerp(flap_freq, freq_t, clamp(delta * 3.0, 0.0, 1.0))
	wing_sweep = lerp(wing_sweep, sweep_t, clamp(delta * 3.0, 0.0, 1.0))
	leg_tuck = move_toward(leg_tuck, tuck_t, delta * 2.0)
	neck_raise = move_toward(neck_raise, 1.0 if d_state == "yer" else (0.55 if d_state == "su" or hover_mix > 0.5 else 0.0), delta * 0.8)
	walk_amt = move_toward(walk_amt, walk_t, delta * 3.0)
	var prev := fmod(flap_ph, TAU)
	if d_state == "ucus" and flap_amp < 0.2:
		flap_ph += delta * TAU * 0.25
	else:
		flap_ph += delta * TAU * flap_freq
	walk_ph += delta * (spd * 0.55 + 0.5) * (1.0 if walk_amt > 0.05 else 0.0)
	var cur := fmod(flap_ph, TAU)
	if prev < PI * 0.5 and cur >= PI * 0.5 and flap_amp > 0.35:
		_play2d("flap", linear_to_db(clamp(flap_amp, 0.2, 1.1)) - 2.0, rng.randf_range(0.85, 1.05) / clamp(flap_freq * 0.7, 0.8, 1.5))
		if d_state == "ucus" and d_pos.y - h_at(d_pos.x, d_pos.z) < 18.0 and flap_amp > 0.5:
			_dust(Vector3(d_pos.x, h_at(d_pos.x, d_pos.z), d_pos.z), 0.35)
	if d_state == "yer" and walk_amt > 0.3:
		var stp := fmod(walk_ph, PI)
		if stp < delta * (spd * 0.55 + 0.5) * 1.01:
			_play2d("thud", -14.0 + walk_amt * 4.0, rng.randf_range(1.3, 1.6))
			if walk_amt > 1.0:
				shake = max(shake, 0.1)
	# vücut salınımı
	dbody.position = Vector3(0, -sin(flap_ph - 0.4) * 0.25 * flap_amp * (1.0 - wing_fold), 0)
	if d_state == "yer":
		dbody.position.y += sin(walk_ph * 2.0) * 0.06 * walk_amt
	# kafa nişana baksın
	var la := d_basis.inverse() * aim_dir
	var ly: float = clamp(atan2(-la.x, -la.z), -1.0, 1.0)
	var lp: float = clamp(asin(clamp(la.y, -1.0, 1.0)), -0.6, 0.6)
	if mode == 1:
		var tl := d_basis.inverse() * (f_pos + Vector3(0, 1.6, 0) - d_pos).normalized()
		ly = clamp(atan2(-tl.x, -tl.z), -1.2, 1.2)
		lp = clamp(asin(clamp(tl.y, -1.0, 1.0)), -0.6, 0.6)
	look_yaw = lerp(look_yaw, ly * 0.8, clamp(delta * 3.0, 0.0, 1.0))
	look_pitch = lerp(look_pitch, lp * 0.5, clamp(delta * 3.0, 0.0, 1.0))
	jaw_open = move_toward(jaw_open, 1.0 if (firing or roar_cd > 2.0) else 0.0, delta * 5.0)
	roar_cd = max(0.0, roar_cd - delta)
	_update_pose(delta)
	_update_wings()
	var sway := 0.12 + walk_amt * 0.25 + (0.35 if d_state == "su" else 0.0)
	_update_tail(delta, sway)
	if mode == 0:
		hero.global_transform = saddle.global_transform.orthonormalized()
		var wind := -d_vel
		_pose_hero(true, 0.0, clamp(spd / 60.0, 0.0, 1.0), wind, delta)


func _dragon_idle(delta: float) -> void:
	if d_state == "ucus":
		# binicisiz havada kalırsa yavaşça iner
		d_vel = d_vel.move_toward(Vector3(0, -6, 0), delta * 10.0)
		d_pos += d_vel * delta
		var th := h_at(d_pos.x, d_pos.z)
		if d_pos.y < th + STAND_H:
			d_pos.y = th + STAND_H
			d_state = "yer"
			_dust(Vector3(d_pos.x, th, d_pos.z), 0.6)
		return
	d_vel = d_vel.move_toward(Vector3.ZERO, delta * 20.0)
	var th := h_at(d_pos.x, d_pos.z)
	var wl := water_at(d_pos.x, d_pos.z)
	if wl > th + 2.4:
		d_pos.y = lerp(d_pos.y, wl + 0.4, delta * 3.0)
	else:
		d_pos.y = lerp(d_pos.y, th + STAND_H - 0.3, delta * 4.0)
	air_speed = 0.0


# ---------------------------------------------------------------- ateş & kükreme
func _update_fire(delta: float) -> void:
	var want := Input.is_action_pressed("ates") and mode == 0 and not paused
	if fire_lock and fire_fuel > 0.3:
		fire_lock = false
	firing = want and fire_fuel > 0.0 and not fire_lock
	if firing:
		fire_fuel -= delta * 0.16
		if fire_fuel <= 0.0:
			fire_fuel = 0.0
			fire_lock = true
			_msg("Ateş tükendi — yeniden doluyor", 1.5)
	else:
		fire_fuel = min(1.0, fire_fuel + delta * 0.09)
	fire_p.emitting = firing
	fire_light.light_energy = lerp(fire_light.light_energy, (6.0 + sin(game_time * 31.0) * 1.5) if firing else 0.0, clamp(delta * 12.0, 0.0, 1.0))
	if firing:
		shake = max(shake, 0.12)
		fire_tick -= delta
		if fire_tick <= 0.0:
			fire_tick = 0.1
			_fire_hits()


func _fire_hits() -> void:
	var o := dmouth.global_position
	var dir := -dmouth.global_transform.basis.z.normalized()
	var t := 4.0
	while t < 75.0 * SK:
		var p := o + dir * t + d_vel * (t / 70.0) * 0.5
		var gk := Vector2i(int(p.x / 32.0), int(p.z / 32.0))
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var key := gk + Vector2i(dx, dz)
				if tree_grid.has(key):
					for id in tree_grid[key]:
						var tp: Vector3 = tree_pos[id]
						if Vector2(tp.x - p.x, tp.z - p.z).length() < 6.0 * SK and p.y > tp.y - 2.0 and p.y < tp.y + 24.0:
							if sp().breath == "ice":
								_freeze(id)
							else:
								_ignite(id)
		if p.y < h_at(p.x, p.z) + 0.5:
			_dust(p, 0.25)
			break
		if p.y < water_at(p.x, p.z):
			_splash(Vector3(p.x, water_at(p.x, p.z), p.z), 0.3)
			break
		t += 5.0


func _roar() -> void:
	roar_cd = 3.2
	_play2d("roar", 3.0, rng.randf_range(0.92, 1.05))
	shake = max(shake, 0.6)
	for fl in birds:
		fl.scat = 1.0
	for cw in cows:
		if Vector2(cw.pos.x - d_pos.x, cw.pos.y - d_pos.z).length() < 350.0:
			cw.flee = 6.0
			cw.target = cw.pos + (cw.pos - Vector2(d_pos.x, d_pos.z)).normalized() * 120.0


# ---------------------------------------------------------------- binme / inme / çağırma
func _toggle_mount() -> void:
	if mode == 0:
		if d_state == "ucus":
			_msg("Önce in! (Yere yaklaş, yavaşla)", 2.0)
			return
		mode = 1
		var side := d_basis.x
		f_pos = d_pos + side * 6.5 * SK
		f_pos.y = h_at(f_pos.x, f_pos.z)
		f_vel = Vector3.ZERO
		f_yaw = cam_yaw
		firing = false
		_msg("Yürüyorsun  •  E: ejderhaya bin   F: ejderhayı çağır", 3.0)
	else:
		if f_pos.distance_to(d_pos) < 12.0 * SK and not calling:
			mode = 0
			cam_yaw = atan2(d_basis.z.x, d_basis.z.z)
			_msg("Ejderhaya bindin!", 1.5)
		else:
			_msg("Ejderhan çok uzakta — F ile çağır", 2.0)


func _call_dragon() -> void:
	if calling:
		return
	var dist := d_pos.distance_to(f_pos)
	_play2d("whistle", -2.0, 1.0)
	if dist < 12.0:
		_msg("Ejderhan zaten yanında", 1.5)
		return
	calling = true
	call_t = 0.0
	call_a = d_pos
	var side := Vector3(f_pos.x - d_pos.x, 0, f_pos.z - d_pos.z).normalized()
	call_c = f_pos - side * 9.0 * SK
	call_c.y = max(h_at(call_c.x, call_c.z), water_at(call_c.x, call_c.z)) + STAND_H
	var mid := (call_a + call_c) * 0.5
	mid.y = max(call_a.y, call_c.y) + clamp(dist * 0.25, 30.0, 250.0)
	var hm := h_at(mid.x, mid.z) + 80.0
	mid.y = max(mid.y, hm)
	call_b = mid
	call_dur = clamp(dist / 45.0, 3.0, 14.0)
	d_state = "ucus"
	_msg("Ejderhan geliyor!", 2.0)
	_play2d("roar", -6.0, 1.1)


func _update_call(delta: float) -> void:
	call_t += delta / call_dur
	var t: float = clamp(call_t, 0.0, 1.0)
	var e := t * t * (3.0 - 2.0 * t)
	var p := call_a.lerp(call_b, e).lerp(call_b.lerp(call_c, e), e)
	var tng := (call_b - call_a).lerp(call_c - call_b, e)
	tng.y *= 0.4
	if tng.length() > 0.1:
		var tb := Basis.looking_at(tng.normalized(), Vector3.UP)
		d_basis = d_basis.slerp(tb, clamp(delta * 3.0, 0.0, 1.0)).orthonormalized()
	d_vel = (p - d_pos) / max(delta, 0.001)
	d_pos = p
	if call_t >= 1.0:
		calling = false
		d_state = "yer" if water_at(d_pos.x, d_pos.z) < h_at(d_pos.x, d_pos.z) + 2.0 else "su"
		d_vel = Vector3.ZERO
		var hf := Vector3(f_pos.x - d_pos.x, 0, f_pos.z - d_pos.z).normalized()
		d_basis = Basis.looking_at(hf, Vector3.UP)
		_dust(Vector3(d_pos.x, h_at(d_pos.x, d_pos.z), d_pos.z), 0.9)
		_play2d("thud", 0.0, 0.9)
		_msg("E: bin", 2.0)


# ---------------------------------------------------------------- yaya hareketi
func _update_foot(delta: float) -> void:
	var mv := Vector2(Input.get_action_strength("sag") - Input.get_action_strength("sol"), Input.get_action_strength("fren") - Input.get_action_strength("ileri"))
	var run := Input.is_action_pressed("hiz")
	var dir := Vector3(mv.x, 0, mv.y).rotated(Vector3.UP, cam_yaw)
	if dir.length() > 1.0:
		dir = dir.normalized()
	var th := h_at(f_pos.x, f_pos.z)
	var wl := water_at(f_pos.x, f_pos.z)
	var swim := wl > th + 1.3
	var top := (2.2 if swim else (8.5 if run else 4.2))
	var hv := Vector3(f_vel.x, 0, f_vel.z)
	hv = hv.move_toward(dir * top, delta * (8.0 if f_ground else 2.5) * top)
	if hv.length() > 0.3:
		f_yaw = lerp_angle(f_yaw, atan2(-hv.x, -hv.z), clamp(delta * 10.0, 0.0, 1.0))
	var np := f_pos + hv * delta
	if n_at(np.x, np.z).y < 0.55 and h_at(np.x, np.z) > f_pos.y:
		hv *= 0.0
		np = f_pos
	var dd := Vector2(np.x - d_pos.x, np.z - d_pos.z)
	if dd.length() < 4.6 * SK and mode == 1 and not calling:
		var push := dd.normalized() * (4.6 * SK - dd.length())
		np.x += push.x
		np.z += push.y
	np = _push_out(np, 0.35)
	f_vel.x = hv.x
	f_vel.z = hv.z
	f_vel.y -= 20.0 * delta
	if f_ground and Input.is_action_just_pressed("yuksel") and not swim:
		f_vel.y = 7.0
		f_ground = false
	np.y += f_vel.y * delta
	th = h_at(np.x, np.z)
	wl = water_at(np.x, np.z)
	swim = wl > th + 1.3
	if swim:
		np.y = wl - 1.25
		f_vel.y = 0.0
		f_ground = true
	elif np.y <= th:
		np.y = th
		f_vel.y = 0.0
		f_ground = true
	elif np.y > th + 0.3:
		f_ground = false
	f_pos = np
	var spd := hv.length()
	f_amt = move_toward(f_amt, clamp(spd / 4.2, 0.0, 1.4), delta * 6.0)
	f_ph += delta * (spd * 1.9 + 0.1)
	step_t -= delta
	if f_ground and spd > 1.0 and step_t <= 0.0 and not swim:
		step_t = PI / (spd * 1.9 + 0.1)
		_play2d("step", -16.0 + f_amt * 3.0, rng.randf_range(0.9, 1.2))
	hero.global_transform = Transform3D(Basis(Vector3.UP, f_yaw), f_pos)
	_pose_hero(false, f_ph, f_amt, -hv + Vector3(2, 0, 1), delta)


# ---------------------------------------------------------------- kamera
func _update_camera(delta: float) -> void:
	var target: Vector3
	var dist: float
	var look: Vector3
	var cb := Basis.from_euler(Vector3(cam_pitch, cam_yaw, 0))
	if mode == 0:
		target = d_pos + d_basis.y * 4.5 * SK + Vector3(0, 3.0 * SK, 0)
		dist = cam_dist + clamp((air_speed - 30.0) * 0.08, 0.0, 6.0)
		var want := cb * Vector3(0, 0, dist) + Vector3(0, dist * 0.08, 0)
		cam_off = cam_off.lerp(want, clamp(delta * 9.0, 0.0, 1.0))
		var lag := -d_vel * 0.035 if d_state == "ucus" else Vector3.ZERO
		var cp := target + cam_off + lag
		look = target + aim_dir * 30.0
		cam.global_position = cp
	else:
		target = f_pos + Vector3(0, 1.65, 0)
		dist = foot_cam_dist
		var want := cb * Vector3(0.55, 0.2, dist)
		cam_off = cam_off.lerp(want, clamp(delta * 12.0, 0.0, 1.0))
		cam.global_position = target + cam_off
		look = target + aim_dir * 10.0 + cb * Vector3(0.55, 0, 0)
	cam.global_position = _cam_collide(target, cam.global_position)
	var c := cam.global_position
	var gh: float = max(h_at(c.x, c.z), water_at(c.x, c.z)) + 1.5
	if c.y < gh:
		c.y = gh
		cam.global_position = c
	var up := Vector3.UP
	if (look - c).normalized().abs().y > 0.98:
		up = Vector3.FORWARD
	cam.look_at(look, up)
	# sarsıntı
	shake = max(0.0, shake - delta * 1.6)
	var buffet: float = clamp((air_speed - 55.0) / 40.0, 0.0, 1.0) * 0.25 if mode == 0 and d_state == "ucus" else 0.0
	var s := shake * shake + buffet * 0.3
	if s > 0.0:
		var t := game_time * 30.0
		cam.rotate_object_local(Vector3.RIGHT, sin(t * 1.1) * 0.015 * s)
		cam.rotate_object_local(Vector3.UP, sin(t * 0.9 + 1.3) * 0.015 * s)
		cam.rotate_object_local(Vector3.FORWARD, sin(t * 1.3 + 2.1) * 0.02 * s)
	var fov_t := 72.0
	if mode == 0:
		fov_t = 70.0 + clamp((air_speed - 20.0) / 60.0, 0.0, 1.0) * 24.0
	fov_cur = lerp(fov_cur, fov_t, clamp(delta * 3.0, 0.0, 1.0))
	cam.fov = fov_cur
	speed_p.emitting = mode == 0 and d_state == "ucus" and air_speed > 48.0
	speed_p.speed_scale = clamp(air_speed / 60.0, 0.8, 1.6)

# ============================================================================
#  SES — tüm sesler kod içinde sentezlenir (dosya gerekmez)
# ============================================================================
var sfx := {}
var p2d: Array = []
var p3d: Array = []
var wind_lo: AudioStreamPlayer
var wind_hi: AudioStreamPlayer
var fire_snd: AudioStreamPlayer
var river_snd: AudioStreamPlayer3D
var fall_snd: AudioStreamPlayer3D
var audio_tick := 0.0
var bird_t := 2.0


func _lp_coef(fc: float) -> float:
	return 1.0 - exp(-TAU * fc / SR)


func _white(n: int) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(n)
	for i in n:
		b[i] = rng.randf() * 2.0 - 1.0
	return b


func _lowpass(b: PackedFloat32Array, fc: float) -> PackedFloat32Array:
	var a := _lp_coef(fc)
	var y := 0.0
	for i in b.size():
		y += a * (b[i] - y)
		b[i] = y
	return b


func _highpass(b: PackedFloat32Array, fc: float) -> PackedFloat32Array:
	var a := _lp_coef(fc)
	var y := 0.0
	for i in b.size():
		y += a * (b[i] - y)
		b[i] = b[i] - y
	return b


func _bandpass(b: PackedFloat32Array, f: float, q: float) -> PackedFloat32Array:
	var w0 := TAU * f / SR
	var al := sin(w0) / (2.0 * q)
	var a0 := 1.0 + al
	var b0 := al / a0
	var b2 := -al / a0
	var a1 := -2.0 * cos(w0) / a0
	var a2 := (1.0 - al) / a0
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	for i in b.size():
		var x := b[i]
		var y := b0 * x + b2 * x2 - a1 * y1 - a2 * y2
		x2 = x1
		x1 = x
		y2 = y1
		y1 = y
		b[i] = y
	return b


func _norm(b: PackedFloat32Array, peak := 0.9) -> PackedFloat32Array:
	var m := 0.0001
	for v in b:
		m = max(m, abs(v))
	var k := peak / m
	for i in b.size():
		b[i] *= k
	return b


func _loopify(b: PackedFloat32Array, fade_s := 0.4) -> PackedFloat32Array:
	var f := int(fade_s * SR)
	var n := b.size() - f
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = b[i]
	for i in f:
		var t := float(i) / f
		out[i] = b[i] * t + b[n + i] * (1.0 - t)
	return out


func _wav(b: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SR
	w.stereo = false
	var bytes := PackedByteArray()
	bytes.resize(b.size() * 2)
	for i in b.size():
		bytes.encode_s16(i * 2, int(clamp(b[i], -1.0, 1.0) * 32000.0))
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = b.size()
	return w


func _env(i: int, att: float, dec: float) -> float:
	var t := float(i) / SR
	if t < att:
		return t / att
	return exp(-(t - att) / dec)


# ---------------------------------------------------------------- tek tek sesler
func _snd_wind() -> PackedFloat32Array:
	var n := SR * 5
	var b := _lowpass(_lowpass(_white(n), 520.0), 700.0)
	for i in n:
		var t := float(i) / SR
		b[i] *= 0.65 + 0.25 * sin(t * 1.1) + 0.15 * sin(t * 2.9 + 1.0)
	return _norm(_loopify(b, 0.6), 0.8)


func _snd_wind_hi() -> PackedFloat32Array:
	var n := SR * 4
	var b := _bandpass(_white(n), 1700.0, 0.9)
	for i in n:
		var t := float(i) / SR
		b[i] *= 0.6 + 0.4 * sin(t * 3.3) * sin(t * 0.7)
	return _norm(_loopify(b, 0.5), 0.6)


func _snd_flap() -> PackedFloat32Array:
	var n := int(SR * 0.75)
	var b := _lowpass(_lowpass(_white(n), 260.0), 260.0)
	var c := _bandpass(_white(n), 750.0, 1.2)
	b = _norm(b, 1.0)
	for i in n:
		var t := float(i) / SR
		var e := _env(i, 0.07, 0.17)
		b[i] = b[i] * e + sin(TAU * 52.0 * t) * _env(i, 0.03, 0.1) * 0.6 + c[i] * _env(i, 0.02, 0.06) * (0.5 + 0.5 * sin(TAU * 38.0 * t)) * 0.8
	return _norm(b, 0.95)


func _snd_roar() -> PackedFloat32Array:
	var n := int(SR * 2.6)
	var b := PackedFloat32Array()
	b.resize(n)
	var ph := 0.0
	var ph2 := 0.0
	var jit := 0.0
	for i in n:
		var t := float(i) / SR
		var f0 := 88.0 + 30.0 * sin(clampf(t / 2.0, 0.0, 1.0) * PI) - t * 6.0
		jit += (rng.randf() - 0.5) * 0.4
		jit *= 0.995
		f0 *= 1.0 + 0.03 * sin(t * TAU * 6.5) + jit * 0.02
		ph = fmod(ph + f0 / SR, 1.0)
		ph2 = fmod(ph2 + f0 * 0.5 / SR, 1.0)
		var saw := ph * 2.0 - 1.0
		var sub := (1.0 if ph2 < 0.5 else -1.0) * 0.45
		b[i] = saw + sub + (rng.randf() * 2.0 - 1.0) * 0.55
	var f1 := _bandpass(b.duplicate(), 420.0, 2.5)
	var f2 := _bandpass(b.duplicate(), 1050.0, 3.5)
	var f3 := _bandpass(b.duplicate(), 2500.0, 4.0)
	var lo := _lowpass(b.duplicate(), 250.0)
	for i in n:
		var t := float(i) / SR
		var e: float = min(t / 0.25, 1.0) * (1.0 if t < 1.7 else exp(-(t - 1.7) / 0.3))
		var v := f1[i] * 1.6 + f2[i] * 1.1 + f3[i] * 0.5 + lo[i] * 0.9
		b[i] = tanh(v * 2.2) * e
	return _norm(b, 0.95)


func _snd_thud() -> PackedFloat32Array:
	var n := int(SR * 0.9)
	var nz := _lowpass(_white(n), 320.0)
	nz = _norm(nz, 1.0)
	var cr := _highpass(_white(n), 1800.0)
	var b := PackedFloat32Array()
	b.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / SR
		ph += (70.0 * exp(-t * 6.0) + 30.0) / SR
		b[i] = sin(TAU * ph) * _env(i, 0.004, 0.18) + nz[i] * _env(i, 0.003, 0.12) * 0.8 + cr[i] * _env(i, 0.001, 0.03) * 0.4
	return _norm(b, 0.95)


func _snd_step() -> PackedFloat32Array:
	var n := int(SR * 0.18)
	var b := _lowpass(_white(n), 1400.0)
	for i in n:
		b[i] = b[i] * _env(i, 0.003, 0.03) + sin(TAU * 90.0 * i / SR) * _env(i, 0.002, 0.03) * 0.5
	return _norm(b, 0.8)


func _snd_splash() -> PackedFloat32Array:
	var n := int(SR * 1.6)
	var b := _highpass(_white(n), 700.0)
	b = _lowpass(b, 5000.0)
	for i in n:
		b[i] *= _env(i, 0.012, 0.35)
	for k in 40:
		var st := int(rng.randf_range(0.02, 1.0) * SR)
		var f := rng.randf_range(350.0, 1300.0)
		var dur := int(rng.randf_range(0.02, 0.06) * SR)
		for j in dur:
			if st + j >= n:
				break
			var t := float(j) / SR
			b[st + j] += sin(TAU * f * t * (1.0 + t * 25.0)) * (1.0 - float(j) / dur) * 0.35
	return _norm(b, 0.9)


func _snd_fire() -> PackedFloat32Array:
	var n := SR * 3
	var a := _lowpass(_white(n), 900.0)
	var c := _bandpass(_white(n), 2200.0, 0.8)
	var b := PackedFloat32Array()
	b.resize(n)
	var fl := 0.0
	for i in n:
		fl += (rng.randf() - 0.5) * 0.05
		fl = clamp(fl * 0.999, -0.4, 0.4)
		b[i] = a[i] * (1.0 + fl) * 1.6 + c[i] * 0.5
	for k in 160:
		var st := rng.randi_range(0, n - 400)
		var amp := rng.randf_range(0.2, 0.9)
		for j in 300:
			b[st + j] += (rng.randf() * 2.0 - 1.0) * amp * exp(-j / 40.0)
	return _norm(_loopify(b, 0.4), 0.85)


func _snd_river() -> PackedFloat32Array:
	var n := SR * 4
	var b := _bandpass(_white(n), 900.0, 0.6)
	var c := _bandpass(_white(n), 2600.0, 1.0)
	for i in n:
		var t := float(i) / SR
		b[i] = b[i] * (0.8 + 0.2 * sin(t * 2.3) * sin(t * 0.9)) + c[i] * 0.35 * (0.7 + 0.3 * sin(t * 5.1))
	for k in 260:
		var st := rng.randi_range(0, n - 800)
		var f := rng.randf_range(500.0, 1700.0)
		var dur := rng.randi_range(200, 700)
		for j in dur:
			var t := float(j) / SR
			b[st + j] += sin(TAU * f * t * (1.0 + t * 18.0)) * sin(PI * j / dur) * 0.12
	return _norm(_loopify(b, 0.6), 0.75)


func _snd_bird(kind: int) -> PackedFloat32Array:
	var n := int(SR * 1.3)
	var b := PackedFloat32Array()
	b.resize(n)
	var notes := rng.randi_range(2, 6)
	var t0 := 0.02
	var base := rng.randf_range(2600.0, 4200.0)
	for k in notes:
		var dur := rng.randf_range(0.05, 0.14)
		var f1 := base * rng.randf_range(0.8, 1.25)
		var f2 := f1 * (rng.randf_range(1.15, 1.6) if kind != 1 else rng.randf_range(0.6, 0.85))
		var ph := 0.0
		var st := int(t0 * SR)
		var nd := int(dur * SR)
		for j in nd:
			if st + j >= n:
				break
			var t := float(j) / nd
			var f: float = lerp(f1, f2, t)
			if kind == 2:
				f *= 1.0 + 0.08 * sin(t * TAU * 6.0)
			ph += f / SR
			var e := sin(PI * t)
			b[st + j] += (sin(TAU * ph) + 0.2 * sin(TAU * ph * 2.0)) * e * e
		t0 += dur + rng.randf_range(0.03, 0.12)
	return _norm(b, 0.6)


func _snd_cowbell() -> PackedFloat32Array:
	var n := int(SR * 1.6)
	var b := PackedFloat32Array()
	b.resize(n)
	var parts := [[1.0, 1.0, 0.9], [2.27, 0.6, 0.5], [3.86, 0.45, 0.3], [5.4, 0.3, 0.18], [6.9, 0.2, 0.1]]
	var f0 := 540.0
	for i in n:
		var t := float(i) / SR
		var v := 0.0
		for p in parts:
			v += sin(TAU * f0 * p[0] * t + p[0]) * p[1] * exp(-t / p[2])
		b[i] = v * (1.0 if t > 0.003 else t / 0.003)
	var click := _highpass(_white(400), 2500.0)
	for j in 400:
		b[j] += click[j] * exp(-j / 60.0) * 0.6
	return _norm(b, 0.7)


func _snd_ring() -> PackedFloat32Array:
	var n := int(SR * 1.6)
	var b := PackedFloat32Array()
	b.resize(n)
	var notes := [1046.5, 1318.5, 1568.0, 2093.0]
	for k in notes.size():
		var st := int(k * 0.085 * SR)
		for j in n - st:
			var t := float(j) / SR
			var e := exp(-t / 0.45) * minf(1.0, t / 0.004)
			b[st + j] += (sin(TAU * notes[k] * t) + 0.35 * sin(TAU * notes[k] * 2.0 * t) * exp(-t / 0.15)) * e * 0.4
	return _norm(b, 0.8)


func _snd_whistle() -> PackedFloat32Array:
	var n := int(SR * 1.0)
	var b := _lowpass(_white(n), 3000.0)
	var ph := 0.0
	for i in n:
		var t := float(i) / SR
		var f := 1300.0 + 500.0 * sin(clampf(t / 0.5, 0.0, 1.0) * PI * 0.5) - (300.0 if t > 0.55 else 0.0) * (t - 0.55) * 4.0
		f *= 1.0 + 0.012 * sin(TAU * 5.5 * t)
		ph += f / SR
		var e: float = min(t / 0.05, 1.0) * (1.0 if t < 0.8 else max(0.0, 1.0 - (t - 0.8) / 0.2))
		b[i] = (sin(TAU * ph) * 0.8 + b[i] * 0.08) * e
	return _norm(b, 0.7)


# ---------------------------------------------------------------- arka plan müziği (sonradan, yavaşça üretilir)
func _build_audio() -> void:
	var fx_bus := AudioServer.bus_count
	AudioServer.add_bus(fx_bus)
	AudioServer.set_bus_name(fx_bus, "Efekt")
	var rv := AudioEffectReverb.new()
	rv.room_size = 0.75
	rv.damping = 0.4
	rv.wet = 0.18
	rv.dry = 1.0
	rv.spread = 0.8
	AudioServer.add_bus_effect(fx_bus, rv)
	var mus_bus := AudioServer.bus_count
	AudioServer.add_bus(mus_bus)
	AudioServer.set_bus_name(mus_bus, "Muzik")
	var gen := [
		["wind", _snd_wind, true], ["wind_hi", _snd_wind_hi, true], ["flap", _snd_flap, false],
		["roar", _snd_roar, false], ["thud", _snd_thud, false], ["step", _snd_step, false],
		["splash", _snd_splash, false], ["fire", _snd_fire, true], ["river", _snd_river, true],
		["cowbell", _snd_cowbell, false], ["ring", _snd_ring, false], ["whistle", _snd_whistle, false]]
	var k := 0
	for g in gen:
		sfx[g[0]] = _wav(g[1].call(), g[2])
		k += 1
		load_bar.value = 80.0 + 16.0 * float(k) / gen.size()
		await _yield()
	for i in 3:
		sfx["bird%d" % i] = _wav(_snd_bird(i))
	for i in 10:
		var p := AudioStreamPlayer.new()
		p.bus = "Efekt"
		add_child(p)
		p2d.append(p)
	for i in 12:
		var p := AudioStreamPlayer3D.new()
		p.bus = "Efekt"
		p.unit_size = 18.0
		p.max_distance = 900.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		p3d.append(p)
	wind_lo = _loop_player(sfx.wind)
	wind_hi = _loop_player(sfx.wind_hi)
	fire_snd = _loop_player(sfx.fire)
	river_snd = AudioStreamPlayer3D.new()
	river_snd.stream = sfx.river
	river_snd.unit_size = 30.0
	river_snd.max_distance = 600.0
	river_snd.bus = "Efekt"
	add_child(river_snd)
	river_snd.play()
	fall_snd = AudioStreamPlayer3D.new()
	fall_snd.stream = sfx.river
	fall_snd.pitch_scale = 0.6
	fall_snd.unit_size = 35.0
	fall_snd.max_distance = 900.0
	fall_snd.volume_db = 0.0
	fall_snd.bus = "Efekt"
	add_child(fall_snd)
	fall_snd.play()
	var mrv := AudioEffectReverb.new()
	mrv.room_size = 0.55
	mrv.damping = 0.5
	mrv.wet = 0.22
	mrv.dry = 0.9
	mrv.spread = 1.0
	AudioServer.add_bus_effect(mus_bus, mrv)
	_gen_music()


func _loop_player(s: AudioStream) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = s
	p.volume_db = -80.0
	add_child(p)
	p.play()
	return p


func _play2d(name: String, db := 0.0, pitch := 1.0) -> void:
	if not sfx.has(name):
		return
	for p in p2d:
		if not p.playing:
			p.stream = sfx[name]
			p.volume_db = db
			p.pitch_scale = pitch
			p.play()
			return


func _play3d(name: String, pos: Vector3, db := 0.0, pitch := 1.0) -> void:
	if not sfx.has(name):
		return
	for p in p3d:
		if not p.playing:
			p.stream = sfx[name]
			p.volume_db = db
			p.pitch_scale = pitch
			p.global_position = pos
			p.play()
			return


func _splash(pos: Vector3, size: float) -> void:
	splash_p.global_position = pos
	splash_p.amount_ratio = clamp(size, 0.2, 1.0)
	splash_p.restart()
	splash_p.emitting = true
	_play3d("splash", pos, linear_to_db(clamp(size, 0.2, 1.0)) + 4.0, rng.randf_range(0.85, 1.1))


func _dust(pos: Vector3, size: float) -> void:
	if water_at(pos.x, pos.z) > pos.y + 0.5:
		return
	dust_p.global_position = pos
	dust_p.amount_ratio = clamp(size, 0.2, 1.0)
	dust_p.restart()
	dust_p.emitting = true


func _update_audio(delta: float) -> void:
	var spd := air_speed if mode == 0 else 2.0
	var alt := cam.global_position.y
	var k: float = clamp(spd / 75.0, 0.0, 1.0)
	var calm: float = 0.06 + clamp((alt - 600.0) / 2000.0, 0.0, 0.25)
	wind_lo.volume_db = linear_to_db(calm + 0.85 * k)
	wind_lo.pitch_scale = 0.7 + 0.7 * k
	var k2: float = clamp((spd - 30.0) / 50.0, 0.0, 1.0)
	if Input.get_action_strength("dalis") > 0.3 and mode == 0:
		k2 = min(1.0, k2 + 0.25)
	wind_hi.volume_db = linear_to_db(0.001 + 0.55 * k2)
	wind_hi.pitch_scale = 0.8 + 0.6 * k2
	fire_snd.volume_db = lerp(fire_snd.volume_db, 2.0 if firing else -60.0, clamp(delta * 10.0, 0.0, 1.0))
	audio_tick -= delta
	if audio_tick <= 0.0:
		audio_tick = 0.4
		var c := cam.global_position
		var best := INF
		var bp := Vector3.ZERO
		for rvr in rivers:
			for p in rvr.pts:
				var d := c.distance_squared_to(p)
				if d < best:
					best = d
					bp = p
		river_snd.global_position = bp
		best = INF
		for w in waterfalls:
			var d := c.distance_squared_to(w)
			if d < best:
				best = d
				bp = w
		fall_snd.global_position = bp
	var day: float = sky_mat.get_shader_parameter("day")
	bird_t -= delta
	if bird_t <= 0.0:
		bird_t = rng.randf_range(0.8, 3.5)
		var c := cam.global_position
		if c.y - h_at(c.x, c.z) < 160.0 and day > 0.5:
			var o := Vector3(rng.randf_range(-60, 60), rng.randf_range(5, 25), rng.randf_range(-60, 60))
			_play3d("bird%d" % rng.randi_range(0, 2), c + o, -6.0, rng.randf_range(0.9, 1.15))
	AudioServer.set_bus_volume_db(0, linear_to_db(max(settings.vol, 0.001)))
	var mb := AudioServer.get_bus_index("Muzik")
	AudioServer.set_bus_mute(mb, not settings.music)
	_music_update(delta)

# ============================================================================
#  ARAYÜZ — HUD, pusula, mini harita, yardım, duraklatma menüsü
# ============================================================================
var map_tex: ImageTexture
var msg_t := 0.0
var finish_time := 0.0
var grass_on := true
var grass_radius := 95.0

func _make_map_image() -> void:
	var s := N - 1
	map_img = Image.create(s, s, false, Image.FORMAT_RGB8)
	var L := Vector3(-0.6, 0.75, -0.4).normalized()
	for z in s:
		for x in s:
			var k := z * N + x
			var h := hmap[k]
			var n := _grid_n(x, z)
			var c: Color
			var wl: float = max(WATER_Y, rwh[k])
			if wl > h + 0.3:
				c = Color(0.2, 0.45, 0.6).lerp(Color(0.08, 0.22, 0.38), clamp((wl - h) / 40.0, 0.0, 1.0))
			else:
				c = Color(0.33, 0.5, 0.18).lerp(Color(0.5, 0.52, 0.32), clamp((h - 600.0) / 900.0, 0.0, 1.0))
				c = c.lerp(Color(0.13, 0.27, 0.12), fmask[k] * 0.85)
				c = c.lerp(Color(0.52, 0.5, 0.47), clamp((1.0 - n.y - 0.3) * 5.0, 0.0, 1.0))
				c = c.lerp(Color(0.95, 0.96, 1.0), clamp((h - SNOW_Y + 100.0) / 200.0, 0.0, 1.0) * clamp((0.6 - (1.0 - n.y)) * 3.0, 0.0, 1.0))
				var sh: float = clamp(0.35 + n.dot(L) * 0.85, 0.45, 1.15)
				c = c * sh
			map_img.set_pixel(x, z, c)
	map_tex = ImageTexture.create_from_image(map_img)


func _panel_style(alpha := 0.45) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.05, 0.06, alpha)
	sb.set_corner_radius_all(10)
	sb.border_color = Color(1.0, 0.8, 0.45, 0.35)
	sb.set_border_width_all(1)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


func _bar(col: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(240, 12)
	b.show_percentage = false
	b.max_value = 1.0
	var f := StyleBoxFlat.new()
	f.bg_color = col
	f.set_corner_radius_all(4)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.5)
	bg.set_corner_radius_all(4)
	b.add_theme_stylebox_override("fill", f)
	b.add_theme_stylebox_override("background", bg)
	return b


func _build_hud() -> void:
	_make_map_image()
	hud = CanvasLayer.new()
	hud.layer = 10
	add_child(hud)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(root)
	ui.root = root
	# nişangah + burun işareti
	var over := Control.new()
	over.set_anchors_preset(Control.PRESET_FULL_RECT)
	over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	over.draw.connect(_draw_overlay.bind(over))
	root.add_child(over)
	ui.over = over
	# sol alt: hız, irtifa, barlar
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style())
	p.anchor_top = 1.0
	p.anchor_bottom = 1.0
	p.offset_left = 28
	p.offset_bottom = -28
	p.offset_top = -28
	p.grow_vertical = Control.GROW_DIRECTION_BEGIN
	if touch_on:
		p.anchor_top = 0.0
		p.anchor_bottom = 0.0
		p.offset_top = 165
		p.offset_bottom = 165
		p.grow_vertical = Control.GROW_DIRECTION_END
	root.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	ui.state = _label("", 20, Color(1.0, 0.85, 0.55))
	v.add_child(ui.state)
	ui.speed = _label("", 30)
	v.add_child(ui.speed)
	ui.alt = _label("", 22, Color(0.85, 0.92, 1.0))
	v.add_child(ui.alt)
	var h1 := HBoxContainer.new()
	h1.add_child(_label("GÜÇ  ", 16, Color(1.0, 0.8, 0.4)))
	ui.stam = _bar(Color(1.0, 0.72, 0.2))
	h1.add_child(ui.stam)
	v.add_child(h1)
	var h2 := HBoxContainer.new()
	h2.add_child(_label("ATEŞ ", 16, Color(1.0, 0.5, 0.3)))
	ui.fire = _bar(Color(1.0, 0.35, 0.1))
	h2.add_child(ui.fire)
	v.add_child(h2)
	# sol üst: halkalar ve saat
	var p2 := PanelContainer.new()
	p2.add_theme_stylebox_override("panel", _panel_style())
	p2.position = Vector2(28, 24)
	root.add_child(p2)
	var v2 := VBoxContainer.new()
	p2.add_child(v2)
	ui.rings = _label("", 26, Color(1.0, 0.82, 0.35))
	v2.add_child(ui.rings)
	ui.clock = _label("", 18, Color(0.85, 0.9, 0.95))
	v2.add_child(ui.clock)
	ui.near = _label("", 16, Color(0.9, 0.85, 0.7))
	v2.add_child(ui.near)
	# pusula
	var comp := Control.new()
	comp.custom_minimum_size = Vector2(640, 46)
	comp.set_anchors_preset(Control.PRESET_CENTER_TOP)
	comp.offset_left = -320
	comp.offset_right = 320
	comp.offset_top = 18
	comp.offset_bottom = 64
	comp.draw.connect(_draw_compass.bind(comp))
	root.add_child(comp)
	ui.compass = comp
	# mini harita
	var mm := Control.new()
	mm.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	mm.offset_left = -310
	mm.offset_right = -30
	mm.offset_top = 24
	mm.offset_bottom = 304
	mm.draw.connect(_draw_minimap.bind(mm, false))
	root.add_child(mm)
	ui.mini = mm
	# büyük harita
	var bm := Control.new()
	bm.set_anchors_preset(Control.PRESET_CENTER)
	bm.offset_left = -440
	bm.offset_right = 440
	bm.offset_top = -440
	bm.offset_bottom = 440
	bm.visible = false
	bm.draw.connect(_draw_minimap.bind(bm, true))
	root.add_child(bm)
	ui.bigmap = bm
	# mesaj
	ui.msg = _label("", 30, Color(1, 0.95, 0.85))
	ui.msg.set_anchors_preset(Control.PRESET_CENTER_TOP)
	ui.msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui.msg.offset_left = -700
	ui.msg.offset_right = 700
	ui.msg.offset_top = 110
	root.add_child(ui.msg)
	# yardım
	var hp_ := PanelContainer.new()
	hp_.add_theme_stylebox_override("panel", _panel_style(0.75))
	hp_.set_anchors_preset(Control.PRESET_CENTER)
	hp_.offset_left = -420
	hp_.offset_right = 420
	hp_.offset_top = -270
	hp_.offset_bottom = 250
	hp_.visible = false
	root.add_child(hp_)
	var ht := RichTextLabel.new()
	ht.bbcode_enabled = true
	ht.fit_content = true
	ht.add_theme_font_size_override("normal_font_size", 20)
	ht.add_theme_font_size_override("bold_font_size", 22)
	ht.text = """[center][b][color=#ffd27a]KONTROLLER[/color][/b][/center]
[b]Fare[/b] — bak / ejderhayı yönlendir (nereye bakarsan oraya uçar)
[b]W[/b] — kanat çırp, hızlan        [b]Shift[/b] — güçlü kanat (hız, güç harcar)
[b]S[/b] — fren; yavaşken havada asılı kal (iniş için)
[b]A / D[/b] — yana yatış, takla      [b]Boşluk[/b] — güçlü vuruş / yerden kalkış
[b]Ctrl[/b] — kanatları kapat, dalış (çok hız!)
[b]Sol tık[/b] — ateş püskürt (ağaçlar tutuşur)   [b]Sağ tık / R[/b] — kükre
[b]E[/b] — ejderhadan in / bin       [b]F[/b] — yayayken ejderhayı çağır
[b]1-4 / G[/b] — ejderha türü: Kızıl Alev, Buz Rüzgârı, Zümrüt Dev, Gölge Gece
[b]Tekerlek[/b] — kamera mesafesi   [b]Alt[/b] — serbest bakış
[b]Tab[/b] — büyük harita   [b]T[/b] — zamanı hızlandır   [b]M[/b] — müzik
[b]F2[/b] — grafik kalitesi   [b]F11[/b] — tam ekran   [b]Esc[/b] — menü

[color=#ffd27a]Görev:[/color] Vadiye saçılmış 25 altın halkanın içinden geç.
[color=#aaccff]İpucu:[/color] Yavaşken (S) yere yaklaşırsan ejderha iner. Yüksekten dalıp hız kazan, sonra kanat aç ve süzül. Suya yüksek hızda yakın uçarsan su yüzeyini sıyırırsın.
[center][color=#999999]F1 ile kapat • Oyun kolu da desteklenir[/color][/center]"""
	if touch_on:
		ht.text = """[center][b][color=#ffd27a]DOKUNMATİK KONTROLLER[/color][/b][/center]
[b]Sol alttaki joystick[/b] — ileri: kanat çırp / hızlan, geri: fren (yavaşken havada asılı kal), sağ-sol: yatış. Yayayken yürü.
[b]Ekranın geri kalanında parmağını sürükle[/b] — bak ve ejderhayı yönlendir (nereye bakarsan oraya uçar).
[b]ATEŞ[/b] — basılı tut, ateş püskür   [b]KANAT[/b] — güçlü vuruş / yerden kalkış
[b]DALIŞ[/b] — basılı tut, kanatları kapat   [b]HIZ[/b] — aç/kapa, güçlü kanat
[b]KÜKRE[/b] — kükre   [b]İN/BİN[/b] — ejderhadan in / bin   [b]ÇAĞIR[/b] — ejderhayı yanına çağır
[b]TÜR[/b] — ejderha türünü değiştir   [b]HARİTA[/b] — büyük harita   [b]☰[/b] — menü (grafik kalitesi, ses)

[color=#ffd27a]Görev:[/color] Vadiye saçılmış 25 altın halkanın içinden geç.
[color=#aaccff]İpucu:[/color] Joystick'i geri çekip yavaşlayınca yere yaklaşırsan ejderha iner. Bluetooth oyun kolu da çalışır.
[center][color=#999999]Kapatmak için ekrana dokun[/color][/center]"""
	hp_.add_child(ht)
	ui.help = hp_
	_build_pause_menu(root)


func _build_pause_menu(root: Control) -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.visible = false
	root.add_child(dim)
	ui.pause = dim
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", _panel_style(0.85))
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.offset_left = -300
	pc.offset_right = 300
	pc.offset_top = -335
	pc.offset_bottom = 335
	dim.add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	pc.add_child(v)
	var t := _label("DURAKLATILDI", 40, Color(1.0, 0.85, 0.55))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var b1 := _button("Devam Et")
	b1.pressed.connect(_toggle_pause)
	v.add_child(b1)
	var bd := _button("Ejderha: " + sp().name)
	bd.pressed.connect(func():
		if mode == 0:
			_set_species((cur_species + 1) % SPECIES.size())
		bd.text = "Ejderha: " + sp().name)
	v.add_child(bd)
	var bq := _button("Grafik: " + QUALITY_NAMES[settings.quality])
	bq.pressed.connect(func():
		settings.quality = (settings.quality + 1) % 4
		bq.text = "Grafik: " + QUALITY_NAMES[settings.quality]
		_apply_quality()
		_save_settings())
	v.add_child(bq)
	v.add_child(_label("Fare hassasiyeti", 18))
	var sl := HSlider.new()
	sl.min_value = 0.0005
	sl.max_value = 0.006
	sl.step = 0.0001
	sl.value = settings.sens
	sl.custom_minimum_size = Vector2(500, 28)
	sl.value_changed.connect(func(x):
		settings.sens = x
		_save_settings())
	v.add_child(sl)
	v.add_child(_label("Ses seviyesi", 18))
	var vs := HSlider.new()
	vs.min_value = 0.0
	vs.max_value = 1.0
	vs.step = 0.01
	vs.value = settings.vol
	vs.custom_minimum_size = Vector2(500, 28)
	vs.value_changed.connect(func(x):
		settings.vol = x
		_save_settings())
	v.add_child(vs)
	var ci := CheckButton.new()
	ci.text = "Y eksenini ters çevir"
	ci.button_pressed = settings.invert
	ci.add_theme_font_size_override("font_size", 20)
	ci.toggled.connect(func(x):
		settings.invert = x
		_save_settings())
	v.add_child(ci)
	var cm := CheckButton.new()
	cm.text = "Müzik"
	cm.button_pressed = settings.music
	cm.add_theme_font_size_override("font_size", 20)
	cm.toggled.connect(func(x):
		settings.music = x
		_save_settings())
	v.add_child(cm)
	var bx := _button("Oyundan Çık")
	bx.pressed.connect(func(): get_tree().quit())
	v.add_child(bx)


func _button(t: String) -> Button:
	var b := Button.new()
	b.text = t
	b.custom_minimum_size = Vector2(500, 52)
	b.add_theme_font_size_override("font_size", 24)
	return b


func _msg(t: String, dur := 2.5) -> void:
	if not ui.has("msg"):
		return
	ui.msg.text = t
	msg_t = dur


func _update_ui(delta: float) -> void:
	msg_t -= delta
	ui.msg.modulate.a = 0.0 if ui.bigmap.visible else clamp(msg_t / 0.6, 0.0, 1.0)
	var spd := air_speed if mode == 0 else Vector2(f_vel.x, f_vel.z).length()
	ui.speed.text = "%d km/sa" % int(spd * 3.6)
	var p := d_pos if mode == 0 else f_pos
	var ground := h_at(p.x, p.z)
	ui.alt.text = "İrtifa %d m   •   Yerden %d m" % [int(p.y), int(max(0.0, p.y - max(ground, water_at(p.x, p.z))))]
	var st := ""
	if mode == 1:
		st = "YAYA"
	elif calling:
		st = "EJDERHA GELİYOR"
	elif d_state == "ucus":
		if stalled:
			st = "⚠ HIZ KAYBI — dalışa geç!"
		elif hover_mix > 0.5:
			st = "HAVADA ASILI"
		elif wing_fold > 0.5:
			st = "DALIŞ"
		elif flap_power > 0.05:
			st = "KANAT ÇIRPIYOR"
		else:
			st = "SÜZÜLÜYOR"
	elif d_state == "yer":
		st = "YERDE"
	else:
		st = "YÜZÜYOR"
	ui.state.text = st + "   •   " + sp().name
	ui.stam.value = stamina
	ui.fire.value = fire_fuel
	ui.rings.text = "Altın Halkalar  %d / %d" % [rings_got, rings.size()]
	var hh := int(time_of_day)
	var mn := int((time_of_day - hh) * 60.0)
	var tt := finish_time if finished else game_time
	ui.clock.text = "Saat %02d:%02d   •   Süre %d:%02d" % [hh, mn, int(tt) / 60, int(tt) % 60]
	var nr = _nearest_ring()
	if nr:
		ui.near.text = "En yakın halka: %d m" % int(p.distance_to(nr.pos))
	else:
		ui.near.text = "Tüm halkalar toplandı!"
	ui.compass.queue_redraw()
	ui.mini.queue_redraw()
	ui.over.queue_redraw()
	if ui.bigmap.visible:
		ui.bigmap.queue_redraw()


func _nearest_ring():
	var p := d_pos if mode == 0 else f_pos
	var best = null
	var bd := INF
	for r in rings:
		if r.got:
			continue
		var d := p.distance_to(r.pos)
		if d < bd:
			bd = d
			best = r
	return best


func _draw_overlay(c: Control) -> void:
	var sz := c.size
	var ctr := sz * 0.5
	if mode == 0 and d_state == "ucus":
		c.draw_arc(ctr, 10.0, 0, TAU, 24, Color(1, 1, 1, 0.55), 2.0, true)
		var nose := d_pos + (-d_basis.z) * 250.0
		if not cam.is_position_behind(nose):
			var sp := cam.unproject_position(nose) * (sz / Vector2(get_viewport().get_visible_rect().size))
			c.draw_circle(sp, 4.0, Color(1.0, 0.75, 0.3, 0.9))
			c.draw_arc(sp, 14.0, 0, TAU, 24, Color(1.0, 0.75, 0.3, 0.6), 2.0, true)
	elif mode == 1:
		c.draw_circle(ctr, 2.5, Color(1, 1, 1, 0.6))
	# halka işaretleri
	var vs := Vector2(get_viewport().get_visible_rect().size)
	for r in rings:
		if r.got:
			continue
		var d: float = cam.global_position.distance_to(r.pos)
		if d > 2500.0 or cam.is_position_behind(r.pos):
			continue
		var sp := cam.unproject_position(r.pos) * (sz / vs)
		var a: float = clamp(1.0 - d / 2500.0, 0.25, 1.0)
		c.draw_arc(sp, 7.0, 0, TAU, 16, Color(1.0, 0.8, 0.3, a), 2.0, true)
		c.draw_string(ThemeDB.fallback_font, sp + Vector2(10, 5), "%d m" % int(d), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.85, 0.5, a))
	if mode == 1 and not cam.is_position_behind(d_pos + Vector3(0, 4, 0)):
		var sp := cam.unproject_position(d_pos + Vector3(0, 5, 0)) * (sz / vs)
		c.draw_string(ThemeDB.fallback_font, sp - Vector2(40, 0), "Ejderha", HORIZONTAL_ALIGNMENT_CENTER, 80, 16, Color(1.0, 0.6, 0.4, 0.8))


func _draw_compass(c: Control) -> void:
	var w := c.size.x
	var h := c.size.y
	c.draw_rect(Rect2(Vector2.ZERO, c.size), Color(0, 0, 0, 0.35))
	var fwd := -cam.global_transform.basis.z
	var heading := atan2(fwd.x, -fwd.z)
	var span := PI * 0.9
	var names := {0: "K", 45: "KD", 90: "D", 135: "GD", 180: "G", 225: "GB", 270: "B", 315: "KB"}
	for deg in range(0, 360, 15):
		var a := deg_to_rad(deg)
		var diff := wrapf(a - heading, -PI, PI)
		if abs(diff) > span * 0.5:
			continue
		var x := w * 0.5 + diff / span * w
		if names.has(deg):
			var col := Color(1.0, 0.45, 0.35) if deg == 0 else Color(1, 1, 1, 0.9)
			c.draw_string(ThemeDB.fallback_font, Vector2(x - 25, h * 0.62), names[deg], HORIZONTAL_ALIGNMENT_CENTER, 50, 20, col)
		else:
			c.draw_line(Vector2(x, h * 0.25), Vector2(x, h * 0.5), Color(1, 1, 1, 0.5), 1.0)
	var p := d_pos if mode == 0 else f_pos
	var nr = _nearest_ring()
	if nr:
		var d: Vector3 = nr.pos - p
		var a := atan2(d.x, -d.z)
		var diff := wrapf(a - heading, -PI, PI)
		var x: float = clamp(w * 0.5 + diff / span * w, 8.0, w - 8.0)
		c.draw_circle(Vector2(x, h - 6), 6.0, Color(1.0, 0.8, 0.3))
	c.draw_line(Vector2(w * 0.5, 0), Vector2(w * 0.5, h), Color(1.0, 0.8, 0.4, 0.9), 2.0)


func _draw_minimap(c: Control, big: bool) -> void:
	var sz := c.size
	var p := d_pos if mode == 0 else f_pos
	var mpp := (WORLD / (N - 1))
	var span := WORLD if big else 1600.0
	var src_c := Vector2(p.x, p.z) / mpp
	var half := span / mpp * 0.5
	var src := Rect2(src_c - Vector2(half, half), Vector2(half, half) * 2.0)
	if big:
		src = Rect2(Vector2.ZERO, Vector2(N - 1, N - 1))
	c.draw_rect(Rect2(Vector2(-4, -4), sz + Vector2(8, 8)), Color(0.05, 0.05, 0.05, 0.85))
	c.draw_texture_rect_region(map_tex, Rect2(Vector2.ZERO, sz), src)
	c.draw_rect(Rect2(Vector2.ZERO, sz), Color(1.0, 0.8, 0.45, 0.6), false, 2.0)
	var to_screen := func(w: Vector3) -> Vector2:
		return (Vector2(w.x, w.z) / mpp - src.position) / src.size * sz
	var inside := func(s: Vector2) -> bool:
		return s.x >= 0 and s.y >= 0 and s.x <= sz.x and s.y <= sz.y
	for v in village_sites:
		var s: Vector2 = to_screen.call(v)
		if inside.call(s):
			c.draw_rect(Rect2(s - Vector2(4, 4), Vector2(8, 8)), Color(0.95, 0.9, 0.8))
	for r in rings:
		if r.got:
			continue
		var s: Vector2 = to_screen.call(r.pos)
		if inside.call(s):
			c.draw_circle(s, 6.0 if big else 4.5, Color(1.0, 0.78, 0.25))
	if mode == 1:
		var s: Vector2 = to_screen.call(d_pos)
		if inside.call(s):
			c.draw_circle(s, 6.0, Color(0.9, 0.25, 0.15))
	var me: Vector2 = to_screen.call(p)
	var fwd := -cam.global_transform.basis.z if mode == 1 else -d_basis.z
	var a := Vector2(fwd.x, fwd.z).normalized()
	if a.length() < 0.1:
		a = Vector2(0, -1)
	var perp := Vector2(-a.y, a.x)
	var k := 12.0 if big else 9.0
	c.draw_colored_polygon(PackedVector2Array([me + a * k, me - a * k * 0.6 + perp * k * 0.6, me - a * k * 0.3, me - a * k * 0.6 - perp * k * 0.6]), Color(1.0, 0.3, 0.2))
	if big:
		c.draw_string(ThemeDB.fallback_font, Vector2(12, 28), "ALP VADİSİ — Tab ile kapat", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1, 0.9, 0.7))
	else:
		c.draw_string(ThemeDB.fallback_font, Vector2(sz.x * 0.5 - 6, 18), "K", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 0.5, 0.4))


# ---------------------------------------------------------------- halka toplama
func _check_rings() -> void:
	var p := d_pos if mode == 0 else f_pos
	for r in rings:
		if r.got:
			r.node.scale = r.node.scale.move_toward(Vector3.ZERO, get_process_delta_time() * 2.0)
			if r.node.scale.x <= 0.001:
				r.node.visible = false
			continue
		r.t += get_process_delta_time()
		if p.distance_to(r.pos) < 14.0 and mode == 0:
			r.got = true
			rings_got += 1
			spark_p.global_position = r.pos
			spark_p.restart()
			spark_p.emitting = true
			_play2d("ring", 0.0, 1.0)
			stamina = min(1.0, stamina + 0.35)
			fire_fuel = 1.0
			if rings_got >= rings.size():
				finished = true
				finish_time = game_time
				_msg("TEBRİKLER! Tüm halkaları %d:%02d sürede topladın!" % [int(game_time) / 60, int(game_time) % 60], 8.0)
				_play2d("roar", 2.0, 1.0)
			else:
				_msg("Halka %d / %d  (+güç, +ateş)" % [rings_got, rings.size()], 2.0)


# ---------------------------------------------------------------- dünya güncellemesi
func _update_world(delta: float) -> void:
	var c := cam.global_position
	var alt := c.y - h_at(c.x, c.z)
	grass_mmi.visible = grass_on and alt < 260.0
	if grass_mmi.visible:
		grass_mmi.global_position = Vector3(snappedf(c.x, grass_spacing), 0, snappedf(c.z, grass_spacing))
		var dalt := d_pos.y - h_at(d_pos.x, d_pos.z)
		var push := 0.0
		if mode == 0 and d_state == "ucus" and dalt < 30.0:
			push = (1.0 - dalt / 30.0) * clamp(flap_amp, 0.2, 1.0) * 1.2
		grass_mat.set_shader_parameter("push_pos", d_pos)
		grass_mat.set_shader_parameter("push_amt", push)
	var threat := d_pos if (mode == 0 or calling) else f_pos
	_update_birds(delta, d_pos)
	_update_cows(delta, threat)
	_update_burning(delta)
	_update_dancers(delta)
	for w in wilds:
		_update_wild(w, delta)
	for r in rings:
		if not r.got:
			r.node.rotate_object_local(Vector3.UP, delta * 0.6)
	# su püskürtmesi
	var wl := water_at(d_pos.x, d_pos.z)
	var above := d_pos.y - wl
	var over_water := wl > h_at(d_pos.x, d_pos.z) + 1.0
	spray_p.emitting = over_water and d_state == "ucus" and above < 9.0 and air_speed > 14.0
	if spray_p.emitting:
		spray_p.global_position = Vector3(d_pos.x, wl + 0.3, d_pos.z) - d_vel.normalized() * 6.0
	if d_state == "su":
		spray_p.emitting = air_speed > 3.0
		spray_p.global_position = Vector3(d_pos.x, wl + 0.2, d_pos.z)


# ---------------------------------------------------------------- grafik kalitesi
func _apply_quality() -> void:
	var q: int = settings.quality
	var vp := get_viewport()
	env.sdfgi_enabled = q == 0
	env.volumetric_fog_enabled = q <= 1
	env.ssao_enabled = q <= 2
	vp.msaa_3d = [Viewport.MSAA_4X, Viewport.MSAA_2X, Viewport.MSAA_DISABLED, Viewport.MSAA_DISABLED][q]
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if q >= 2 else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2 if q == 3 else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 0.75 if q == 3 else 1.0
	if _mob():
		# mobil görüntü motoru: SDFGI / hacimsel sis / SSAO yok, FSR1 ile ölçekleme
		env.sdfgi_enabled = false
		env.volumetric_fog_enabled = false
		env.ssao_enabled = false
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		vp.msaa_3d = [Viewport.MSAA_4X, Viewport.MSAA_2X, Viewport.MSAA_2X, Viewport.MSAA_DISABLED][q]
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
		vp.scaling_3d_scale = [0.9, 0.8, 0.7, 0.6][q]
	sun.directional_shadow_max_distance = [2200.0, 1600.0, 1000.0, 600.0][q]
	RenderingServer.directional_shadow_atlas_set_size([8192, 4096, 4096, 2048][q], true)
	grass_on = q <= 2
	grass_radius = [95.0, 80.0, 55.0, 0.0][q]
	if _mob():
		grass_radius = [70.0, 60.0, 45.0, 0.0][q]
	if grass_mat:
		grass_mat.set_shader_parameter("radius", grass_radius)
	water_mat.set_shader_parameter("ssr_steps", [48, 40, 24, 0][q])
	river_mat.set_shader_parameter("ssr_steps", [32, 24, 0, 0][q])
	for pair in tree_mmis:
		if pair == null:
			continue
		pair[0].visibility_range_end = [1400.0, 1150.0, 900.0, 650.0][q]
		pair[1].visibility_range_begin = pair[0].visibility_range_end
		pair[1].visibility_range_end = [4500.0, 3600.0, 2800.0, 2000.0][q]
		pair[0].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if q <= 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


# ============================================================================
#  ENGELLER (ağaç gövdeleri / taçları, binalar) — kamera, yürüme ve uçuş için
# ============================================================================
func _add_bld(p: Vector3, r: float, top: float) -> void:
	var k := Vector2i(int(p.x / 32.0), int(p.z / 32.0))
	if not bld_grid.has(k):
		bld_grid[k] = []
	bld_grid[k].append(Vector4(p.x, p.z, r, p.y + top))


# p noktası bir engelin içinde mi? (taç=true ise ağaç tacı, değilse gövde)
func _obstacle_at(p: Vector3, crown: bool, pad := 0.0) -> Vector4:
	var gk := Vector2i(int(p.x / 32.0), int(p.z / 32.0))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var key := gk + Vector2i(dx, dz)
			if tree_grid.has(key):
				for id in tree_grid[key]:
					var tp: Vector3 = tree_pos[id]
					var sz: float = tree_size[id]
					var r: float = (sz * (0.24 if tree_kind[id] == 0 else 0.36) if crown else 0.6) + pad
					var dd := Vector2(tp.x - p.x, tp.z - p.z).length()
					if dd < r and p.y < tp.y + sz and p.y > tp.y - 1.0:
						return Vector4(tp.x, tp.z, r, tp.y + sz)
			if bld_grid.has(key):
				for b in bld_grid[key]:
					var dd := Vector2(b.x - p.x, b.y - p.z).length()
					if dd < b.z + pad and p.y < b.w:
						return Vector4(b.x, b.y, b.z + pad, b.w)
	return Vector4(0, 0, -1, 0)


func _push_out(p: Vector3, pad: float) -> Vector3:
	for i in 3:
		var o := _obstacle_at(p, false, pad)
		if o.z < 0.0:
			break
		var d := Vector2(p.x - o.x, p.z - o.y)
		if d.length() < 0.01:
			d = Vector2(1, 0)
		var q := Vector2(o.x, o.y) + d.normalized() * (o.z + 0.05)
		p.x = q.x
		p.z = q.y
	return p


func _cam_collide(target: Vector3, cp: Vector3) -> Vector3:
	if target.y - h_at(target.x, target.z) > 45.0 and cp.y - h_at(cp.x, cp.z) > 45.0:
		return cp
	var d := cp - target
	var L := d.length()
	if L < 0.1:
		return cp
	var dir := d / L
	var t := 2.0
	while t < L:
		var q := target + dir * t
		if _obstacle_at(q, true, 0.5).z >= 0.0:
			return target + dir * max(1.5, t - 1.5)
		t += 1.5
	return cp


func _yield() -> void:
	await get_tree().process_frame


func _freeze(id: int) -> void:
	if tree_burn[id] < 0.0:
		return
	tree_burn[id] = -1.0
	_tree_set_color(id, Color(1.9, 2.2, 2.6))


# ============================================================================
#  MÜZİK v1.1 — ortaçağ taverna / köy şenliği müzikleri
#  Flüt (kaval), lavta (Karplus-Strong), gayda (nağme + dem), bendir, def, el çırpma.
#  Üç parça arka planda (ayrı iş parçacığında) sentezlenir:
#   "ucus"    — 6/8 neşeli jig, uçarken
#   "koy"     — hızlı gaydalı şenlik havası, köylerin yakınında (gündüz)
#   "taverna" — 3/4 lavta valsi, gece ve köylerde akşam
# ============================================================================
const MSR := 22050
const M_DORIAN := [0, 2, 3, 5, 7, 9, 10]
const M_MIXO := [0, 2, 4, 5, 7, 9, 10]
const M_AEOL := [0, 2, 3, 5, 7, 8, 10]

var mus_players := {}
var mus_vol := {}
var mus_ready := {}
var mus_mutex := Mutex.new()
var mus_thread: Thread
var mus_track := "ucus"
var _mus_abort := false
var _mL := PackedFloat32Array()
var _mR := PackedFloat32Array()
var _mT := 1
var _mr := RandomNumberGenerator.new()
var _tab_flute := PackedFloat32Array()
var _tab_reed := PackedFloat32Array()


func _gen_music() -> void:
	_tab_flute = _wavetable([1.0, 0.12, 0.05, 0.02])
	var reed := []
	for h in range(1, 16):
		var a := 1.0 / h * (1.0 if h % 2 == 1 else 0.5)
		if h >= 3 and h <= 6:
			a *= 1.6
		reed.append(a)
	_tab_reed = _wavetable(reed)
	_mr.seed = 4242
	mus_thread = Thread.new()
	mus_thread.start(_music_worker)


func _exit_tree() -> void:
	_mus_abort = true
	if mus_thread and mus_thread.is_started():
		mus_thread.wait_to_finish()


func _wavetable(h: Array) -> PackedFloat32Array:
	var n := 1024
	var t := PackedFloat32Array()
	t.resize(n)
	var m := 0.0001
	for i in n:
		var v := 0.0
		for k in h.size():
			v += sin(TAU * (k + 1) * i / n + k * 0.7) * h[k]
		t[i] = v
		m = maxf(m, absf(v))
	for i in n:
		t[i] /= m
	return t


func _music_worker() -> void:
	for name in ["ucus", "koy", "taverna"]:
		if _mus_abort:
			return
		var w: AudioStreamWAV
		if name == "ucus":
			w = _song_jig()
		elif name == "koy":
			w = _song_reel()
		else:
			w = _song_waltz()
		if w == null:
			return
		mus_mutex.lock()
		mus_ready[name] = w
		mus_mutex.unlock()


# ---------------------------------------------------------------- yardımcılar
func _deg_hz(root: int, md: Array, deg: int) -> float:
	var i := deg - 1
	var o := floori(i / 7.0)
	var k := i - o * 7
	return 440.0 * pow(2.0, (root + o * 12 + md[k] - 69) / 12.0)


func _mus_begin(seconds: float) -> void:
	_mT = int(seconds * MSR)
	_mL = PackedFloat32Array()
	_mR = PackedFloat32Array()
	_mL.resize(_mT)
	_mR.resize(_mT)


func _pan(vel: float, pan: float) -> Vector2:
	return Vector2(vel * sqrt(0.5 - pan * 0.5), vel * sqrt(0.5 + pan * 0.5))


# melodi satırlarını [adım, uzunluk, derece] listesine çevirir
func _parse(bars: Array) -> Array:
	var toks: Array = []
	for b in bars:
		for t in b.split(" ", false):
			toks.append(t)
	var out: Array = []
	for i in toks.size():
		var t: String = toks[i]
		if t == "x" or t == "r":
			continue
		var n := 1
		while i + n < toks.size() and toks[i + n] == "x":
			n += 1
		out.append([i, n, int(t)])
	return out


func _mus_finish(gain := 0.8) -> AudioStreamWAV:
	var m := 0.0001
	for i in _mT:
		m = maxf(m, maxf(absf(_mL[i]), absf(_mR[i])))
	var k := gain / m
	var bytes := PackedByteArray()
	bytes.resize(_mT * 4)
	for i in _mT:
		bytes.encode_s16(i * 4, int(tanh(_mL[i] * k * 1.1) * 30000.0))
		bytes.encode_s16(i * 4 + 2, int(tanh(_mR[i] * k * 1.1) * 30000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = MSR
	w.stereo = true
	w.data = bytes
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = _mT
	_mL = PackedFloat32Array()
	_mR = PackedFloat32Array()
	return w


# ---------------------------------------------------------------- çalgılar
# Flüt / kaval (dalga tablosu + nefes gürültüsü + gecikmeli vibrato)
func _i_flute(t0: float, dur: float, hz: float, vel: float, pan: float) -> void:
	var s0 := int(t0 * MSR)
	var rel := 0.07
	var n := int((dur + rel) * MSR)
	var g := _pan(vel, pan)
	var TN := _tab_flute.size()
	var ph := _mr.randf() * TN
	var inc := hz * TN / MSR
	var nz := 0.0
	for k in n:
		var t := float(k) / MSR
		var env: float
		if t < 0.03:
			env = t / 0.03
		elif t < dur:
			env = 1.0 - 0.18 * (t - 0.03) / maxf(dur, 0.05)
		else:
			env = 0.82 * (1.0 - (t - dur) / rel)
		var vib := 1.0 + 0.006 * sin(TAU * 5.4 * t) * clampf((t - 0.15) * 4.0, 0.0, 1.0)
		ph += inc * vib
		if ph >= TN:
			ph -= TN
		nz += 0.3 * ((_mr.randf() - 0.5) - nz)
		var chiff := 0.6 if t < 0.025 else 0.1
		var v := (_tab_flute[int(ph)] + nz * chiff) * env
		var o := (s0 + k) % _mT
		_mL[o] += v * g.x
		_mR[o] += v * g.y


# Kamış sesi (gayda nağmesi / dem). lp: parlaklık 0..1
func _i_reed(t0: float, dur: float, hz: float, vel: float, pan: float, att := 0.012, rel := 0.03, lp := 0.5) -> void:
	var s0 := int(t0 * MSR)
	var n := int((dur + rel) * MSR)
	var g := _pan(vel, pan)
	var TN := _tab_reed.size()
	var ph := _mr.randf() * TN
	var inc := hz * TN / MSR
	var y := 0.0
	for k in n:
		var t := float(k) / MSR
		var env := 1.0
		if att > 0.0 and t < att:
			env = t / att
		elif t > dur:
			env = 1.0 - (t - dur) / rel
		ph += inc
		if ph >= TN:
			ph -= TN
		y += lp * (_tab_reed[int(ph)] - y)
		var v := y * env
		var o := (s0 + k) % _mT
		_mL[o] += v * g.x
		_mR[o] += v * g.y


# Lavta: Karplus-Strong telli çalgı
func _i_lute(t0: float, hz: float, vel: float, pan: float, dur := 1.5, bright := 0.55) -> void:
	var s0 := int(t0 * MSR)
	var P := maxi(2, int(round(MSR / hz - 0.5)))
	var buf := PackedFloat32Array()
	buf.resize(P)
	var y := 0.0
	for k in P:
		y += bright * ((_mr.randf() * 2.0 - 1.0) - y)
		buf[k] = y * 1.6
	var n := int(dur * MSR)
	var g := _pan(vel, pan)
	var idx := 0
	var damp := 0.4985 if hz < 300.0 else 0.4975
	for k in n:
		var a := buf[idx]
		var nx := idx + 1
		if nx == P:
			nx = 0
		buf[idx] = (a + buf[nx]) * damp
		idx = nx
		var fade := 1.0 if k < n - 400 else float(n - k) / 400.0
		var o := (s0 + k) % _mT
		_mL[o] += a * g.x * fade
		_mR[o] += a * g.y * fade


# Bendir / bodhran
func _i_drum(t0: float, vel: float, pan: float, pitch := 1.0) -> void:
	var s0 := int(t0 * MSR)
	var n := int(0.45 * MSR)
	var g := _pan(vel, pan)
	var ph := 0.0
	var nz := 0.0
	for k in n:
		var t := float(k) / MSR
		var f := (55.0 + 90.0 * exp(-t * 28.0)) * pitch
		ph += f / MSR
		nz += 0.2 * ((_mr.randf() * 2.0 - 1.0) - nz)
		var v := sin(TAU * ph) * exp(-t / 0.16) + nz * exp(-t / 0.012) * 0.9
		var o := (s0 + k) % _mT
		_mL[o] += v * g.x
		_mR[o] += v * g.y


# Def / tef zilleri
func _i_tamb(t0: float, vel: float, pan: float) -> void:
	var s0 := int(t0 * MSR)
	var n := int(0.24 * MSR)
	var g := _pan(vel, pan)
	var lp := 0.0
	for k in n:
		var t := float(k) / MSR
		var w := _mr.randf() * 2.0 - 1.0
		lp += 0.35 * (w - lp)
		var hp := w - lp
		var met := sin(TAU * 5300.0 * t) + sin(TAU * 7150.0 * t) * 0.8 + sin(TAU * 8900.0 * t) * 0.6
		var v := (hp * 0.8 + met * 0.25) * exp(-t / 0.055)
		var o := (s0 + k) % _mT
		_mL[o] += v * g.x
		_mR[o] += v * g.y


# El çırpma (birkaç el)
func _i_clap(t0: float, vel: float, pan: float) -> void:
	var s0 := int(t0 * MSR)
	var n := int(0.2 * MSR)
	var g := _pan(vel, pan)
	var lp := 0.0
	var lp2 := 0.0
	for k in n:
		var t := float(k) / MSR
		var w := _mr.randf() * 2.0 - 1.0
		lp += 0.45 * (w - lp)
		lp2 += 0.08 * (lp - lp2)
		var bp := lp - lp2
		var e := exp(-t / 0.05)
		if t < 0.03:
			e = 0.6 + 0.4 * absf(sin(t * PI / 0.0105))
		var o := (s0 + k) % _mT
		_mL[o] += bp * e * g.x
		_mR[o] += bp * e * g.y


func _hz_loop(hz: float, total: float) -> float:
	return round(hz * total) / total


func _strum(t0: float, root: int, md: Array, deg: int, vel: float, pan: float, dur := 1.2) -> void:
	for k in 3:
		_i_lute(t0 + k * 0.014, _deg_hz(root, md, deg + k * 2), vel * (1.0 - k * 0.12), pan + (k - 1) * 0.1, dur, 0.45)


func _jit() -> float:
	return _mr.randf_range(-0.006, 0.006)


# ---------------------------------------------------------------- 1) UÇUŞ — 6/8 jig, Re dorian
func _song_jig() -> AudioStreamWAV:
	var A := ["1 x 3 5 x 3", "4 x 6 5 4 3", "2 x 4 7 x 5", "5 4 3 2 x x",
		"1 x 3 5 x 8", "7 x 5 6 x 4", "5 4 3 2 3 4", "1 x x 1 x x"]
	var B := ["8 x 9 10 x 8", "7 x 8 9 x 7", "6 x 7 8 x 6", "5 4 3 5 x x",
		"8 x 9 10 9 8", "7 x 5 8 x 7", "6 5 4 5 4 3", "1 x x 1 x x"]
	var cA := [1, 4, 7, 5, 1, 7, 5, 1]
	var cB := [1, 7, 4, 5, 1, 7, 4, 1]
	var e := 0.2
	var bar := 6 * e
	var total := 32 * bar
	_mus_begin(total)
	var md := M_DORIAN
	var form := [[A, cA, 0], [A, cA, 1], [B, cB, 2], [B, cB, 3]]
	for sec in form.size():
		if _mus_abort:
			return null
		var notes: Array = _parse(form[sec][0])
		var chords: Array = form[sec][1]
		var pas: int = form[sec][2]
		var t0 := sec * 8 * bar
		for nt in notes:
			var t: float = t0 + nt[0] * e + _jit()
			var dur: float = nt[1] * e * 0.95
			_i_flute(t, dur, _deg_hz(74, md, nt[2]), 0.32, 0.25)
			if pas == 1 or pas == 3:
				_i_lute(t + 0.01, _deg_hz(62, md, nt[2]), 0.2, -0.45, 1.0, 0.7)
		for b in 8:
			var bt := t0 + b * bar
			var r: int = chords[b]
			var arp := [r - 7, r - 5, r - 3, r, r - 3, r - 5]
			for k in 6:
				_i_lute(bt + k * e + _jit(), _deg_hz(50, md, arp[k]), 0.24 if k % 3 == 0 else 0.16, -0.3, 1.1, 0.5)
			_i_drum(bt + _jit(), 0.55, 0.0)
			_i_drum(bt + 3 * e + _jit(), 0.4, 0.0, 1.1)
			if pas >= 1:
				_i_drum(bt + 2 * e + _jit(), 0.15, 0.05, 1.3)
				_i_drum(bt + 5 * e + _jit(), 0.18, 0.05, 1.3)
			if pas >= 2:
				_i_tamb(bt + 3 * e + _jit(), 0.22, 0.4)
				_i_tamb(bt + _jit(), 0.12, 0.4)
	# dem (gayda borusu) — döngüye tam oturan frekans
	_i_reed(0.0, total, _hz_loop(_deg_hz(38, md, 1), total), 0.06, -0.1, 0.0, 0.0, 0.25)
	_i_reed(0.0, total, _hz_loop(_deg_hz(38, md, 5), total), 0.035, 0.1, 0.0, 0.0, 0.25)
	return _mus_finish()


# ---------------------------------------------------------------- 2) KÖY ŞENLİĞİ — gaydalı reel, Sol miksolidyen
func _song_reel() -> AudioStreamWAV:
	var A := ["1 3 5 3 8 5 3 5", "4 6 8 6 5 x 4 3", "1 3 5 8 7 5 6 7", "8 7 6 5 4 3 2 x",
		"1 3 5 3 8 5 3 5", "4 6 8 6 5 x 4 3", "2 4 3 2 1 2 3 4", "1 x 5 x 1 x x x"]
	var B := ["8 x 8 9 10 9 8 7", "7 x 7 8 9 8 7 6", "8 x 8 9 10 12 10 9", "8 7 6 5 4 x 5 x",
		"8 x 8 9 10 9 8 7", "7 x 7 8 9 8 7 6", "5 6 7 8 9 7 5 2", "1 x 5 x 1 x x x"]
	var cA := [1, 4, 1, 7, 1, 4, 2, 1]
	var cB := [1, 7, 1, 4, 1, 7, 5, 1]
	var e := 0.215
	var bar := 8 * e
	var total := 32 * bar
	_mus_begin(total)
	var md := M_MIXO
	var form := [[A, cA, 0], [A, cA, 1], [B, cB, 2], [B, cB, 3]]
	for sec in form.size():
		if _mus_abort:
			return null
		var notes: Array = _parse(form[sec][0])
		var chords: Array = form[sec][1]
		var pas: int = form[sec][2]
		var t0 := sec * 8 * bar
		for nt in notes:
			var t: float = t0 + nt[0] * e
			var dur: float = nt[1] * e
			var hz := _deg_hz(67, md, nt[2])
			if nt[1] >= 2:
				# gayda süslemesi (kesme notası)
				_i_reed(t, 0.03, _deg_hz(67, md, nt[2] + 2), 0.2, 0.05, 0.004, 0.006, 0.6)
				_i_reed(t + 0.03, dur - 0.03, hz, 0.22, 0.05, 0.004, 0.02, 0.6)
			else:
				_i_reed(t, dur, hz, 0.22, 0.05, 0.004, 0.02, 0.6)
			if pas == 1 or pas == 3:
				_i_flute(t + _jit(), dur * 0.9, _deg_hz(79, md, nt[2]), 0.18, 0.35)
		for b in 8:
			var bt := t0 + b * bar
			var r: int = chords[b]
			_i_lute(bt + _jit(), _deg_hz(43, md, r), 0.32, -0.2, 0.9, 0.5)
			_i_lute(bt + 4 * e + _jit(), _deg_hz(43, md, r + 4), 0.26, -0.2, 0.9, 0.5)
			for k in [2, 6]:
				_strum(bt + k * e + _jit(), 55, md, r, 0.16, -0.35, 0.5)
			_i_drum(bt + _jit(), 0.6, 0.0, 0.9)
			_i_drum(bt + 4 * e + _jit(), 0.5, 0.0, 0.9)
			_i_drum(bt + 2 * e + _jit(), 0.25, 0.0, 1.25)
			_i_drum(bt + 6 * e + _jit(), 0.25, 0.0, 1.25)
			for k in 8:
				_i_tamb(bt + k * e + _jit(), 0.2 if k % 4 == 2 else 0.07, 0.45)
			if pas >= 2:
				_i_clap(bt + 2 * e + _jit(), 0.3, -0.15)
				_i_clap(bt + 6 * e + _jit(), 0.3, 0.15)
			if pas == 3 and b == 7:
				_i_drum(bt + 7 * e, 0.4, 0.0, 1.1)
				_i_drum(bt + 7.5 * e, 0.4, 0.0, 1.0)
	_i_reed(0.0, total, _hz_loop(_deg_hz(43, md, 1), total), 0.07, -0.15, 0.0, 0.0, 0.35)
	_i_reed(0.0, total, _hz_loop(_deg_hz(55, md, 1), total), 0.045, 0.15, 0.0, 0.0, 0.35)
	_i_reed(0.0, total, _hz_loop(_deg_hz(55, md, 5), total), 0.03, 0.0, 0.0, 0.0, 0.35)
	return _mus_finish()


# ---------------------------------------------------------------- 3) TAVERNA — 3/4 lavta valsi, La eolyen
func _song_waltz() -> AudioStreamWAV:
	var A := ["5 x x x 3 x", "4 x 3 x 2 x", "1 x x x 3 x", "5 x x x x x",
		"6 x x x 5 x", "4 x 3 x 4 x", "2 x 1 x 0 x", "1 x x x x x"]
	var B := ["8 x x x 7 x", "6 x 5 x 4 x", "5 x x x 3 x", "6 x x x x x",
		"7 x x x 6 x", "5 x 4 x 3 x", "2 x 3 x 2 x", "1 x x x x x"]
	var cA := [1, 4, 1, 5, 6, 4, 7, 1]
	var cB := [1, 4, 3, 6, 7, 3, 5, 1]
	var e := 0.29
	var bar := 6 * e
	var total := 32 * bar
	_mus_begin(total)
	var md := M_AEOL
	var form := [[A, cA, 0], [A, cA, 1], [B, cB, 2], [B, cB, 3]]
	for sec in form.size():
		if _mus_abort:
			return null
		var notes: Array = _parse(form[sec][0])
		var chords: Array = form[sec][1]
		var pas: int = form[sec][2]
		var t0 := sec * 8 * bar
		for nt in notes:
			var t: float = t0 + nt[0] * e + _jit()
			var dur: float = nt[1] * e * 0.95
			if pas == 1:
				_i_lute(t, _deg_hz(69, md, nt[2]), 0.3, 0.2, 1.8, 0.65)
			else:
				_i_flute(t, dur, _deg_hz(69, md, nt[2]), 0.3, 0.25)
			if pas == 3:
				_i_flute(t + 0.01, dur, _deg_hz(69, md, nt[2] - 2), 0.14, -0.25)
		for b in 8:
			var bt := t0 + b * bar
			var r: int = chords[b]
			_i_lute(bt + _jit(), _deg_hz(45, md, r), 0.36, -0.15, 1.6, 0.5)
			_strum(bt + 2 * e + _jit(), 57, md, r, 0.13, -0.3, 0.9)
			_strum(bt + 4 * e + _jit(), 57, md, r, 0.11, -0.3, 0.9)
			_i_drum(bt + _jit(), 0.32, 0.0, 1.1)
			if pas >= 2:
				_i_tamb(bt + 2 * e + _jit(), 0.07, 0.4)
				_i_tamb(bt + 4 * e + _jit(), 0.07, 0.4)
	return _mus_finish(0.7)


# ---------------------------------------------------------------- çalma / geçiş
func _music_update(delta: float) -> void:
	mus_mutex.lock()
	var ready := mus_ready.duplicate()
	mus_mutex.unlock()
	for name in ready.keys():
		if not mus_players.has(name):
			var pl := AudioStreamPlayer.new()
			pl.bus = "Muzik"
			pl.stream = ready[name]
			pl.volume_db = -80.0
			add_child(pl)
			pl.play()
			mus_players[name] = pl
			mus_vol[name] = 0.0
	# hangi parça çalmalı?
	var p := d_pos if mode == 0 else f_pos
	var near := INF
	for v in village_sites:
		near = minf(near, Vector2(p.x - v.x, p.z - v.z).length())
	var agl := p.y - h_at(p.x, p.z)
	var day: float = sky_mat.get_shader_parameter("day")
	var want := "ucus"
	if near < 520.0 and agl < 320.0:
		want = "koy" if day > 0.45 else "taverna"
	elif day < 0.2:
		want = "taverna"
	if mus_players.has(want):
		mus_track = want
	for name in mus_players.keys():
		var target := 1.0 if name == mus_track else 0.0
		mus_vol[name] = move_toward(mus_vol[name], target, delta / 2.5)
		mus_players[name].volume_db = linear_to_db(maxf(mus_vol[name], 0.0001)) - 4.0

# ============================================================================
#  KÖY ŞENLİĞİ — direk, kurdeleler, bayrak süsleri, pazar tezgâhları, dans eden köylüler
# ============================================================================
var festivals: Array = []
const FEST_COLS := [Color(0.85, 0.12, 0.12), Color(0.95, 0.8, 0.15), Color(0.15, 0.35, 0.8), Color(0.95, 0.95, 0.92), Color(0.15, 0.6, 0.25)]

func _festival(c: Vector3, placed: Array, to_lake: Vector2) -> void:
	# boş ve düz bir meydan bul
	var fc := Vector3.ZERO
	var found := false
	var side := Vector2(to_lake.y, -to_lake.x)
	for cand in [side * 30.0, -side * 30.0, to_lake * 40.0, side * 45.0, -side * 45.0, -to_lake * 35.0, to_lake * 60.0]:
		var q: Vector2 = Vector2(c.x, c.z) + cand
		var ok := n_at(q.x, q.y).y > 0.95 and water_at(q.x, q.y) < h_at(q.x, q.y) - 1.0
		for pp in placed:
			if q.distance_to(pp) < 22.0:
				ok = false
				break
		if ok:
			fc = Vector3(q.x, h_at(q.x, q.y), q.y)
			found = true
			break
	if not found:
		return
	# meydanı hafifçe düzle (ağaçları da temizle)
	_add_bld(fc, 3.0, 16.0)
	# --- şenlik direği
	var pole_h := 15.0
	_mb_cyl(_xf(fc + Vector3(0, -0.5, 0)), 0.35, 0.22, pole_h + 0.5, 8, Color(0.95, 0.94, 0.9), Color(0.95, 0.94, 0.9))
	for k in 7:
		_mb_cyl(_xf(fc + Vector3(0, 1.5 + k * 1.9, 0)), 0.36 - k * 0.018, 0.35 - k * 0.018, 0.7, 8, Color(0.8, 0.1, 0.1), Color(0.8, 0.1, 0.1))
	var top := fc + Vector3(0, pole_h, 0)
	for k in 16:
		var a := TAU * k / 16.0
		_mb_box(_xf(top + Vector3(cos(a), -1.2, sin(a)) * Vector3(1.4, 1, 1.4), Vector3(0, -a, 0)), Vector3(0.5, 0.45, 0.45), Color(0.2, 0.5, 0.15), Color(0.35, 0.65, 0.2))
	_mb_cyl(_xf(top), 0.4, 0.0, 1.2, 6, Color(0.95, 0.8, 0.2), Color(1.0, 0.9, 0.3))
	# kurdeleler (direkten yere)
	for k in 10:
		var a := TAU * k / 10.0
		var bot := fc + Vector3(cos(a) * 7.5, 0.3, sin(a) * 7.5)
		var a0 := top + Vector3(0, -1.5, 0)
		var dir := (bot - a0).normalized()
		var perp := dir.cross(Vector3.UP).normalized() * 0.18
		var col: Color = FEST_COLS[k % FEST_COLS.size()]
		var nn := perp.cross(dir).normalized()
		_mb_quad(a0 - perp, a0 + perp, bot + perp, bot - perp, nn, col)
		_mb_quad(a0 - perp, bot - perp, bot + perp, a0 + perp, -nn, col)
		_mb_box(_xf(bot + Vector3(0, -0.2, 0)), Vector3(0.25, 0.4, 0.25), Color(0.4, 0.28, 0.15))
	# --- bayrak süsleri: direk tepesinden çevredeki direklere
	var posts: Array = []
	for k in 6:
		var a := TAU * k / 6.0 + 0.3
		var q := Vector2(fc.x, fc.z) + Vector2(cos(a), sin(a)) * 21.0
		var gp := Vector3(q.x, h_at(q.x, q.y), q.y)
		_mb_cyl(_xf(gp + Vector3(0, -0.4, 0)), 0.15, 0.12, 6.4, 6, Color(0.42, 0.3, 0.18), Color(0.45, 0.32, 0.2))
		_mb_box(_xf(gp + Vector3(0, 6.2, 0)), Vector3(0.45, 0.6, 0.45), Color(1.0, 0.7, 0.3, 0.2))
		posts.append(gp + Vector3(0, 5.9, 0))
	for k in 6:
		_bunting(top + Vector3(0, -2.0, 0), posts[k], k)
		_bunting(posts[k], posts[(k + 1) % 6], k + 3)
	# --- pazar tezgâhları
	for k in 3:
		var a := TAU * k / 3.0 + 0.95
		var q := Vector2(fc.x, fc.z) + Vector2(cos(a), sin(a)) * 15.0
		var gp := Vector3(q.x, h_at(q.x, q.y), q.y)
		var yaw := -a + PI * 0.5
		var xf := Transform3D(Basis(Vector3.UP, yaw), gp)
		var wood := Color(0.42, 0.28, 0.15)
		_mb_box(xf * _xf(Vector3(0, 0.5, 0)), Vector3(4.0, 1.0, 1.6), wood)
		for sx in [-1.9, 1.9]:
			for sz in [-0.75, 0.75]:
				_mb_box(xf * _xf(Vector3(sx, 1.4, sz)), Vector3(0.12, 2.8, 0.12), wood.darkened(0.2))
		var c1: Color = FEST_COLS[k % 3]
		for st in 8:
			var col := c1 if st % 2 == 0 else Color(0.96, 0.95, 0.9)
			_mb_box(xf * _xf(Vector3(-1.75 + st * 0.5, 3.0, 0), Vector3(0.18, 0, 0)), Vector3(0.5, 0.08, 2.4), col)
		for g in 5:
			_mb_ellipsoid(xf * _xf(Vector3(-1.5 + g * 0.75, 1.15, 0)), Vector3(0.28, 0.18, 0.28), 3, 6, [Color(0.9, 0.6, 0.1), Color(0.7, 0.1, 0.1), Color(0.95, 0.85, 0.5), Color(0.5, 0.3, 0.15), Color(0.3, 0.6, 0.2)][g])
	festivals.append({"c": fc, "dancers": 12, "t": rng.randf() * 10.0})


func _bunting(a: Vector3, b: Vector3, seed_: int) -> void:
	var L := a.distance_to(b)
	var n := int(L / 1.4)
	var sag := L * 0.08
	var prev := a
	for i in range(1, n + 1):
		var t := float(i) / n
		var p := a.lerp(b, t) - Vector3(0, sin(PI * t) * sag, 0)
		var dir := (p - prev)
		var mid := (p + prev) * 0.5
		var tip := mid + Vector3(0, -0.75, 0)
		var col: Color = FEST_COLS[(i + seed_) % FEST_COLS.size()]
		var nn := dir.cross(Vector3.DOWN).normalized()
		var q0 := prev + dir * 0.08
		var q1 := p - dir * 0.08
		_mb_tri(q0, q1, tip, nn, nn, nn, col)
		_mb_tri(q0, q1, tip, -nn, -nn, -nn, col)
		prev = p


var dancer_mm: MultiMesh
var dancer_head_mm: MultiMesh

func _build_dancers() -> void:
	if festivals.is_empty():
		return
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	_mb_begin()
	_mb_cyl(_xf(Vector3(0, 0.05, 0)), 0.42, 0.2, 1.0, 10, Color.WHITE, Color.WHITE, true)
	_mb_ellipsoid(_xf(Vector3(0, 1.25, 0)), Vector3(0.2, 0.32, 0.15), 5, 8, Color.WHITE)
	for s in [-1.0, 1.0]:
		_mb_ellipsoid(_xf(Vector3(s * 0.3, 1.55, 0), Vector3(0, 0, s * 2.2)), Vector3(0.07, 0.3, 0.07), 4, 6, Color.WHITE)
	var body := _mb_mesh(mat)
	_mb_begin()
	_mb_ellipsoid(_xf(Vector3(0, 1.75, 0)), Vector3(0.12, 0.14, 0.13), 5, 8, Color(0.86, 0.66, 0.52))
	_mb_ellipsoid(_xf(Vector3(0, 1.83, 0.02)), Vector3(0.13, 0.08, 0.13), 4, 8, Color(0.35, 0.2, 0.1))
	var head := _mb_mesh(mat)
	var total := 0
	for f in festivals:
		total += f.dancers
	dancer_mm = MultiMesh.new()
	dancer_mm.transform_format = MultiMesh.TRANSFORM_3D
	dancer_mm.use_colors = true
	dancer_mm.mesh = body
	dancer_mm.instance_count = total
	dancer_head_mm = MultiMesh.new()
	dancer_head_mm.transform_format = MultiMesh.TRANSFORM_3D
	dancer_head_mm.mesh = head
	dancer_head_mm.instance_count = total
	var cols := [Color(0.75, 0.12, 0.12), Color(0.15, 0.3, 0.7), Color(0.95, 0.85, 0.3), Color(0.2, 0.55, 0.25), Color(0.6, 0.2, 0.55), Color(0.95, 0.95, 0.9)]
	for i in total:
		dancer_mm.set_instance_color(i, cols[i % cols.size()])
	for m in [dancer_mm, dancer_head_mm]:
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = m
		mmi.custom_aabb = AABB(Vector3(-10, -100, -10), Vector3(WORLD + 20, 3000, WORLD + 20))
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
	_update_dancers(0.0, true)


func _update_dancers(delta: float, force := false) -> void:
	if dancer_mm == null:
		return
	var cp := cam.global_position if cam else Vector3.ZERO
	var k := 0
	for f in festivals:
		var fc: Vector3 = f.c
		var n: int = f.dancers
		if not force and cp.distance_to(fc) > 900.0:
			k += n
			continue
		var scare := 0.0
		if (mode == 0 or calling) and d_pos.distance_to(fc) < 60.0 * SK:
			scare = 1.0
		f.t += delta * (1.0 - scare)
		var t: float = f.t
		for i in n:
			var a := TAU * i / n + t * 0.55
			var r := 9.5 + sin(t * 2.0 + i) * 0.8 + scare * 6.0
			var p := fc + Vector3(cos(a) * r, 0, sin(a) * r)
			p.y = h_at(p.x, p.z) + absf(sin(t * 6.5 + i * 0.9)) * 0.35 * (1.0 - scare)
			var fwd := Vector3(-sin(a), 0, cos(a))
			var b := Basis.looking_at(fwd, Vector3.UP) * Basis(Vector3.UP, sin(t * 3.0 + i) * 0.4)
			b = b * Basis(Vector3(0, 0, 1), sin(t * 6.5 + i * 0.9) * 0.12)
			var xf := Transform3D(b, p)
			dancer_mm.set_instance_transform(k, xf)
			dancer_head_mm.set_instance_transform(k, xf)
			k += 1

var _touch_forced := false
var _mobile_forced := false

func _mob() -> bool:
	return OS.has_feature("mobile") or _mobile_forced

# ============================================================================
#  DOKUNMATİK KONTROLLER (iPhone / iPad / Android) — v1.2
#  Sol alt: sanal joystick. Ekranın geri kalanında sürükle: kamera / yön.
#  Sağ alt: ATEŞ, KANAT, DALIŞ, HIZ. Üstte küçük düğmeler.
# ============================================================================
var touch_on := false
var t_layer: CanvasLayer
var t_draw: Control
var t_btns: Array = []          # {id, label, pos(Vector2 0..1 göreli), r, act, hold, finger, toggle}
var t_joy_finger := -1
var t_joy_center := Vector2.ZERO
var t_joy_vec := Vector2.ZERO
var t_look := {}                # finger -> son konum
var t_hiz_lock := false
var t_safe := Rect2()


func _setup_touch() -> void:
	touch_on = _mob() or OS.has_feature("web_ios") or OS.has_feature("web_android")
	if _touch_forced:
		touch_on = true
	if not touch_on:
		return
	# fare emülasyonu dokunuşlarda "ates" vb. tetiklemesin
	for a in ["ates", "kukre", "yakin", "uzak"]:
		for e in InputMap.action_get_events(a):
			if e is InputEventMouseButton:
				InputMap.action_erase_event(a, e)
	t_layer = CanvasLayer.new()
	t_layer.layer = 20
	add_child(t_layer)
	t_draw = Control.new()
	t_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	t_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t_draw.draw.connect(_touch_draw)
	t_layer.add_child(t_draw)
	# (pozisyonlar ekranın sağ/alt kenarına göre, birim: piksel @1920x1080)
	t_btns = [
		{"id": "ates", "label": "ATEŞ", "pos": Vector2(-150, -170), "r": 92.0, "act": "ates", "hold": true},
		{"id": "yuksel", "label": "KANAT", "pos": Vector2(-345, -110), "r": 72.0, "act": "yuksel", "hold": true},
		{"id": "dalis", "label": "DALIŞ", "pos": Vector2(-150, -380), "r": 66.0, "act": "dalis", "hold": true},
		{"id": "hiz", "label": "HIZ", "pos": Vector2(-335, -300), "r": 60.0, "act": "hiz", "hold": true, "toggle": true},
		{"id": "kukre", "label": "KÜKRE", "pos": Vector2(-520, -95), "r": 52.0, "act": "kukre", "hold": false},
		{"id": "bin", "label": "İN/BİN", "pos": Vector2(-305, -480), "r": 50.0, "act": "bin", "hold": false},
		{"id": "cagir", "label": "ÇAĞIR", "pos": Vector2(-455, -420), "r": 46.0, "act": "cagir", "hold": false},
		{"id": "tur", "label": "TÜR", "pos": Vector2(-120, -540), "r": 44.0, "act": "tur_sonraki", "hold": false},
		{"id": "menu", "label": "☰", "pos": Vector2(-370, 60), "r": 40.0, "act": "menu", "hold": false, "top": true},
		{"id": "harita", "label": "HARİTA", "pos": Vector2(-470, 60), "r": 40.0, "act": "harita", "hold": false, "top": true},
		{"id": "yardim", "label": "?", "pos": Vector2(-570, 60), "r": 34.0, "act": "yardim", "hold": false, "top": true},
	]
	for b in t_btns:
		b.finger = -1
		b.down = false


func _vp_size() -> Vector2:
	return get_viewport().get_visible_rect().size


func _safe_rect() -> Rect2:
	var vs := _vp_size()
	var ws := Vector2(DisplayServer.window_get_size())
	var sa := Rect2(DisplayServer.get_display_safe_area())
	if ws.x < 1.0 or sa.size.x < 1.0:
		return Rect2(Vector2.ZERO, vs)
	var k := vs / ws
	var wp := Vector2(DisplayServer.window_get_position())
	return Rect2((sa.position - wp) * k, sa.size * k).intersection(Rect2(Vector2.ZERO, vs))


func _btn_center(b: Dictionary) -> Vector2:
	var s := t_safe
	var p: Vector2 = b.pos
	var x := s.end.x + p.x
	var y := (s.position.y + p.y) if b.get("top", false) else (s.end.y + p.y)
	return Vector2(x, y)


func _joy_base() -> Vector2:
	return Vector2(t_safe.position.x + 230.0, t_safe.end.y - 230.0)


func _touch_input(event: InputEvent) -> bool:
	if not touch_on:
		return false
	t_safe = _safe_rect()
	if event is InputEventScreenTouch:
		var p: Vector2 = event.position
		if event.pressed:
			if paused or ui.help.visible or ui.bigmap.visible:
				# kapatmak için herhangi bir düğmeye/ekrana dokunuş
				for b in t_btns:
					if b.act in ["menu", "harita", "yardim"] and p.distance_to(_btn_center(b)) < b.r * 1.25:
						_t_fire(b.act, true)
						_t_fire(b.act, false)
						return true
				if (ui.help.visible or ui.bigmap.visible) and not paused:
					ui.help.visible = false
					ui.bigmap.visible = false
					return true
				return false
			for b in t_btns:
				if p.distance_to(_btn_center(b)) < b.r * 1.2:
					if b.get("toggle", false):
						t_hiz_lock = not t_hiz_lock
						b.down = t_hiz_lock
						_t_hold(b.act, t_hiz_lock)
					else:
						b.finger = event.index
						b.down = true
						if b.hold:
							_t_hold(b.act, true)
						else:
							_t_fire(b.act, true)
					return true
			if p.x < t_safe.position.x + t_safe.size.x * 0.42 and p.y > t_safe.position.y + t_safe.size.y * 0.35 and t_joy_finger < 0:
				t_joy_finger = event.index
				t_joy_center = p
				t_joy_vec = Vector2.ZERO
				return true
			t_look[event.index] = p
			return true
		else:
			for b in t_btns:
				if b.finger == event.index:
					b.finger = -1
					b.down = false
					if b.hold:
						_t_hold(b.act, false)
					else:
						_t_fire(b.act, false)
					return true
			if event.index == t_joy_finger:
				t_joy_finger = -1
				t_joy_vec = Vector2.ZERO
				_t_apply_joy()
				return true
			t_look.erase(event.index)
			return true
	elif event is InputEventScreenDrag:
		if paused:
			return false
		if event.index == t_joy_finger:
			var d: Vector2 = event.position - t_joy_center
			var R := 150.0
			if d.length() > R:
				t_joy_center += d - d.normalized() * R
				d = d.normalized() * R
			t_joy_vec = d / R
			_t_apply_joy()
			return true
		if t_look.has(event.index):
			var rel: Vector2 = event.relative
			var k: float = settings.sens * 1.25
			cam_yaw -= rel.x * k
			cam_pitch -= rel.y * k * (-1.0 if settings.invert else 1.0)
			cam_pitch = clamp(cam_pitch, -1.4, 1.25)
			t_look[event.index] = event.position
			return true
	return false


func _t_apply_joy() -> void:
	var v := t_joy_vec
	var dz := 0.12
	var f := clampf((-v.y - dz) / (1.0 - dz), 0.0, 1.0)
	var bk := clampf((v.y - dz) / (1.0 - dz), 0.0, 1.0)
	var l := clampf((-v.x - dz) / (1.0 - dz), 0.0, 1.0)
	var r := clampf((v.x - dz) / (1.0 - dz), 0.0, 1.0)
	for pair in [["ileri", f], ["fren", bk], ["sol", l], ["sag", r]]:
		if pair[1] > 0.0:
			Input.action_press(pair[0], pair[1])
		else:
			Input.action_release(pair[0])


func _t_hold(act: String, on: bool) -> void:
	var e := InputEventAction.new()
	e.action = act
	e.pressed = on
	e.strength = 1.0 if on else 0.0
	Input.parse_input_event(e)


func _t_fire(act: String, on: bool) -> void:
	_t_hold(act, on)


func _touch_draw() -> void:
	if not touch_on or not loaded:
		return
	t_safe = _safe_rect()
	var c := t_draw
	var font := ThemeDB.fallback_font
	if paused:
		return
	# joystick
	var base := _joy_base() if t_joy_finger < 0 else t_joy_center
	c.draw_circle(base, 150.0, Color(0, 0, 0, 0.22))
	c.draw_arc(base, 150.0, 0, TAU, 48, Color(1, 1, 1, 0.35), 3.0, true)
	c.draw_circle(base + t_joy_vec * 150.0, 62.0, Color(1, 1, 1, 0.38 if t_joy_finger >= 0 else 0.22))
	for b in t_btns:
		var ctr := _btn_center(b)
		var r: float = b.r
		var on: bool = b.down
		var col := Color(0, 0, 0, 0.32)
		if b.id == "ates":
			col = Color(0.85, 0.25, 0.05, 0.55 if on else 0.36)
		elif on:
			col = Color(1.0, 0.75, 0.3, 0.5)
		c.draw_circle(ctr, r, col)
		c.draw_arc(ctr, r, 0, TAU, 40, Color(1, 0.9, 0.7, 0.55), 2.5, true)
		var fs := int(clampf(r * 0.38, 18.0, 34.0))
		c.draw_string(font, ctr + Vector2(-r, fs * 0.35), b.label, HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, fs, Color(1, 1, 1, 0.92))
	if b_fire_ring():
		var cf := _btn_center(t_btns[0])
		c.draw_arc(cf, t_btns[0].r + 8.0, -PI * 0.5, -PI * 0.5 + TAU * fire_fuel, 40, Color(1.0, 0.55, 0.15, 0.9), 6.0, true)


func b_fire_ring() -> bool:
	return mode == 0


func _touch_process() -> void:
	if touch_on and t_draw:
		# HIZ kilidi açıkken bırakılmasın
		if t_hiz_lock and not Input.is_action_pressed("hiz"):
			_t_hold("hiz", true)
		t_draw.queue_redraw()
