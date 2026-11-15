extends Control
## Ant's — the NecroMancer agent console, Telegram-style.
## Lobby with agent rows (avatar, preview, unread badge), slide-in chat pages,
## and the viewport-tile desktop as a second page. Summon souls, whisper,
## heal the dead, reap the fallen, repeat. Attach to a Control root; main.tscn.

const COL_BG := Color("0e1621")
const COL_PANEL := Color("17212b")
const COL_HEADER := Color("1f2c3a")
const COL_ACCENT := Color("2aabee")
const COL_BUBBLE_IN := Color("182533")
const COL_BUBBLE_OUT := Color("2b5278")
const COL_TEXT := Color("f5f5f5")
const COL_SUB := Color("7d8b99")
const COL_ONLINE := Color("4fae4e")
const COL_BUSY := Color("e5a33d")
const COL_DEAD := Color("ff4d5e")
const STATE_COLORS := {
	"idle": COL_ONLINE,
	"busy": COL_BUSY,
	"dead": COL_DEAD,
}
const AVATAR_COLORS := [
	Color("e17076"), Color("7bc862"), Color("65aadd"), Color("a695e7"),
	Color("f2a60c"), Color("ee7aae"),
]
const TOUCH_H := 52.0

const ROSTER := ["Qwen3.5", "GLM-5.3", "Gemma", "Llama.cpp", "DeepSeek", "Ollama"]
const SSH_HOSTS := [
	["Lappy  (aaron@192.168.0.33)", "aaron@192.168.0.33"],
	["Ryan  (aaron@192.168.0.209)", "aaron@192.168.0.209"],
]
const DEFAULT_BASE_URL := "http://192.168.0.33:8477/v1"
const DEFAULT_MODEL := "scullm-q4"
const ENDPOINTS := [
	["scullm-q4 (Lappy :8477, primary)", "http://192.168.0.33:8477/v1", ""],
	["scullm-q4-think (Lappy :8478)", "http://192.168.0.33:8478/v1", ""],
	["scullm-q4 (llama-swap :8180)", "http://192.168.0.33:8180/v1", ""],
	["dory lane (Lappy :8182)", "http://192.168.0.33:8182/v1", ""],
	["Ollama (Lappy :11434)", "http://192.168.0.33:11434/v1", ""],
	["Local llama.cpp (localhost :8080)", "http://localhost:8080/v1", ""],
	["OpenRouter", "https://openrouter.ai/api/v1", "openrouter"],
	["NVIDIA API catalog", "https://integrate.api.nvidia.com/v1", "nvidia"],
	["z.ai (coding plan)", "https://api.z.ai/api/paas/v4", "zai"],
]
const API_PORT := 8720

var agents: Array[Soul] = []
var history := {}          # soul instance id -> Array of [kind, text]
var selected: Soul = null
var expanded: Soul = null     # the soul whose chat page is open (null = none)
var _counter := 0
var _roster_idx := 0
var mobile := OS.has_feature("mobile")

# Telegram pages: lobby at rest, chat and desktop slide in over it.
var m_left := 0.0
var m_right := 0.0
var m_top := 0.0
var m_bottom := 0.0
var _page_lobby: Control
var _desktop: Control         # viewport-tile desktop page
var _stage: Control        # the chat page (one soul, full size)
var _root: Control            # pages container — slides above the keyboard
var _lobby_list: VBoxContainer
var _search: LineEdit
var _entry: LineEdit
var _status_label: Label
var _chat_title: Label
var _chat_sub: Label
var _avatar_host: MarginContainer
var _chat_host: MarginContainer   # where the expanded soul's ChatPanel lives
var _chat_scroll: ScrollContainer
var _lobby_menu: PopupMenu
var _chat_menu: PopupMenu
var _rows := {}               # soul instance id -> row widget dictionary
var _unread := {}             # soul instance id -> unread answer count
var _last_ts := {}            # soul instance id -> "HH:MM" of the last message
var _broadcast_on := false    # chat input whispers to every soul
var _optimize_on := false     # broadcasts skip busy and dead souls
var _swipe_x := -1.0
var _swipe_y := -1.0
var _slide := {}              # page -> slide state (see _animate)
const SLIDE_S := 0.22
var panels := {}              # soul instance id -> ChatPanel (the one true transcript)
var _last_text := {}          # soul instance id -> last chat message (lobby preview)
var _nodes := {}              # soul instance id -> GraphNode card on the nest canvas
var _node_slots := {}         # soul instance id -> MarginContainer (panel slot) in the card
var _node_state_l := {}       # soul instance id -> state Label on the card
var _nest: GraphEdit          # the n8n-style node canvas (the desktop page)
var _wires := []              # connection records: {from, from_port, to, to_port}
var _new_dialog: ConfirmationDialog
var _type_pick: OptionButton
var _cli_box: VBoxContainer
var _api_box: VBoxContainer
var _name_edit: LineEdit
var _cmd_edit: LineEdit
var _ssh_pick: OptionButton
var _ep_pick: OptionButton
var _url_edit: LineEdit
var _model_edit: LineEdit
var _key_edit: LineEdit
var _fetch_btn: Button
var _model_search: LineEdit
var _models_list: ItemList
var _models_http: HTTPRequest
var _models_all: Array = []   # every model id the endpoint reports
var _keys := {}               # endpoint name -> key, loaded from gitignored keys.json
var _api: ApiServer           # loopback HTTP API for agents + MCP bridge
var bus := EventBus.new()     # full signal bus: every console event, sequenced
var _mcp_clients := {}        # registered MCP servers: name -> McpClient
var _mcp_dlg: AcceptDialog
var _mcp_name: LineEdit
var _mcp_cmd: LineEdit
var _mcp_list: ItemList
var _art_dialog: AcceptDialog
var _alert: AcceptDialog


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_apply_theme()
	_load_keys()
	_api = ApiServer.new(self, API_PORT)
	_compute_safe_margins()

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	_build_lobby_page()
	_build_desktop_page()
	_build_chat_page()
	_place(_page_lobby, 0.0)
	_place(_desktop, _page_width())
	_place(_stage, _page_width())

	get_viewport().size_changed.connect(_on_resized)
	_build_dialogs()

	for i in 3:
		_add_agent(_next_name(), "")

	# Dev affordance: `godot --path . -- nest` boots straight onto the canvas.
	if OS.get_cmdline_user_args().has("nest"):
		_open_desktop()


func _exit_tree() -> void:
	_api.shutdown()
	for n in _mcp_clients:
		(_mcp_clients[n] as McpClient).shutdown()
	for a in agents:
		a.shutdown()
	for a in agents:
		a.wait_done()


func _notification(what: int) -> void:
	# Android back button: close the deepest page first.
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if expanded != null:
			_close_chat()
		elif _desktop.visible:
			_close_desktop()


# ---------- Telegram pages: placement, safe area, slide ----------

func _page_width() -> float:
	return get_viewport_rect().size.x


func _compute_safe_margins() -> void:
	var screen := DisplayServer.screen_get_size()
	if screen.x <= 0:
		return
	var safe := DisplayServer.get_display_safe_area()
	var k := _page_width() / float(screen.x)
	m_left = safe.position.x * k
	m_top = safe.position.y * k
	m_right = (screen.x - safe.end.x) * k
	m_bottom = (screen.y - safe.end.y) * k


## Places a full-rect page at horizontal offset x, respecting safe-area margins.
func _place(page: Control, x: float) -> void:
	page.offset_left = x + m_left
	page.offset_right = x - m_right
	page.offset_top = m_top
	page.offset_bottom = -m_bottom


## Slides are driven from _process, not tweens — a SceneTree tween never
## advanced on the Android build (traced: page stayed at its offscreen offset).
func _animate(page: Control, from_x: float, to_x: float, on_done := Callable()) -> void:
	if DisplayServer.get_name() == "headless":
		_place(page, to_x)   # gates get instant transitions
		if on_done.is_valid():
			on_done.call()
		return
	_slide[page] = {"from": from_x, "to": to_x, "t": 0.0, "done": on_done}


func _on_resized() -> void:
	_compute_safe_margins()
	_place(_page_lobby, 0.0)
	if _desktop.visible:
		_place(_desktop, 0.0)
	else:
		_place(_desktop, _page_width())
	if expanded != null:
		_place(_stage, 0.0)
	else:
		_place(_stage, _page_width())


# ---------- style helpers ----------

func _style(c: Color, radius := 0, pad_x := 0, pad_y := 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad_x
	s.content_margin_right = pad_x
	s.content_margin_top = pad_y
	s.content_margin_bottom = pad_y
	return s


func _label(t: String, font_size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = MOUSE_FILTER_IGNORE
	return l


func _bar(parent: Control) -> HBoxContainer:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", _style(COL_HEADER, 0, 8, 6))
	parent.add_child(pc)
	var hb := HBoxContainer.new()
	hb.custom_minimum_size.y = TOUCH_H
	hb.add_theme_constant_override("separation", 10)
	pc.add_child(hb)
	return hb


func _icon_btn(t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.flat = true
	b.custom_minimum_size = Vector2(44, TOUCH_H)
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_color", COL_ACCENT)
	b.add_theme_color_override("font_hover_color", COL_TEXT)
	b.add_theme_color_override("font_pressed_color", COL_ACCENT)
	b.pressed.connect(cb)
	return b


func _pad(c: Control, px: int) -> MarginContainer:
	var mc := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		mc.add_theme_constant_override("margin_" + side, px)
	mc.add_child(c)
	return mc


func _avatar_for(soul_name: String, d: float) -> Control:
	var h := absi(soul_name.hash())
	var col: Color = AVATAR_COLORS[h % AVATAR_COLORS.size()]
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(d, d)
	pc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pc.add_theme_stylebox_override("panel", _style(col, int(d / 2.0)))
	# Deterministic ant face per soul, from the generated pool (tools/antface_gen.py).
	var face_path := "res://art/avatars/ant_%02d.png" % (h % 24)
	if ResourceLoader.exists(face_path):
		var face := TextureRect.new()
		face.texture = load(face_path)
		face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		face.custom_minimum_size = Vector2(d - 6, d - 6)
		face.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		pc.add_child(face)
		return pc
	var l := _label(soul_name.substr(0, 1).to_upper(), int(d * 0.42), COL_TEXT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pc.add_child(l)
	return pc


# ---------- lobby page ----------

func _build_lobby_page() -> void:
	_page_lobby = Control.new()
	_page_lobby.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = COL_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = MOUSE_FILTER_IGNORE
	_page_lobby.add_child(bg)
	_root.add_child(_page_lobby)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 0)
	_page_lobby.add_child(col)

	var bar := _bar(col)
	var title := _label("Ant's", 22, COL_TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)
	bar.add_child(_icon_btn("+", _open_new_dialog))
	bar.add_child(_icon_btn("#", _open_desktop))
	var dots := _icon_btn("...", func() -> void: _lobby_menu.popup())
	dots.custom_minimum_size.x = 52
	bar.add_child(dots)

	_lobby_menu = PopupMenu.new()
	_lobby_menu.add_item("Summon a soul...", 0)
	_lobby_menu.add_item("Heal dead souls", 1)
	_lobby_menu.add_item("Stop all", 2)
	_lobby_menu.add_separator()
	_lobby_menu.add_item("Viewport desktop", 3)
	_lobby_menu.add_item("MCP servers...", 4)
	_lobby_menu.add_item("Canon art", 5)
	_lobby_menu.id_pressed.connect(_on_lobby_menu)
	_lobby_menu.add_theme_stylebox_override("panel", _style(COL_PANEL, 8, 4, 4))
	_lobby_menu.add_theme_color_override("font_color", COL_TEXT)
	_lobby_menu.add_theme_color_override("font_hover_color", COL_ACCENT)
	add_child(_lobby_menu)

	_search = LineEdit.new()
	_search.placeholder_text = "Search souls"
	_search.custom_minimum_size.y = TOUCH_H
	_search.text_changed.connect(func(_t: String) -> void: _apply_filter())
	col.add_child(_pad(_search, 10))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)

	_lobby_list = VBoxContainer.new()
	_lobby_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lobby_list.add_theme_constant_override("separation", 0)
	scroll.add_child(_lobby_list)

	_status_label = _label("the circle is drawn", 12, COL_SUB)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.custom_minimum_size.y = 26
	col.add_child(_status_label)


## Rebuilds every lobby row — only on summon / reap, never per-frame.
func _rebuild_list() -> void:
	for c in _lobby_list.get_children():
		c.queue_free()
	_rows.clear()
	for a in agents:
		_add_row_widget(a)


func _add_row_widget(a: Soul) -> void:
	var id := a.get_instance_id()
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 76)
	btn.add_theme_stylebox_override("normal", _style(COL_BG))
	btn.add_theme_stylebox_override("hover", _style(COL_PANEL))
	btn.add_theme_stylebox_override("pressed", _style(COL_HEADER))
	btn.add_theme_stylebox_override("focus", _style(COL_BG))
	btn.pressed.connect(_open_soul.bind(a))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = MOUSE_FILTER_IGNORE
	row.add_child(_avatar_for(a.name_text, 52))

	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.alignment = BoxContainer.ALIGNMENT_CENTER
	mid.mouse_filter = MOUSE_FILTER_IGNORE
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	# PASS would swallow touches over the name area (the IGNORE'd mid above
	# ends them) — IGNORE lets hit-testing fall through to the row Button.
	name_row.mouse_filter = MOUSE_FILTER_IGNORE
	var dot_tr := TextureRect.new()
	dot_tr.custom_minimum_size = Vector2(10, 10)
	dot_tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dot_tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	dot_tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot_tr.texture = _dot("idle")
	name_row.add_child(dot_tr)
	var name_l := _label(a.name_text, 18, COL_TEXT)
	name_l.clip_text = true
	# clip_text zeroes the label's min width in 4.7 — expand so it takes the
	# remaining row width and clips inside it.
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_l)
	mid.add_child(name_row)
	var prev_l := _label("", 14, COL_SUB)
	prev_l.clip_text = true
	prev_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	mid.add_child(prev_l)
	row.add_child(mid)

	var right := VBoxContainer.new()
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	right.mouse_filter = MOUSE_FILTER_IGNORE
	var time_l := _label("", 12, COL_SUB)
	time_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(time_l)
	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", _style(COL_ACCENT, 10, 7, 2))
	badge.add_child(_label("0", 12, COL_TEXT))
	badge.visible = false
	right.add_child(badge)
	row.add_child(right)

	var mc := MarginContainer.new()
	mc.set_anchors_preset(Control.PRESET_FULL_RECT)
	mc.mouse_filter = MOUSE_FILTER_IGNORE
	mc.add_theme_constant_override("margin_left", 14)
	mc.add_theme_constant_override("margin_right", 14)
	mc.add_child(row)
	btn.add_child(mc)
	_lobby_list.add_child(btn)
	_rows[id] = {"btn": btn, "name": name_l, "prev": prev_l, "time": time_l,
			"badge": badge, "unread_l": badge.get_child(0), "dot": dot_tr}


func _apply_filter() -> void:
	var q := _search.text.to_lower()
	for a in agents:
		var row: Dictionary = _rows.get(a.get_instance_id(), {})
		if row.is_empty():
			continue
		(row["btn"] as Control).visible = q == "" or a.name_text.to_lower().contains(q)


## Per-frame row refresh with change detection — cheap string compares only.
func _update_row(a: Soul, st: String, _q: int) -> void:
	var id := a.get_instance_id()
	if not _rows.has(id):
		return
	var row: Dictionary = _rows[id]
	var dot: Texture2D = _dot(st)
	var dot_tr: TextureRect = row["dot"]
	if dot_tr.texture != dot:
		dot_tr.texture = dot
	var prev := ""
	if _last_text.has(id):
		prev = str(_last_text[id]).replace("\n", " ")
	if (row["prev"] as Label).text != prev:
		row["prev"].text = prev
	var time_s := str(_last_ts.get(id, ""))
	if (row["time"] as Label).text != time_s:
		row["time"].text = time_s
	var n := int(_unread.get(id, 0))
	var badge: PanelContainer = row["badge"]
	if badge.visible != (n > 0):
		badge.visible = n > 0
	if n > 0:
		var bl: Label = row["unread_l"]
		if bl.text != str(n):
			bl.text = str(n)


## Per-frame node-card refresh: state text + dot, dead nodes dim (ComfyUI-style
## status on the canvas).
func _update_node_card(a: Soul, st: String) -> void:
	var id := a.get_instance_id()
	if not _nodes.has(id):
		return
	var node: GraphNode = _nodes[id]
	if not is_instance_valid(node):
		return
	var dim := st == "dead"
	var want := Color(1, 0.45, 0.45) if dim else Color(1, 1, 1)
	if node.modulate != want:
		node.modulate = want
	var state_l: Label = _node_state_l[id]
	if is_instance_valid(state_l) and state_l.text != st:
		state_l.text = st


# ---------- desktop page (the nest canvas — n8n-style node graph) ----------

func _build_desktop_page() -> void:
	_desktop = Control.new()
	_desktop.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = COL_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = MOUSE_FILTER_IGNORE
	_desktop.add_child(bg)
	_root.add_child(_desktop)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	_desktop.add_child(col)

	var bar := _bar(col)
	bar.add_child(_icon_btn("<", _close_desktop))
	var t := _label("the nest map", 18, COL_TEXT)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(t)

	_nest = GraphEdit.new()
	_nest.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_nest.add_theme_color_override("grid_pattern", Color(1, 1, 1, 0.04))
	_nest.add_theme_color_override("connection_line", COL_ACCENT)
	_nest.connection_request.connect(_on_wire_request)
	_nest.disconnection_request.connect(_on_unwire_request)
	col.add_child(_nest)


## Wire = a whisper pipe between two souls (visual plumbing; recorded on the bus).
func _on_wire_request(from: String, from_port: int, to: String, to_port: int) -> void:
	for w in _wires:
		if w["from"] == from and w["to"] == to:
			return
	_nest.connect_node(from, from_port, to, to_port)
	_wires.append({"from": from, "from_port": from_port, "to": to, "to_port": to_port})
	bus.emit_event("wire", from, "→ " + to)


func _on_unwire_request(from: String, from_port: int, to: String, to_port: int) -> void:
	for i in _wires.size():
		var w: Dictionary = _wires[i]
		if w["from"] == from and w["to"] == to:
			_wires.remove_at(i)
			break
	_nest.disconnect_node(from, from_port, to, to_port)
	bus.emit_event("unwire", from, "✂ " + to)


func _make_node_card(a: Soul, slot_idx: int) -> GraphNode:
	var node := GraphNode.new()
	node.name = a.name_text
	node.title = a.name_text
	node.custom_minimum_size = Vector2(220, 120)
	node.position_offset = Vector2(30.0 + (slot_idx % 3) * 250.0,
			30.0 + float(slot_idx / 3) * 170.0)
	node.set_meta("soul_id", a.get_instance_id())

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	node.add_child(body)

	var head := HBoxContainer.new()
	head.mouse_filter = MOUSE_FILTER_IGNORE
	var face_path := "res://art/avatars/ant_%02d.png" % (absi(a.name_text.hash()) % 24)
	if ResourceLoader.exists(face_path):
		var face := TextureRect.new()
		face.texture = load(face_path)
		face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		face.custom_minimum_size = Vector2(24, 24)
		head.add_child(face)
	var dot := TextureRect.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.texture = _dot("idle")
	var state_l := _label("idle", 12, COL_SUB)
	head.add_child(dot)
	head.add_child(state_l)
	_node_state_l[a.get_instance_id()] = state_l
	body.add_child(head)

	var slot := MarginContainer.new()
	slot.custom_minimum_size = Vector2(200, 84)
	slot.add_theme_constant_override("margin_left", 4)
	slot.add_theme_constant_override("margin_right", 4)
	slot.add_theme_constant_override("margin_top", 2)
	slot.add_theme_constant_override("margin_bottom", 4)
	body.add_child(slot)

	# slots: left (0) in, right (0) out — on the body row index 1
	node.set_slot(1, true, 0, COL_ACCENT, true, 0, COL_ACCENT)

	node.gui_input.connect(_on_node_input.bind(a))
	node.node_selected.connect(func() -> void: selected = a)   # GraphNode emits this with no args
	_nest.add_child(node)
	_nodes[a.get_instance_id()] = node
	_node_slots[a.get_instance_id()] = slot
	return node


func _on_node_input(ev: InputEvent, a: Soul) -> void:
	# double-click (or double-tap) opens the chat page; right-click the menu
	if ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_LEFT and ev.double_click:
			_open_soul(a)
		elif ev.button_index == MOUSE_BUTTON_RIGHT:
			selected = a
			_sync_chat_menu()
			_chat_menu.popup()


func _open_desktop() -> void:
	_desktop.visible = true
	_animate(_desktop, _page_width(), 0.0)


func _close_desktop() -> void:
	_animate(_desktop, 0.0, _page_width(), func() -> void: _desktop.visible = false)


# ---------- chat page ----------

func _build_chat_page() -> void:
	# Plain Control with anchored bands: in a VBox the full-rect bg ColorRect
	# collapses to zero height and the lobby shows through the transcript.
	_stage = Control.new()
	_stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = COL_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = MOUSE_FILTER_IGNORE
	_stage.add_child(bg)
	_root.add_child(_stage)

	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _style(COL_HEADER, 0, 8, 6))
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = 64
	_stage.add_child(bar)
	var hb := HBoxContainer.new()
	hb.custom_minimum_size.y = TOUCH_H
	hb.add_theme_constant_override("separation", 10)
	bar.add_child(hb)
	hb.add_child(_icon_btn("<", _close_chat))
	_avatar_host = MarginContainer.new()
	hb.add_child(_avatar_host)
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	_chat_title = _label("", 18, COL_TEXT)
	_chat_sub = _label("", 12, COL_SUB)
	names.add_child(_chat_title)
	names.add_child(_chat_sub)
	hb.add_child(names)
	var nest_btn := _icon_btn("#", func() -> void:
		_close_chat()
		_open_desktop())
	nest_btn.custom_minimum_size.x = 44
	hb.add_child(nest_btn)
	var dots := _icon_btn("...", func() -> void:
		_sync_chat_menu()
		_chat_menu.popup())
	dots.custom_minimum_size.x = 52
	hb.add_child(dots)

	_chat_menu = PopupMenu.new()
	_chat_menu.add_check_item("Broadcast to all", 0)
	_chat_menu.add_check_item("Optimize: idle only", 1)
	_chat_menu.add_separator()
	_chat_menu.add_item("Stop", 2)
	_chat_menu.add_item("Heal", 3)
	_chat_menu.add_item("Reap", 4)
	_chat_menu.id_pressed.connect(_on_chat_menu)
	_chat_menu.add_theme_stylebox_override("panel", _style(COL_PANEL, 8, 4, 4))
	_chat_menu.add_theme_color_override("font_color", COL_TEXT)
	_chat_menu.add_theme_color_override("font_hover_color", COL_ACCENT)
	add_child(_chat_menu)

	_chat_scroll = ScrollContainer.new()
	_chat_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_chat_scroll.offset_top = 64
	_chat_scroll.offset_bottom = -76
	_chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_stage.add_child(_chat_scroll)
	_chat_host = MarginContainer.new()
	_chat_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_host.add_theme_constant_override("margin_left", 6)
	_chat_host.add_theme_constant_override("margin_right", 6)
	_chat_host.add_theme_constant_override("margin_top", 6)
	_chat_host.add_theme_constant_override("margin_bottom", 6)
	_chat_scroll.add_child(_chat_host)

	var ibar := PanelContainer.new()
	ibar.add_theme_stylebox_override("panel", _style(COL_HEADER, 0, 8, 8))
	ibar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	ibar.offset_top = -76
	_stage.add_child(ibar)
	var irow := HBoxContainer.new()
	irow.add_theme_constant_override("separation", 8)
	ibar.add_child(irow)
	_entry = LineEdit.new()
	_entry.placeholder_text = "Whisper..."
	_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry.custom_minimum_size.y = TOUCH_H
	_entry.text_submitted.connect(func(_t: String) -> void: _send())
	irow.add_child(_entry)
	var send := Button.new()
	send.text = "Send"
	send.custom_minimum_size = Vector2(88, TOUCH_H)
	send.pressed.connect(_send)
	irow.add_child(send)


func _open_soul(a: Soul) -> void:
	selected = a
	if expanded == a:
		return
	var id := a.get_instance_id()
	if not panels.has(id) or not is_instance_valid(panels[id]):
		return
	if expanded != null:
		_detach_expanded(false)
	_attach_expanded(a)
	expanded = a
	_unread[id] = 0
	_update_header(a)
	# Close hides the page (slide-out callback), so every open must re-show it
	# before sliding in from wherever it sits.
	_stage.visible = true
	_animate(_stage, _stage.offset_left, 0.0)


## Test- and gate-facing alias: expand a soul's chat page.
func _expand_chat(a: Soul) -> void:
	_open_soul(a)


func _close_chat() -> void:
	if expanded == null:
		return
	_entry.release_focus()
	_detach_expanded(true)
	expanded = null
	_animate(_stage, 0.0, _page_width(), func() -> void: _stage.visible = false)


## Test- and gate-facing alias: collapse the chat page.
func _collapse_chat() -> void:
	_close_chat()


func _attach_expanded(a: Soul) -> void:
	var panel: ChatPanel = panels[a.get_instance_id()]
	panel.get_parent().remove_child(panel)
	_chat_host.add_child(panel)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.set_mini(false)


## Puts the soul's transcript back into its nest-canvas node card (mini mode).
func _detach_expanded(_slide_out: bool) -> void:
	if expanded == null:
		return
	var id := expanded.get_instance_id()
	if not panels.has(id) or not is_instance_valid(panels[id]):
		expanded = null
		return
	var panel: ChatPanel = panels[id]
	if panel.get_parent() == _chat_host:
		panel.get_parent().remove_child(panel)
	if _node_slots.has(id) and is_instance_valid(_node_slots[id]):
		(_node_slots[id] as MarginContainer).add_child(panel)
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		panel.set_mini(true)


func _update_header(a: Soul) -> void:
	for c in _avatar_host.get_children():
		c.queue_free()
	_avatar_host.add_child(_avatar_for(a.name_text, 40))
	_chat_title.text = a.name_text


func _sync_chat_menu() -> void:
	_chat_menu.set_item_checked(0, _broadcast_on)
	_chat_menu.set_item_checked(1, _optimize_on)


func _on_lobby_menu(id: int) -> void:
	match id:
		0:
			_open_new_dialog()
		1:
			_heal_all()
		2:
			_stop_all()
		3:
			_open_desktop()
		4:
			_open_mcp_dialog()
		5:
			_show_art_dialog()


func _on_chat_menu(id: int) -> void:
	match id:
		0:
			_broadcast_on = not _broadcast_on
		1:
			_optimize_on = not _optimize_on
		2:
			if expanded != null:
				expanded.cancel()
				_record(expanded, "system", "stop requested")
		3:
			if expanded != null:
				expanded.revive()
		4:
			if expanded != null:
				_teardown_soul(expanded)


# ---------- theme ----------

func _apply_theme() -> void:
	var t := Theme.new()

	var panel := _style(COL_PANEL, 6)
	panel.border_color = Color("2a3947")
	panel.set_border_width_all(1)
	t.set_stylebox("panel", "ItemList", panel)
	t.set_color("font_color", "ItemList", COL_TEXT)
	t.set_color("font_selected_color", "ItemList", COL_TEXT)
	t.set_stylebox("selected", "ItemList", _style(Color("22343f"), 4))
	t.set_stylebox("selected_focus", "ItemList", _style(Color("22343f"), 4))

	t.set_stylebox("normal", "Button", _style(COL_HEADER, 8))
	t.set_stylebox("hover", "Button", _style(Color("22343f"), 8))
	t.set_stylebox("pressed", "Button", _style(COL_PANEL, 8))
	t.set_stylebox("disabled", "Button", _style(COL_PANEL, 8))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", COL_TEXT)
	t.set_color("font_hover_color", "Button", Color("cfe9ff"))
	t.set_color("font_pressed_color", "Button", COL_ACCENT)
	t.set_color("font_disabled_color", "Button", COL_SUB)

	var edit := _style(COL_PANEL, 10, 12, 8)
	edit.border_color = Color("2a3947")
	edit.set_border_width_all(1)
	t.set_stylebox("normal", "LineEdit", edit)
	var edit_f := _style(Color("1d2c3a"), 10, 12, 8)
	edit_f.border_color = COL_ACCENT
	edit_f.set_border_width_all(1)
	t.set_stylebox("focus", "LineEdit", edit_f)
	t.set_color("font_color", "LineEdit", COL_TEXT)
	t.set_color("font_placeholder_color", "LineEdit", COL_SUB)
	t.set_color("caret_color", "LineEdit", COL_ACCENT)

	t.set_color("font_color", "CheckBox", COL_SUB)
	t.set_color("font_color", "Label", COL_SUB)

	t.set_stylebox("panel", "PopupMenu", _style(COL_PANEL, 8, 4, 4))
	t.set_color("font_color", "PopupMenu", COL_TEXT)
	t.set_color("font_hover_color", "PopupMenu", COL_ACCENT)

	theme = t


func _add_button(row: HBoxContainer, text: String, icon: String, action: Callable, tip: String) -> void:
	var b := Button.new()
	b.text = text
	if icon != "":
		b.icon = load("res://icons/" + icon)
		b.expand_icon = true
	b.tooltip_text = tip
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(action)
	row.add_child(b)


func _make_label(text: String, _bold: bool) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", COL_SUB)
	return l


func _build_dialogs() -> void:
	_new_dialog = ConfirmationDialog.new()
	_new_dialog.title = "Summon Agent"
	var v := VBoxContainer.new()
	_new_dialog.add_child(v)
	v.add_child(_make_label("Name:", false))
	_name_edit = LineEdit.new()
	v.add_child(_name_edit)
	v.add_child(_make_label("Soul type:", false))
	_type_pick = OptionButton.new()
	_type_pick.add_item("Echo (test backend)")
	_type_pick.add_item("CLI (local command)")
	_type_pick.add_item("CLI (ssh remote)")
	_type_pick.add_item("Agent (OpenAI-compatible API)")
	_type_pick.item_selected.connect(_on_type_picked)
	v.add_child(_type_pick)

	_cli_box = VBoxContainer.new()
	v.add_child(_cli_box)
	_cli_box.add_child(_make_label("Command. Use {prompt} where the message goes:", false))
	_cmd_edit = LineEdit.new()
	_cli_box.add_child(_cmd_edit)
	_cli_box.add_child(_make_label("Run on:", false))
	_ssh_pick = OptionButton.new()
	_ssh_pick.add_item("Local CLI")
	for h in SSH_HOSTS:
		_ssh_pick.add_item(h[0])
	_cli_box.add_child(_ssh_pick)

	_api_box = VBoxContainer.new()
	v.add_child(_api_box)
	_api_box.add_child(_make_label("Endpoint preset:", false))
	_ep_pick = OptionButton.new()
	for ep in ENDPOINTS:
		_ep_pick.add_item(ep[0])
	_ep_pick.item_selected.connect(_on_endpoint_picked)
	_api_box.add_child(_ep_pick)
	_api_box.add_child(_make_label("Base URL (any OpenAI-compatible /v1):", false))
	_url_edit = LineEdit.new()
	_url_edit.text = DEFAULT_BASE_URL
	_api_box.add_child(_url_edit)
	_api_box.add_child(_make_label("Model:", false))
	_model_edit = LineEdit.new()
	_model_edit.text = DEFAULT_MODEL
	_model_edit.placeholder_text = "e.g. walker-duo or z-ai/glm-5.3"
	_api_box.add_child(_model_edit)
	_api_box.add_child(_make_label("API key (runtime only, never saved to disk):", false))
	_key_edit = LineEdit.new()
	_key_edit.placeholder_text = "optional — needed for OpenRouter etc."
	_api_box.add_child(_key_edit)
	_api_box.add_child(_make_label("Models (fetch from endpoint, search, click to pick):", false))
	_fetch_btn = Button.new()
	_fetch_btn.text = "Fetch models"
	_fetch_btn.pressed.connect(_on_fetch_models)
	_api_box.add_child(_fetch_btn)
	_model_search = LineEdit.new()
	_model_search.placeholder_text = "search models..."
	_model_search.text_changed.connect(_on_model_search_changed)
	_api_box.add_child(_model_search)
	_models_list = ItemList.new()
	_models_list.custom_minimum_size.y = 150
	_models_list.item_selected.connect(_on_model_selected)
	_api_box.add_child(_models_list)
	_models_http = HTTPRequest.new()
	_models_http.timeout = 30.0
	add_child(_models_http)
	_models_http.request_completed.connect(_on_models_response)
	_api_box.visible = false

	_new_dialog.confirmed.connect(_on_new_confirmed)
	add_child(_new_dialog)

	_alert = AcceptDialog.new()
	_alert.title = "Ant's"
	add_child(_alert)


func _on_type_picked(idx: int) -> void:
	_cli_box.visible = idx == 1 or idx == 2
	_api_box.visible = idx == 3


func _on_endpoint_picked(idx: int) -> void:
	if idx < 0 or idx >= ENDPOINTS.size():
		return
	_url_edit.text = ENDPOINTS[idx][1]
	# Default the key in from gitignored keys.json when this endpoint has one.
	var key_name: String = ENDPOINTS[idx][2]
	_key_edit.text = str(_keys.get(key_name, "")) if key_name != "" else ""


## Keys live in gitignored keys.json ({openrouter, nvidia, ...}) — never committed.
func _load_keys() -> void:
	if not FileAccess.file_exists("res://keys.json"):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://keys.json"))
	if typeof(data) == TYPE_DICTIONARY:
		_keys = data


# ---------- model browser ----------

func _on_fetch_models() -> void:
	var base := _url_edit.text.strip_edges()
	if base == "":
		_say_alert("Enter a Base URL first.")
		return
	var headers := PackedStringArray()
	var key := _key_edit.text.strip_edges()
	if key != "":
		headers.append("Authorization: Bearer " + key)
	_fetch_btn.disabled = true
	_fetch_btn.text = "Fetching..."
	var err := _models_http.request(base + "/models", headers, HTTPClient.METHOD_GET)
	if err != OK:
		_fetch_btn.disabled = false
		_fetch_btn.text = "Fetch models"
		_say_alert("models request failed to start (%d)" % err)


func _on_models_response(result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
	_fetch_btn.disabled = false
	_fetch_btn.text = "Fetch models"
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_say_alert("models fetch failed — HTTP %d (result %d)" % [code, result])
		return
	var data = JSON.parse_string(raw.get_string_from_utf8())
	_models_all.clear()
	if typeof(data) == TYPE_DICTIONARY and typeof(data.get("data")) == TYPE_ARRAY:
		for entry in data["data"]:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var id := str(entry.get("id", entry.get("model", "")))
			if id != "":
				_models_all.append(id)
	_models_all.sort()
	_fill_models(_model_search.text)
	if _models_all.is_empty():
		_say_alert("Endpoint returned no models (HTTP %d)." % code)


func _fill_models(filter: String) -> void:
	_models_list.clear()
	var f := filter.to_lower()
	for id in _models_all:
		if f == "" or id.to_lower().contains(f):
			_models_list.add_item(str(id))


func _on_model_search_changed(text: String) -> void:
	_fill_models(text)


func _on_model_selected(idx: int) -> void:
	if idx >= 0 and idx < _models_list.item_count:
		_model_edit.text = _models_list.get_item_text(idx)


# ---------- HTTP API (loopback; driven by agents + mcp/mcp_stdio.py) ----------

func _api_dispatch(id: int, method: String, raw_path: String, body: Dictionary) -> void:
	var path := raw_path.get_slice("?", 0)
	var query := {}
	if raw_path.contains("?"):
		for kv in raw_path.get_slice("?", 1).split("&"):
			var pair := kv.split("=", true, 1)
			if pair.size() == 2:
				query[pair[0].uri_decode()] = pair[1].uri_decode()
	if method == "GET" and path == "/health":
		var busy := 0
		var dead := 0
		for a in agents:
			var st := a.get_state()
			if st == "busy":
				busy += 1
			elif st == "dead":
				dead += 1
		_api.respond(id, 200, {"ok": true, "port": _api.port, "souls": agents.size(),
				"busy": busy, "dead": dead})
	elif method == "GET" and path == "/souls":
		var out := []
		for a in agents:
			out.append({"name": a.name_text, "kind": "agent" if a is AntSoul else "cli",
					"state": a.get_state(), "queued": a.queued()})
		_api.respond(id, 200, {"souls": out})
	elif method == "POST" and path == "/spawn":
		_api.respond(id, 200, api_spawn(body))
	elif method == "POST" and path == "/whisper":
		_api.respond(id, 200, api_whisper(str(body.get("target", "")), str(body.get("text", ""))))
	elif method == "POST" and path == "/open":
		var a := _soul_by_name(str(body.get("target", "")))
		if a == null:
			_api.respond(id, 404, {"ok": false, "error": "unknown soul"})
			return
		_open_soul(a)
		_api.respond(id, 200, {"ok": true, "expanded": expanded != null,
				"stage": _stage.visible, "off_l": _stage.offset_left})
	elif method == "POST" and path == "/close":
		_close_chat()
		_api.respond(id, 200, {"ok": true, "expanded": expanded != null,
				"stage": _stage.visible})
	elif method == "GET" and path == "/status":
		_api.respond(id, 200, {"expanded": str(expanded),
				"stage_vis": _stage.visible, "stage_l": _stage.offset_left,
				"lobby_vis": _page_lobby.visible, "lobby_l": _page_lobby.offset_left,
				"desk_vis": _desktop.visible, "desk_l": _desktop.offset_left,
				"stage_size": _stage.size, "root_y": _root.position.y})
	elif method == "POST" and path == "/broadcast":
		_api.respond(id, 200, {"ok": true, "reached": api_broadcast(str(body.get("text", "")))})
	elif method == "GET" and path.begins_with("/transcript/"):
		var tname := path.get_slice("/transcript/", 1).uri_decode()
		_api.respond(id, 200, {"name": tname, "events": api_transcript(tname)})
	elif method == "POST" and path == "/heal":
		_api.respond(id, 200, api_heal(str(body.get("name", ""))))
	elif method == "POST" and path == "/stop":
		_api.respond(id, 200, api_stop(str(body.get("name", ""))))
	elif method == "POST" and path == "/reap":
		_api.respond(id, 200, {"ok": api_reap(str(body.get("name", "")))})
	elif method == "GET" and path == "/models":
		await api_models(id, query)
	elif method == "GET" and path == "/events":
		_api.respond(id, 200, bus.events_since(int(query.get("since", 0))))
	elif method == "POST" and path == "/mcp/add":
		await api_mcp_add(id, body)
	elif method == "GET" and path == "/mcp/servers":
		_api.respond(id, 200, api_mcp_servers())
	elif method == "POST" and path == "/mcp/call":
		await api_mcp_call(id, body)
	elif method == "POST" and path == "/mcp/remove":
		_api.respond(id, 200, api_mcp_remove(str(body.get("name", ""))))
	else:
		_api.respond(id, 404, {"error": "unknown route"})


func _soul_by_name(soul_name: String) -> Soul:
	for a in agents:
		if a.name_text == soul_name:
			return a
	return null


func api_spawn(body: Dictionary, depth := 1, caller: Soul = null) -> Dictionary:
	var soul_name := str(body.get("name", ""))
	var type := str(body.get("type", "cli"))
	var command := str(body.get("command", ""))
	if soul_name == "":
		return {"ok": false, "error": "name required"}
	if _soul_by_name(soul_name) != null:
		return {"ok": false, "error": "duplicate name"}
	var a: Soul = null
	if type == "cli":
		# blank command is legal: it summons an echo-backend soul
		a = _add_agent(soul_name, command)
	elif type == "ssh":
		if command == "":
			return {"ok": false, "error": "ssh needs a command"}
		a = _add_agent(soul_name, _ssh_wrap(command, int(body.get("host", 0))))
	elif type == "agent":
		a = _add_ant_soul(soul_name, str(body.get("url", DEFAULT_BASE_URL)),
				str(body.get("model", DEFAULT_MODEL)), str(body.get("key", "")))
		a.depth = depth
		if caller != null and caller is AntSoul:
			caller.children += 1
	else:
		return {"ok": false, "error": "unknown type " + type}
	return {"ok": true, "name": soul_name, "state": a.get_state()}


func api_whisper(target: String, text: String) -> Dictionary:
	if text == "":
		return {"ok": false, "error": "text required"}
	var a := _soul_by_name(target)
	if a == null:
		return {"ok": false, "error": "unknown target " + target}
	if a.get_state() == "dead":
		a.revive()
	_record(a, "you", text)
	a.submit(text)
	return {"ok": true, "target": target, "state": a.get_state()}


func api_broadcast(text: String) -> int:
	var reached := 0
	for a in agents:
		if a.get_state() == "dead":
			a.revive()
		_record(a, "you", text)
		a.submit(text)
		reached += 1
	return reached


func api_transcript(soul_name: String) -> Array:
	var a := _soul_by_name(soul_name)
	if a == null:
		return [["error", "unknown soul " + soul_name]]
	return history.get(a.get_instance_id(), [])


func api_heal(soul_name: String) -> Dictionary:
	if soul_name == "":
		var n := 0
		for a in agents:
			if a.get_state() == "dead":
				a.revive()
				n += 1
		return {"ok": true, "healed": n}
	var a := _soul_by_name(soul_name)
	if a == null:
		return {"ok": false, "error": "unknown soul " + soul_name}
	a.revive()
	return {"ok": true, "healed": 1}


func api_stop(soul_name: String) -> Dictionary:
	if soul_name == "":
		for a in agents:
			a.cancel()
			_record(a, "system", "stop requested")
		return {"ok": true, "stopped": agents.size()}
	var a := _soul_by_name(soul_name)
	if a == null:
		return {"ok": false, "error": "unknown soul " + soul_name}
	a.cancel()
	_record(a, "system", "stop requested")
	return {"ok": true, "stopped": 1}


func api_reap(soul_name: String) -> bool:
	var a := _soul_by_name(soul_name)
	if a == null:
		return false
	_teardown_soul(a)
	bus.emit_event("removed", soul_name, "")
	return true


## Shared removal path for Reap and the API: collapse if expanded, free the
## chat panel + desktop tile, shut the soul down, rebuild the lobby rows.
func _teardown_soul(a: Soul) -> void:
	if expanded == a:
		var id := a.get_instance_id()
		if panels.has(id) and is_instance_valid(panels[id]):
			var panel: ChatPanel = panels[id]
			if panel.get_parent() == _chat_host:
				panel.get_parent().remove_child(panel)
		expanded = null
		_place(_stage, _page_width())
		_stage.visible = false
	if panels.has(a.get_instance_id()):
		panels[a.get_instance_id()].queue_free()
		panels.erase(a.get_instance_id())
	if _nodes.has(a.get_instance_id()):
		var node: GraphNode = _nodes[a.get_instance_id()]
		for i in range(_wires.size() - 1, -1, -1):
			var w: Dictionary = _wires[i]
			if w["from"] == node.name or w["to"] == node.name:
				_nest.disconnect_node(w["from"], w["from_port"], w["to"], w["to_port"])
				_wires.remove_at(i)
		if is_instance_valid(node):
			node.queue_free()
		_nodes.erase(a.get_instance_id())
		_node_slots.erase(a.get_instance_id())
	_rows.erase(a.get_instance_id())
	agents.erase(a)
	history.erase(a.get_instance_id())
	a.shutdown()
	a.wait_done()
	_rebuild_list()
	if selected == a:
		selected = null
		if not agents.is_empty():
			selected = agents[0]


## Synchronous console control handed to Ant souls via their `console` tool.
## Deliberately NOT loopback HTTP: the API dispatches handlers on the main
## thread and Ant tools also run on the main thread — an HTTP self-call would
## deadlock until timeout. Enforces the recursion law: up to 3 summoned ants
## per soul, depth 2 max.
func api_necro_for(caller: Soul, args: Dictionary) -> Dictionary:
	match str(args.get("op", "")):
		"list":
			var out := []
			for a in agents:
				out.append({"name": a.name_text, "kind": "agent" if a is AntSoul else "cli",
						"state": a.get_state(), "queued": a.queued(),
						"depth": caller_depth_of(a)})
			return {"souls": out}
		"whisper":
			return api_whisper(str(args.get("name", "")), str(args.get("text", "")))
		"broadcast":
			return {"ok": true, "reached": api_broadcast(str(args.get("text", "")))}
		"spawn":
			var type := str(args.get("type", "cli"))
			if type == "agent" and caller is AntSoul:
				if caller.depth >= 3:
					return {"error": "recursion limit — a depth-3 leaf ant cannot summon ants (tree: 1 + 3 + 9)"}
				if caller.children >= 3:
					return {"error": "spawn budget exhausted (3 ants per soul)"}
				var result := api_spawn(args, caller.depth + 1, caller)
				return result
			return api_spawn(args)
		"transcript":
			var tname := str(args.get("name", ""))
			return {"name": tname, "events": api_transcript(tname)}
		"heal":
			return api_heal(str(args.get("name", "")))
		"stop":
			return api_stop(str(args.get("name", "")))
		"reap":
			return {"ok": api_reap(str(args.get("name", "")))}
		"sense":
			return {"stimuli": bus.sense_pheromones(str(args.get("kind", "")))}
		"claim":
			var capability := 1.0
			if caller is AntSoul:
				capability = 1.0 if caller.depth <= 1 else (0.75 if caller.depth == 2 else 0.5)
			var ph_id := int(args.get("id", 0))
			var claim_result: Dictionary = bus.claim_pheromone(ph_id, caller.name_text, capability)
			if claim_result.has("payload"):
				return {"claimed": true, "payload": claim_result["payload"]}
			return claim_result
		_:
			return {"error": "unknown op"}


func caller_depth_of(a: Soul) -> int:
	return a.depth if a is AntSoul else 1


func api_models(id: int, query: Dictionary) -> void:
	var url := str(query.get("url", DEFAULT_BASE_URL))
	var key := str(query.get("key", ""))
	var req := HTTPRequest.new()
	req.timeout = 30.0
	add_child(req)
	var headers := PackedStringArray()
	if key != "":
		headers.append("Authorization: Bearer " + key)
	var err := req.request(url + "/models", headers, HTTPClient.METHOD_GET)
	if err != OK:
		_api.respond(id, 500, {"error": "models request failed to start"})
		req.queue_free()
		return
	var res: Array = await req.request_completed
	req.queue_free()
	var ids := []
	if int(res[1]) == 200:
		var data = JSON.parse_string(res[3].get_string_from_utf8())
		if typeof(data) == TYPE_DICTIONARY and typeof(data.get("data")) == TYPE_ARRAY:
			for entry in data["data"]:
				if typeof(entry) == TYPE_DICTIONARY:
					var mid := str(entry.get("id", entry.get("model", "")))
					if mid != "":
						ids.append(mid)
			ids.sort()
		_api.respond(id, 200, {"url": url, "models": ids})
	else:
		_api.respond(id, int(res[1]), {"error": "models fetch failed", "url": url})


# ---------- MCP adder (register external MCP servers as tool sources) ----------

func api_mcp_add(id: int, body: Dictionary) -> void:
	var out: Dictionary = await _mcp_add_process(str(body.get("name", "")), str(body.get("command", "")))
	_api.respond(id, 200 if bool(out.get("ok", false)) else 400, out)


func _mcp_add_process(sname: String, command: String) -> Dictionary:
	if sname == "" or command == "":
		return {"ok": false, "error": "name and command required"}
	if _mcp_clients.has(sname):
		return {"ok": false, "error": "duplicate server name"}
	var client := McpClient.new(sname, command)
	if not client.is_alive() or client.stdio_null():
		return {"ok": false, "error": "could not launch: " + command}
	var ok := await client.initialize(self)
	if not ok:
		client.shutdown()
		return {"ok": false, "error": "initialize handshake failed — no response from the server"}
	var tools := await client.list_tools(self)
	_mcp_clients[sname] = client
	bus.emit_event("mcp_add", sname, "%d tools" % tools.size())
	var names := []
	for t in tools:
		if typeof(t) == TYPE_DICTIONARY:
			names.append(str(t.get("name", "")))
	return {"ok": true, "name": sname, "tools": names}


func api_mcp_servers() -> Dictionary:
	var out := []
	for n in _mcp_clients:
		var c: McpClient = _mcp_clients[n]
		var tool_names := []
		for t in c.tools:
			if typeof(t) == TYPE_DICTIONARY:
				tool_names.append(str(t.get("name", "")))
		out.append({"name": n, "alive": c.is_alive(), "tools": tool_names})
	return {"servers": out}


func api_mcp_call(id: int, body: Dictionary) -> void:
	var cname := str(body.get("server", ""))
	if not _mcp_clients.has(cname):
		_api.respond(id, 404, {"ok": false, "error": "unknown server " + cname})
		return
	var client: McpClient = _mcp_clients[cname]
	var args = body.get("arguments", {})
	if typeof(args) != TYPE_DICTIONARY:
		args = {}
	var out: Dictionary = await client.call_tool(str(body.get("tool", "")), args, self)
	bus.emit_event("mcp_call", cname, str(body.get("tool", "")))
	_api.respond(id, 200, out)


func api_mcp_remove(sname: String) -> Dictionary:
	if not _mcp_clients.has(sname):
		return {"ok": false, "error": "unknown server " + sname}
	var client: McpClient = _mcp_clients[sname]
	client.shutdown()
	_mcp_clients.erase(sname)
	bus.emit_event("mcp_remove", sname, "")
	return {"ok": true}


# ---------- MCP adder GUI ----------

func _open_mcp_dialog() -> void:
	if _mcp_dlg == null:
		_mcp_dlg = AcceptDialog.new()
		_mcp_dlg.title = "MCP adder — register servers"
		var v := VBoxContainer.new()
		_mcp_dlg.add_child(v)
		v.add_child(_make_label("Server name:", false))
		_mcp_name = LineEdit.new()
		v.add_child(_mcp_name)
		v.add_child(_make_label("Launch command (stdio MCP server), e.g. python my_server.py:", false))
		_mcp_cmd = LineEdit.new()
		v.add_child(_mcp_cmd)
		var add_btn := Button.new()
		add_btn.text = "Register & fetch tools"
		add_btn.pressed.connect(_on_mcp_add_pressed)
		v.add_child(add_btn)
		v.add_child(_make_label("Registered servers / tools:", false))
		_mcp_list = ItemList.new()
		_mcp_list.custom_minimum_size.y = 150
		v.add_child(_mcp_list)
		add_child(_mcp_dlg)
	_mcp_refresh_list()
	_mcp_dlg.popup_centered(Vector2i(560, 560))


func _on_mcp_add_pressed() -> void:
	var out: Dictionary = await _mcp_add_process(
			_mcp_name.text.strip_edges(), _mcp_cmd.text.strip_edges())
	if bool(out.get("ok", false)):
		_mcp_name.text = ""
		_mcp_cmd.text = ""
		_mcp_refresh_list()
	else:
		_say_alert(str(out.get("error", "registration failed")))


func _mcp_refresh_list() -> void:
	if _mcp_list == null:
		return
	_mcp_list.clear()
	for n in _mcp_clients:
		var c: McpClient = _mcp_clients[n]
		var tnames := []
		for t in c.tools:
			if typeof(t) == TYPE_DICTIONARY:
				tnames.append(str(t.get("name", "")))
		_mcp_list.add_item("%s (%s): %s" % [n,
				"alive" if c.is_alive() else "dead",
				", ".join(PackedStringArray(tnames))])


func _say_alert(text: String) -> void:
	_alert.dialog_text = text
	_alert.popup_centered()


func _show_art_dialog() -> void:
	if _art_dialog == null:
		_art_dialog = AcceptDialog.new()
		_art_dialog.title = "Ant's — canon art"
		var box := VBoxContainer.new()
		_art_dialog.add_child(box)
		for path in ["res://art/NecroMancer_ Agent Management Overlord.png",
				"res://art/Orchestrator Controls Cybernetic Ant.png"]:
			var tr := TextureRect.new()
			tr.texture = load(path)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.custom_minimum_size = Vector2(760, 400)
			box.add_child(tr)
		add_child(_art_dialog)
	_art_dialog.popup_centered(Vector2i(820, 900))


# ---------- agent management ----------

func _next_name() -> String:
	if _roster_idx < ROSTER.size():
		var n: String = ROSTER[_roster_idx]
		_roster_idx += 1
		return n
	_counter += 1
	return "shade-%d" % _counter


func _add_agent(agent_name: String, command: String) -> AgentWorker:
	var a := AgentWorker.new(agent_name, command)
	var mode := "command: " + command if command != "" else "built-in echo backend"
	_register_soul(a, mode)
	return a


func _add_ant_soul(agent_name: String, base_url: String, model: String, key: String) -> Soul:
	var soul: Soul = AntSoul.new(agent_name, base_url, model, key, self)
	soul.ant_ref().set_necro(func(args: Dictionary) -> Dictionary:
		return api_necro_for(soul, args))
	soul.ant_ref().necro_depth = 1
	soul.ant_ref().soul_name = agent_name
	_register_soul(soul, "agent %s @ %s" % [model, base_url])
	_restore_agent_history(soul)
	return soul


## Reattach an agent's saved chat (user://ant/sessions, newest match by soul
## name) so a re-summoned ant picks up where it left off.
func _restore_agent_history(soul: Soul) -> void:
	var ant := (soul as AntSoul).ant_ref()
	var sid := ant.latest_session_for(soul.name_text)
	if sid == "" or not ant.load_session(sid):
		return
	var id := soul.get_instance_id()
	var msgs := ant.saved_transcript()
	for m in msgs:
		history[id].append(m)
	history[id].append(["system", "restored %d messages from %s" % [msgs.size(), sid]])
	panels[id].replay(history[id])


func _register_soul(a: Soul, mode_text: String) -> void:
	agents.append(a)
	history[a.get_instance_id()] = [["system", "summoned (%s)" % mode_text]]
	var panel := ChatPanel.new()
	panel.setup(a)
	panel.set_mini(true)
	panel.replay(history[a.get_instance_id()])
	panels[a.get_instance_id()] = panel
	# The node card embeds the soul's one-true transcript (ComfyUI-style live
	# preview inside the node).
	_make_node_card(a, agents.size() - 1)
	_node_slots[a.get_instance_id()].add_child(panel)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_add_row_widget(a)
	selected = a
	bus.emit_event("spawned", a.name_text, mode_text)


func _open_new_dialog() -> void:
	_name_edit.text = _next_name()
	_cmd_edit.text = ""
	_new_dialog.popup_centered(Vector2i(460, 640))


func _on_new_confirmed() -> void:
	var agent_name := _name_edit.text.strip_edges()
	if agent_name == "":
		return
	var cmd := _cmd_edit.text.strip_edges()
	match _type_pick.selected:
		0:
			_add_agent(agent_name, "")
		1:
			if cmd != "":
				_add_agent(agent_name, cmd)
		2:
			if cmd != "":
				_add_agent(agent_name, _ssh_wrap(cmd, _ssh_pick.selected - 1))
		3:
			_add_ant_soul(agent_name, _url_edit.text.strip_edges(),
					_model_edit.text.strip_edges(), _key_edit.text)


## Wraps a plain local command in a non-interactive ssh line: the whole remote
## command becomes one quoted argument that ssh hands to the remote shell.
## Inner double quotes would break the wrap — use single quotes remotely.
## Requires the owner's key on the host (BatchMode: password prompts hang a
## headless process, so they are disabled).
func _ssh_wrap(cmd: String, host_idx: int) -> String:
	var host: String = SSH_HOSTS[host_idx][1]
	return 'ssh -o BatchMode=yes %s "%s"' % [host, cmd]


func _heal_all() -> void:
	var healed := 0
	for a in agents:
		if a.get_state() == "dead":
			a.revive()   # revive() emits its own "heal" event
			healed += 1
	if healed == 0:
		_say_alert("No dead souls in the pool.")


func _stop_all() -> void:
	for a in agents:
		a.cancel()
		_record(a, "system", "stop requested")


# ---------- selection and rendering ----------

func _select(a: Soul) -> void:
	selected = a


func _input(ev: InputEvent) -> void:
	# Mobile pager: swipe left/right inside an open chat moves between souls.
	if not mobile or expanded == null:
		return
	if ev is InputEventScreenTouch:
		if ev.pressed:
			_swipe_x = ev.position.x
			_swipe_y = ev.position.y
		elif _swipe_x >= 0.0:
			var dx: float = ev.position.x - _swipe_x
			var dy: float = ev.position.y - _swipe_y
			_swipe_x = -1.0
			if absf(dx) > 140.0 and absf(dx) > absf(dy) * 1.2:
				_open_neighbor(-1 if dx > 0.0 else 1)


func _open_neighbor(dir: int) -> void:
	if agents.is_empty() or expanded == null:
		return
	var idx := agents.find(expanded)
	if idx < 0:
		return
	var next := posmod(idx + dir, agents.size())
	_open_soul(agents[next])


func _record(a: Soul, kind: String, text: String) -> void:
	var key := a.get_instance_id()
	if not history.has(key):
		return
	var ts := Time.get_time_string_from_system().substr(0, 5)
	history[key].append([kind, text])
	if kind == "you" or kind == "output":
		_last_text[key] = text
		_last_ts[key] = ts
	if (kind == "output" or kind == "error") and expanded != a:
		_unread[key] = int(_unread.get(key, 0)) + 1
	if panels.has(key):
		panels[key].append(kind, text)
	bus.emit_event(kind, a.name_text, text)


# ---------- messaging ----------

func _send() -> void:
	var text := _entry.text.strip_edges()
	if text == "":
		return
	var targets: Array[Soul] = []
	if _broadcast_on:
		if _optimize_on:
			for a in agents:
				if a.get_state() == "idle" and a.queued() == 0:
					targets.append(a)
			if targets.is_empty():
				_say_alert("Optimize is on: every soul is busy. No idle target.")
				return
		else:
			targets = agents.duplicate()
	elif selected != null:
		targets.append(selected)
	if targets.is_empty():
		_say_alert("The pool is empty. Spawn a soul first.")
		return
	for a in targets:
		if a.get_state() == "dead":
			a.revive()   # Repeat...: whispering to a dead soul revives it first.
		_record(a, "you", text)
		a.submit(text)
	_entry.clear()


# ---------- main loop: pull events from worker threads ----------

func _process(_delta: float) -> void:
	var busy := 0
	var dead := 0
	var queued := 0
	for a in agents:
		for ev in a.drain_events():
			_record(a, ev[0], ev[1])
		var st := a.get_state()
		var q := a.queued()
		if st == "busy":
			busy += 1
		elif st == "dead":
			dead += 1
		queued += q
		_update_row(a, st, q)
		_update_node_card(a, st)
	var line := "%d souls · %d busy · %d queued" % [agents.size(), busy, queued]
	if dead > 0:
		line += " · %d DEAD — heal them" % dead
	if _optimize_on:
		line += " · optimize: idle-only"
	if _status_label.text != line:
		_status_label.text = line
	_status_label.add_theme_color_override(
			"font_color", COL_DEAD if dead > 0 else COL_SUB)
	_update_typing()
	# Slide the layout above the on-screen keyboard while typing (Android).
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		var kb := DisplayServer.virtual_keyboard_get_height()
		_root.position.y = -float(kb)
	_advance_slides(_delta)


## Eases every running page slide (cubic ease-out); fires done callbacks.
func _advance_slides(delta: float) -> void:
	var finished: Array = []
	for page in _slide:
		var s: Dictionary = _slide[page]
		s["t"] = minf(float(s["t"]) + delta / SLIDE_S, 1.0)
		var e := 1.0 - pow(1.0 - float(s["t"]), 3.0)
		_place(page, lerpf(float(s["from"]), float(s["to"]), e))
		if float(s["t"]) >= 1.0:
			finished.append(page)
	for page in finished:
		var done: Callable = _slide[page]["done"]
		_slide.erase(page)
		if done.is_valid():
			done.call()


## Chat header sub-line doubles as the typing indicator: a busy soul shows
## "typing...", otherwise its state with the state color.
func _update_typing() -> void:
	if expanded == null or _chat_sub == null or not is_instance_valid(_chat_sub):
		return
	var st := expanded.get_state()
	var q := expanded.queued()
	var txt := ""
	var col := COL_SUB
	if st == "busy":
		txt = "typing..." if q == 0 else "typing · %d queued" % q
		col = COL_ACCENT
	elif q > 0:
		txt = "%s · %d queued" % [st, q]
		col = STATE_COLORS.get(st, COL_SUB)
	else:
		txt = st
		col = STATE_COLORS.get(st, COL_SUB)
	if _chat_sub.text != txt:
		_chat_sub.text = txt
	_chat_sub.add_theme_color_override("font_color", col)


# ---------- chat lobby ----------

static var _dot_cache := {}

## Little colored status dot for the lobby rows (idle/busy/dead).
func _dot(state: String) -> Texture2D:
	if _dot_cache.has(state):
		return _dot_cache[state]
	var col: Color = STATE_COLORS.get(state, COL_SUB)
	var img := Image.create(10, 10, false, Image.FORMAT_RGBA8)
	for x in 10:
		for y in 10:
			if Vector2(x - 4.5, y - 4.5).length() <= 4.0:
				img.set_pixel(x, y, col)
	var tex := ImageTexture.create_from_image(img)
	_dot_cache[state] = tex
	return tex
