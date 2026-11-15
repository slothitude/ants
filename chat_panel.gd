class_name ChatPanel
extends PanelContainer
## One soul's full chat, Telegram-style: bubbles (right = you in 2b5278,
## left = the soul in 182533), rounded corners, dim timestamps. Lives inside
## a SubViewport tile on the desktop or — expanded — fills the chat page.
## The transcript exists in exactly one place per soul; expansion is just
## re-parenting.

const COL_BG := Color("0e1621")
const COL_PANEL := Color("17212b")
const COL_HEADER := Color("1f2c3a")
const COL_SUB := Color("7d8b99")
const COL_TEXT := Color("f5f5f5")
const COL_BUBBLE_IN := Color("182533")
const COL_BUBBLE_OUT := Color("2b5278")
const COL_DEAD := Color("ff4d5e")
const COL_ONLINE := Color("4fae4e")

var soul: Soul
var events: Array = []         # [{k, t, ts}] — the one true transcript
var bubble_width := 300.0

var _scroll: ScrollContainer
var _messages: VBoxContainer
var _head: Label
var _mini := true


func setup(p_soul: Soul) -> void:
	soul = p_soul
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	_style_panel()
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_messages = VBoxContainer.new()
	_messages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages.add_theme_constant_override("separation", 10)
	_scroll.add_child(_messages)

	_head = Label.new()
	_head.text = soul.name_text
	_head.add_theme_font_size_override("font_size", 13)
	_head.add_theme_color_override("font_color", COL_SUB)
	_messages.add_child(_head)


## Mini tiles show compact rows at 12px; the expanded chat reads full size
## with wide bubbles. Rebuilds the transcript since bubble layout changes.
## Bails out when the panel (or its children) are queued for deletion — stray
## clicks can still route here after a Reap.
func set_mini(mini: bool) -> void:
	if is_queued_for_deletion() or not is_instance_valid(_head):
		return
	_mini = mini
	bubble_width = 280.0 if mini else 460.0
	_style_panel()
	_head.visible = mini
	_rebuild_all()


## Tiles get a bordered panel look; the full chat page is the flat Telegram
## chat background.
func _style_panel() -> void:
	var sb := StyleBoxFlat.new()
	if _mini:
		sb.bg_color = COL_PANEL
		sb.border_color = COL_HEADER
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(12)
	else:
		sb.bg_color = COL_BG
	sb.set_content_margin_all(8)
	add_theme_stylebox_override("panel", sb)


func append(kind: String, text: String) -> void:
	var ts := Time.get_time_string_from_system().substr(0, 5)
	events.append({"k": kind, "t": text, "ts": ts})
	_add_row(kind, text, ts)
	_scroll_to_bottom.call_deferred()


func replay(events_array: Array) -> void:
	events.clear()
	_clear_messages()
	for e in events_array:
		var ts := Time.get_time_string_from_system().substr(0, 5)
		var k := str(e[0])
		var t := str(e[1])
		events.append({"k": k, "t": t, "ts": ts})
		_add_row(k, t, ts)
	_scroll_to_bottom.call_deferred()


# ---------- internals ----------

func _clear_messages() -> void:
	while _messages.get_child_count() > 0:
		var c := _messages.get_child(0)
		_messages.remove_child(c)
		c.queue_free()


func _rebuild_all() -> void:
	_clear_messages()
	_head = null
	var first := true
	for e in events:
		if first:
			_add_head()
			first = false
		_add_row(str(e["k"]), str(e["t"]), str(e["ts"]))
	if first:
		_add_head()
	_scroll_to_bottom.call_deferred()


func _add_head() -> void:
	_head = Label.new()
	_head.text = soul.name_text
	_head.add_theme_font_size_override("font_size", 12)
	_head.add_theme_color_override("font_color", COL_SUB)
	_messages.add_child(_head)


func _add_row(kind: String, text: String, ts: String) -> void:
	match kind:
		"you":
			_add_bubble(true, text, ts, COL_BUBBLE_OUT, COL_TEXT)
		"output":
			if _mini:
				_plain_row("[color=#f5f5f5]%s[/color]" % text)
			else:
				var head := Label.new()
				head.text = "%s  ·  %s" % [who_for(kind), ts]
				head.add_theme_font_size_override("font_size", 11)
				head.add_theme_color_override("font_color", COL_SUB)
				_messages.add_child(head)
				_add_bubble(false, text, ts, COL_BUBBLE_IN, COL_TEXT)
		"error":
			_plain_row("[color=#ff4d5e]![/color] " + text)
		"dead":
			_plain_row("[color=#ff4d5e]×[/color] " + text)
		"heal":
			_plain_row("[color=#4fae4e]+[/color] " + text)
		"system":
			_plain_row("[color=#7d8b99]• " + text + "[/color]")
		_:
			_plain_row("[color=#f5f5f5]" + text + "[/color]")


func who_for(kind: String) -> String:
	return soul.name_text if soul != null else "?"


func _plain_row(bb: String) -> void:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("normal_font_size", 12 if _mini else 14)
	_messages.add_child(l)
	l.append_text(bb)


## A real bubble: PanelContainer with a rounded style, pushed to the right
## (you) or left (the soul), autowrapping at the configured width. Bodies are
## MarkdownLabel (markdown in — bold/lists/code render formatted).
## A real bubble: PanelContainer with a rounded style, pushed to the right
## (you) or left (the soul). On narrow (portrait) screens the bubble takes
## most of the width — the simple-chat look.
func _add_bubble(right: bool, text: String, ts: String, bg: Color, fg: Color) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vw := get_viewport_rect().size.x
	var width := bubble_width
	if vw < bubble_width * 1.6:
		width = vw * 0.82

	var bubble := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(16)
	sb.set_content_margin_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	bubble.add_theme_stylebox_override("panel", sb)

	var l: RichTextLabel = MarkdownLabel.new()
	l.fit_content = true
	l.scroll_active = false
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = width
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var font_size := 12 if _mini else 16
	for fs in ["normal_font_size", "bold_font_size", "italics_font_size", "mono_font_size"]:
		l.add_theme_font_size_override(fs, font_size)
	l.add_theme_color_override("default_color", fg)
	l.text = _esc(text) + "\n\n*" + ts + "*"
	bubble.add_child(l)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if right:
		row.add_child(spacer)
		row.add_child(bubble)
	else:
		row.add_child(bubble)
		row.add_child(spacer)
	_messages.add_child(row)


func _esc(s: String) -> String:
	# Markdown bodies pass [ through the MarkdownLabel's own escaping; nothing
	# to strip here — kept as an escape hatch for plain-text variants.
	return s


func _scroll_to_bottom() -> void:
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)
