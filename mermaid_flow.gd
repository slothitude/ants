class_name MermaidFlow
extends Control
## The ScuLLM Watch centerpiece: an OFL-dialect mermaid flow rendered as a
## hologram-style map, with the %% <== YOU ARE HERE marker as a live walk
## cursor. Parser keeps to the corpora dialect (walker/planner/translator
## trees) — node forms N0["action"] / N1{"gate"} / N3[/"code_task"/]
## N5(["done"]), labeled edges N1 -- "confirmed" --> N2. Walker answers
## (branch label / jump:nX / replan) move the cursor along the edges.

signal cursor_moved(node_id: String)
signal replanned

const COL_BG := Color(0.02, 0.03, 0.05, 0.85)
const COL_EDGE := Color(0.42, 0.62, 0.85, 0.85)
const COL_EDGE_DIM := Color(0.25, 0.35, 0.5, 0.6)
const COL_NODE_ACTION := Color(0.09, 0.14, 0.2)
const COL_NODE_GATE := Color(0.16, 0.12, 0.04)
const COL_NODE_CODE := Color(0.06, 0.16, 0.1)
const COL_NODE_DONE := Color(0.18, 0.14, 0.02)
const COL_FRAME_ACTION := Color(0.35, 0.5, 0.68)
const COL_FRAME_GATE := Color(0.9, 0.64, 0.24)
const COL_FRAME_CODE := Color(0.3, 0.78, 0.45)
const COL_FRAME_DONE := Color(0.95, 0.8, 0.25)
const COL_TEXT := Color(0.92, 0.95, 1.0)
const COL_HERE := Color(0.35, 0.85, 1.0)
const COL_LABEL := Color(0.7, 0.8, 0.95, 0.9)

const NODE_W := 150.0
const NODE_H := 44.0
const COL_GAP := 78.0
const ROW_GAP := 24.0
const CURSOR_SPEED := 3.2   # lerp factor per frame for the walk marker

# Kenney art (CC0, tracked miniset in art/kenney_min/ — the full packs stay
# local-only): the walk cursor is a board-game piece, gates carry a die chip,
# code nodes wear a drawn </> mark, done/goal gets a drawn star.
const CURSOR_TEX := "res://art/kenney_min/pieceYellow_multi11.png"
const DIE_TEX := "res://art/kenney_min/dieRed_border1.png"
const CURSOR_TEX_ALT := "res://art/kenney_min/pieceYellow_multi01.png"

class FlowNode:
	var id: String
	var label: String
	var kind: String        # action | gate | code | done
	var level := 0
	var pos := Vector2.ZERO # layout space (before fit transform)
	var is_here := false

class FlowEdge:
	var from_id: String
	var to_id: String
	var label: String

var _nodes := {}          # id -> FlowNode
var _order: Array = []    # ids in parse order (stable row layout)
var _edges: Array = []    # FlowEdge
var _here := ""           # cursor node id
var _cursor_from := Vector2.ZERO
var _cursor_to := Vector2.ZERO
var _cursor_t := 1.0      # 1.0 = arrived
var _cursor_pos := Vector2.ZERO
var _bounds := Rect2()
var _pulse_t := 0.0
var _cursor_tex: Texture2D
var _die_tex: Texture2D


func _init() -> void:
	_cursor_tex = _load_art(CURSOR_TEX)
	if _cursor_tex == null:
		_cursor_tex = _load_art(CURSOR_TEX_ALT)
	_die_tex = _load_art(DIE_TEX)


static func _load_art(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	return null


# ---------- parsing (the OFL corpora dialect) ----------

## Parses a mermaid tree. Returns false when no nodes were found.
func set_flow(text: String) -> bool:
	_nodes.clear()
	_order.clear()
	_edges.clear()
	_here = ""
	var node_re := RegEx.new()
	node_re.compile("^\\s*(\\w+)\\s*([\\[{(\"]+)(.*)$")
	var here_re := RegEx.new()
	here_re.compile("^\\s*(\\w+).*%%\\s*<==\\s*YOU ARE HERE")
	var edge_re := RegEx.new()
	edge_re.compile("^\\s*(\\w+)\\s*--\\s*\"?([^\"]*)\"?\\s*-->\\s*(\\w+)")
	var plain_re := RegEx.new()
	plain_re.compile("^\\s*(\\w+)\\s*-->\\s*(\\w+)")
	for line in text.split("\n"):
		var here_m := here_re.search(line)
		if here_m:
			_here = here_m.get_string(1)
			line = line.substr(0, here_m.get_start(0))   # strip the marker
		var em := edge_re.search(line)
		if em and em.get_start(0) == 0:
			_edges.append(_mk_edge(em.get_string(1), em.get_string(3), em.get_string(2)))
			continue
		var pm := plain_re.search(line)
		if pm and pm.get_start(0) == 0:
			_edges.append(_mk_edge(pm.get_string(1), pm.get_string(2), ""))
			continue
		var nm := node_re.search(line)
		if nm == null or nm.get_start(0) != 0:
			continue
		var id := nm.get_string(1)
		var rest: String = nm.get_string(3).strip_edges()
		var kind := _kind_of(nm.get_string(2), rest)
		var label := _label_of(rest)
		if id == "graph" or id == "flowchart":
			continue
		if label == "":
			continue
		var n := FlowNode.new()
		n.id = id
		n.label = label
		n.kind = kind
		n.is_here = (id == _here)
		_nodes[id] = n
		_order.append(id)
	if _nodes.is_empty():
		return false
	if _here == "" and _order.size() > 0:
		_here = _order[0]   # no marker: start at the first node
	_layout()
	_cursor_pos = _node_screen_center(_here)
	_cursor_from = _cursor_pos
	_cursor_to = _cursor_pos
	_cursor_t = 1.0
	queue_redraw()
	return true


func _kind_of(open: String, rest: String) -> String:
	if open.contains("{"):
		return "gate"
	var l := rest.to_lower()
	if l.begins_with("/\"") or l.begins_with("[/"):
		return "code"
	if l.begins_with("(\"") or l.contains("(\""):
		return "done"
	if l.contains("done:") or l.contains("flag"):
		return "done"
	if l.contains("code_task"):
		return "code"
	if l.contains("replan"):
		return "gate"
	return "action"


func _label_of(rest: String) -> String:
	# take what's between the first and last quote, else strip shape syntax
	var a := rest.find("\"")
	var b := rest.rfind("\"")
	if a >= 0 and b > a:
		return rest.substr(a + 1, b - a - 1)
	return rest.trim_prefix("[").trim_prefix("{").trim_suffix("]").trim_suffix("}").strip_edges()


func _mk_edge(f: String, t: String, label: String) -> FlowEdge:
	var e := FlowEdge.new()
	e.from_id = f
	e.to_id = t
	e.label = label.strip_edges()
	return e


# ---------- layout: BFS levels from the first node ----------

func _layout() -> void:
	var start := _order[0]
	var levels := {}          # id -> depth
	var queue: Array = [start]
	levels[start] = 0
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		for e in _edges:
			if e.from_id == cur and not levels.has(e.to_id):
				levels[e.to_id] = int(levels[cur]) + 1
				queue.append(e.to_id)
	# unlinked nodes trail after the deepest level
	var max_lv := 0
	for id in _order:
		if not levels.has(id):
			levels[id] = max_lv + 1
		max_lv = max(max_lv, int(levels[id]))
	var by_level := {}
	for id in _order:
		var lv := int(levels[id])
		if not by_level.has(lv):
			by_level[lv] = []
		by_level[lv].append(id)
	var y_cursor := 0.0
	for lv in range(0, max_lv + 1):
		var ids: Array = by_level.get(lv, [])
		var col_h := ids.size() * (NODE_H + ROW_GAP)
		var y0 := y_cursor + (0.0 if ids.is_empty() else 0.0)
		for i in ids.size():
			var n: FlowNode = _nodes[ids[i]]
			n.level = lv
			n.pos = Vector2(lv * (NODE_W + COL_GAP), y0 + i * (NODE_H + ROW_GAP))
		y_cursor += col_h + ROW_GAP * 2.0
	var max_x := 0.0
	for id in _order:
		var n: FlowNode = _nodes[id]
		max_x = max(max_x, n.pos.x + NODE_W)
	_bounds = Rect2(0, 0, maxf(max_x, NODE_W), maxf(y_cursor, NODE_H))


func _scale() -> float:
	var avail := size - Vector2(24, 24)
	if _bounds.size.x <= 1 or _bounds.size.y <= 1:
		return 1.0
	var sx := avail.x / _bounds.size.x
	var sy := avail.y / _bounds.size.y
	return clampf(minf(sx, sy), 0.35, 1.4)


func _node_screen_center(id: String) -> Vector2:
	if not _nodes.has(id):
		return size / 2.0
	var n: FlowNode = _nodes[id]
	var s := _scale()
	var c := (n.pos + Vector2(NODE_W, NODE_H) / 2.0) * s + Vector2(12, 12)
	# columns can overflow vertically on tall trees; clamp into view
	c.y = clampf(c.y, 20.0, size.y - 20.0)
	return c


# ---------- the walk ----------

## Feeds one walker answer. Returns {ok, kind, to} — kind is jump | replan | stuck.
func walk(answer: String) -> Dictionary:
	var a := answer.strip_edges()
	if a == "":
		return {"ok": false, "kind": "stuck", "to": _here}
	if a.to_lower() == "replan":
		replanned.emit()
		queue_redraw()
		return {"ok": true, "kind": "replan", "to": _here}
	var target := ""
	if a.to_lower().begins_with("jump:"):
		target = a.substr(5).strip_edges().to_upper()
		if not _nodes.has(target):
			target = ""
	elif _nodes.has(a.to_upper()):
		target = a.to_upper()
	if target == "":
		target = _edge_target_by_label(a)
	if target == "":
		return {"ok": false, "kind": "stuck", "to": _here}
	_move_cursor(target)
	return {"ok": true, "kind": "jump", "to": target}


func _edge_target_by_label(label: String) -> String:
	for e in _edges:
		if e.from_id == _here and e.label.to_lower() == label.to_lower():
			return e.to_id
	return ""


func _move_cursor(to_id: String) -> void:
	if not _nodes.has(to_id):
		return
	if _nodes.has(_here):
		_nodes[_here].is_here = false
	_here = to_id
	_nodes[to_id].is_here = true
	_cursor_from = _cursor_pos
	_cursor_to = _node_screen_center(to_id)
	_cursor_t = 0.0
	cursor_moved.emit(to_id)
	queue_redraw()


func here() -> String:
	return _here


func node_count() -> int:
	return _nodes.size()


func edge_count() -> int:
	return _edges.size()


## Gate branches available from the cursor (for the UI hints).
func branches() -> Array:
	var out := []
	for e in _edges:
		if e.from_id == _here and e.label != "":
			out.append(e.label)
	return out


# ---------- drawing ----------

func _process(delta: float) -> void:
	_pulse_t += delta
	if _cursor_t < 1.0:
		_cursor_t = minf(_cursor_t + delta * CURSOR_SPEED, 1.0)
		var e := 1.0 - pow(1.0 - _cursor_t, 3.0)
		_cursor_pos = _cursor_from.lerp(_cursor_to, e)
	queue_redraw()


func _draw() -> void:
	var s := _scale()
	# holo backdrop: vignette + faint grid
	draw_rect(Rect2(Vector2.ZERO, size), COL_BG)
	var grid := Color(0.5, 0.7, 1.0, 0.05)
	var step := 28.0
	var x := step
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), grid, 1.0)
		x += step
	var y := step
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), grid, 1.0)
		y += step
	# edges first (under the nodes)
	for e in _edges:
		if not _nodes.has(e.from_id) or not _nodes.has(e.to_id):
			continue
		var a := _node_screen_center(e.from_id)
		var b := _node_screen_center(e.to_id)
		var active := e.from_id == _here or e.to_id == _here
		draw_line(a, b, COL_EDGE if active else COL_EDGE_DIM, 2.0 if active else 1.2)
		_arrow_head(a, b, COL_EDGE if active else COL_EDGE_DIM)
		if e.label != "":
			_edge_label(a, b, e.label, active)
	# nodes
	var font := get_theme_default_font()
	var fsize := get_theme_default_font_size()
	for id in _order:
		var n: FlowNode = _nodes[id]
		var top_left := (n.pos) * s + Vector2(12, 12)
		var sz := Vector2(NODE_W, NODE_H) * s
		_draw_node(n, Rect2(top_left, sz), font, fsize)
	_draw_cursor(s, font, fsize)


func _draw_node(n: FlowNode, r: Rect2, font: Font, fsize: int) -> void:
	var frame := COL_FRAME_ACTION
	var fill := COL_NODE_ACTION
	match n.kind:
		"gate":
			frame = COL_FRAME_GATE
			fill = COL_NODE_GATE
		"code":
			frame = COL_FRAME_CODE
			fill = COL_NODE_CODE
		"done":
			frame = COL_FRAME_DONE
			fill = COL_NODE_DONE
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = frame
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10 if n.kind != "gate" else 4)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	draw_style_box(sb, r)
	# glyph column
	var glyph_r := Rect2(r.position + Vector2(5, r.size.y / 2.0 - 11), Vector2(22, 22))
	match n.kind:
		"gate":
			if _die_tex:
				draw_texture_rect(_die_tex, glyph_r, false)
			else:
				draw_polygon(_diamond(glyph_r.get_center(), 11),
						PackedVector2Array(), PackedColorArray([COL_FRAME_GATE]))
		"code":
			_draw_ant_face(glyph_r)
		"done":
			draw_polygon(_star(glyph_r.get_center(), 11, 5),
					PackedVector2Array(), PackedColorArray([COL_FRAME_DONE]))
		_:
			var c := glyph_r.get_center()
			draw_line(Vector2(c.x - 6, c.y - 5), Vector2(c.x - 6, c.y + 5), frame, 2.0)
			draw_line(Vector2(c.x + 6, c.y - 5), Vector2(c.x + 6, c.y + 5), frame, 2.0)
			draw_line(Vector2(c.x - 2, c.y - 7), Vector2(c.x + 3, c.y + 7), frame, 2.0)
	# label, wrapped to two lines
	var text_r := Rect2(r.position + Vector2(30, 2), r.size - Vector2(34, 4))
	var lines := _wrap(n.label, font, int(fsize * 0.86), int(text_r.size.x))
	var lh := float(fsize) * 0.86 + 2.0
	var y := text_r.position.y + maxf(0.0, (text_r.size.y - lines.size() * lh) / 2.0) + float(fsize) * 0.8
	for i in mini(lines.size(), 2):
		draw_string(font, Vector2(text_r.position.x, y + i * lh), lines[i],
				HORIZONTAL_ALIGNMENT_LEFT, text_r.size.x, int(fsize * 0.86), COL_TEXT)
	# YOU ARE HERE halo
	if n.is_here:
		var pulse := 0.5 + 0.5 * sin(_pulse_t * 4.0)
		draw_arc(r.get_center(), maxf(r.size.x, r.size.y) * 0.62 + pulse * 6.0,
				0, TAU, 48, Color(COL_HERE.r, COL_HERE.g, COL_HERE.b, 0.5 + 0.3 * pulse), 2.0)


func _draw_cursor(s: float, font: Font, fsize: int) -> void:
	# the walk marker: a Kenney piece riding the cursor node
	var bob := sin(_pulse_t * 3.0) * 3.0
	var pos := _cursor_pos + Vector2(-10, -34 + bob)
	if _cursor_tex:
		draw_texture_rect(_cursor_tex, Rect2(pos, Vector2(24, 24)), false)
		draw_string(font, pos + Vector2(26, 12), "YOU ARE HERE",
				HORIZONTAL_ALIGNMENT_LEFT, 120, int(fsize * 0.72), COL_HERE)
	else:
		draw_circle(_cursor_pos + Vector2(0, -20), 7.0, COL_HERE)


func _draw_ant_face(r: Rect2) -> void:
	# tiny </> mark for code_task seats
	var c := r.get_center()
	draw_string(get_theme_default_font(), Vector2(c.x - 10, c.y + 5), "</>",
			HORIZONTAL_ALIGNMENT_CENTER, 20, 11, COL_FRAME_CODE)


func _arrow_head(a: Vector2, b: Vector2, col: Color) -> void:
	var d := (b - a).normalized()
	if d == Vector2.ZERO:
		return
	var tip := b
	var left := tip - d.rotated(0.5) * 9.0
	var right := tip - d.rotated(-0.5) * 9.0
	draw_polygon(PackedVector2Array([tip, left, right]), PackedColorArray([col]))


func _edge_label(a: Vector2, b: Vector2, text: String, active: bool) -> void:
	var font := get_theme_default_font()
	var fsize := int(get_theme_default_font_size() * 0.72)
	var mid := (a + b) / 2.0
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
	var r := Rect2(mid - Vector2(w / 2.0 + 5, 10), Vector2(w + 10, 20))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.05, 0.08, 0.85)
	sb.border_color = COL_EDGE if active else COL_EDGE_DIM
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	draw_style_box(sb, r)
	draw_string(font, Vector2(r.position.x + 5, r.position.y + 14), text,
			HORIZONTAL_ALIGNMENT_LEFT, w + 2, fsize, COL_LABEL if active else COL_LABEL * Color(1, 1, 1, 0.6))


func _wrap(text: String, font: Font, fsize: int, width: float) -> Array:
	if width <= 10:
		return [text]
	var words := text.split(" ")
	var lines := []
	var cur := ""
	for w in words:
		var t := (cur + " " + w).strip_edges()
		if font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x > width and cur != "":
			lines.append(cur)
			cur = w
		else:
			cur = t
	if cur != "":
		lines.append(cur)
	return lines


func _diamond(c: Vector2, r: float) -> PackedVector2Array:
	return PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)])


func _star(c: Vector2, r: float, points: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in points * 2:
		var ang := -PI / 2.0 + TAU * float(i) / float(points * 2)
		var rad := r if i % 2 == 0 else r * 0.45
		out.append(c + Vector2(cos(ang), sin(ang)) * rad)
	return out
