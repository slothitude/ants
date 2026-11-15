extends SceneTree
## GMP gate suite for the NecroMancer console (M0). Run headless:
##   GODOT --headless --path . --script res://tests/test_console.gd
## Exit 0 = green. One line per check; a red summary on failure.

var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_test_splitter()
	await _test_echo()
	await _test_cancel()
	if OS.get_name() == "Windows":
		await _test_death_and_revive()
	await _test_console()
	_finish()


func _check(cond: bool, what: String) -> void:
	checks += 1
	if cond:
		print("  ok   " + what)
	else:
		fails.append(what)
		printerr("  FAIL " + what)


func _wait_until(pred: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if pred.call():
			return true
		await create_timer(0.1).timeout
		t += 0.1
	return pred.call()


func _test_splitter() -> void:
	print("[splitter]")
	var parts := AgentWorker._split_args('python x.py --task "two words" end')
	_check(parts.size() == 5, "quoted command splits into 5 parts")
	_check(String(parts[3]) == "two words", "double quotes keep words together")


func _test_echo() -> void:
	print("[worker echo]")
	var w := AgentWorker.new("echo-1", "")
	w.submit("hello world")
	# Wait for busy first: idle is the initial state, so waiting for it
	# directly would pass before the worker thread even wakes.
	var busy := await _wait_until(func() -> bool: return w.get_state() == "busy", 2.0)
	_check(busy, "echo run starts (busy)")
	var done := await _wait_until(func() -> bool: return w.get_state() == "idle", 8.0)
	_check(done, "echo run returns to idle")
	var got := false
	for ev in w.drain_events():
		if ev[0] == "output" and String(ev[1]).contains("echo: hello world"):
			got = true
	_check(got, "echo output carries the prompt")
	w.shutdown()
	w.wait_done()


func _test_cancel() -> void:
	print("[cancel]")
	var w := AgentWorker.new("echo-2", "")
	w.submit("doomed")
	await create_timer(0.3).timeout
	w.cancel()
	var idle := await _wait_until(func() -> bool: return w.get_state() == "idle", 5.0)
	_check(idle, "cancelled run returns to idle")
	var saw := false
	for ev in w.drain_events():
		if ev[0] == "system" and String(ev[1]).contains("cancelled"):
			saw = true
	_check(saw, "cancel is reported")
	w.shutdown()
	w.wait_done()


func _test_death_and_revive() -> void:
	print("[death and revive]")
	var w := AgentWorker.new("doomed-1", "cmd.exe /c exit 7")
	w.submit("rise")
	var dead := await _wait_until(func() -> bool: return w.get_state() == "dead", 10.0)
	_check(dead, "non-zero exit marks the agent dead")
	var reason := false
	for ev in w.drain_events():
		if ev[0] == "dead" and String(ev[1]).contains("7"):
			reason = true
	_check(reason, "death reason carries the exit code")
	w.revive()
	_check(w.get_state() == "idle", "revive returns the soul to idle")
	w.submit("again")
	var dead2 := await _wait_until(func() -> bool: return w.get_state() == "dead", 10.0)
	_check(dead2, "revived soul runs the command again")
	w.shutdown()
	w.wait_done()


func _test_console() -> void:
	print("[console scene]")
	var scene: PackedScene = load("res://main.tscn")
	_check(scene != null, "main.tscn loads")
	var console = scene.instantiate()
	root.add_child(console)
	await process_frame
	await process_frame

	var agents: Array = console.get("agents")
	_check(agents.size() == 3, "three souls summoned on boot")
	var rows: Dictionary = console.get("_rows")
	_check(rows.size() == 3, "lobby shows a row for every soul")
	var nest: GraphEdit = console.get("_nest")
	_check(nest != null and (console.get("_nodes") as Dictionary).size() == 3,
			"the nest canvas shows 3 agent nodes")
	console._on_wire_request("Qwen3.5", 0, "GLM-5.3", 0)
	var wires: Array = console.get("_wires")
	_check(wires.size() == 1, "connecting two nodes records a whisper pipe")
	var first: Soul = agents[0]
	var node_sel: GraphNode = console.get("_nodes")[first.get_instance_id()]
	_check(node_sel != null and node_sel.get_meta("soul_id", 0) == first.get_instance_id(),
			"each node card carries its soul")
	# Selecting a nest node must retarget the composer (node_selected is 0-arg).
	console.set("selected", null)
	node_sel.emit_signal("node_selected")
	await process_frame
	_check(console.get("selected") == first, "selecting a nest node targets that soul")
	var mdl := MarkdownLabel.new()
	root.add_child(mdl)
	mdl.text = "**bold** and `code` and a list"
	await create_timer(0.3).timeout
	var parsed := mdl.get_parsed_text()
	print("    [md parsed] ", parsed.strip_edges())
	_check(parsed.contains("bold"), "markdown label renders markdown")
	_check(not parsed.contains("**"), "markdown syntax is consumed, not shown")
	mdl.queue_free()

	# Telegram lobby: search filters rows by name.
	console.get("_search").text = "Qwen"
	console._apply_filter()
	var a0: Soul = agents[0]
	var a1: Soul = agents[1]
	var row0: Dictionary = rows[a0.get_instance_id()]
	var row1: Dictionary = rows[a1.get_instance_id()]
	_check((row0["btn"] as Control).visible, "search keeps the matching soul row")
	_check(not (row1["btn"] as Control).visible, "search hides non-matching soul rows")
	console.get("_search").text = ""
	console._apply_filter()
	_check((row1["btn"] as Control).visible, "clearing search restores every row")

	# Chat page: expand, typing indicator, unread badge, collapse.
	console._expand_chat(a0)
	await process_frame
	var stage: Control = console.get("_stage")
	_check(stage.visible, "tapping a row slides in the chat page")
	var avatar_count := (console.get("_avatar_host") as Control).get_child_count()
	_check(avatar_count > 0, "chat header shows the soul's avatar")
	console._entry.text = "hello"
	console._send()
	var typing_pred := func() -> bool:
		return String(console.get("_chat_sub").text).contains("typing")
	var typing := await _wait_until(typing_pred, 3.0)
	_check(typing, "busy soul shows a typing indicator in the chat header")
	var sel: AgentWorker = console.get("selected")
	var idle := await _wait_until(func() -> bool: return sel.get_state() == "idle", 8.0)
	_check(idle, "whisper to the chosen soul completes")
	var h: Array = console.get("history")[sel.get_instance_id()]
	var saw_you := false
	var saw_echo := false
	for ev in h:
		if ev[0] == "you" and ev[1] == "hello":
			saw_you = true
		if ev[0] == "output" and String(ev[1]).contains("echo: hello"):
			saw_echo = true
	_check(saw_you, "your whisper is recorded")
	_check(saw_echo, "the soul's answer is recorded")

	# Answers to souls whose chat is closed raise their unread badge.
	console.api_whisper(a1.name_text, "badge me")
	var unread_pred := func() -> bool:
		return a1.get_state() == "idle" \
				and int(console.get("_unread").get(a1.get_instance_id(), 0)) > 0
	var answered := await _wait_until(unread_pred, 8.0)
	_check(answered, "a reply to a closed chat raises the unread badge")
	var badge0: PanelContainer = rows[a0.get_instance_id()]["badge"]
	_check(not badge0.visible, "the open chat's soul carries no badge")
	console._collapse_chat()
	await process_frame
	await process_frame
	_check(not stage.visible, "back collapses the chat page")
	var badge1: PanelContainer = rows[a1.get_instance_id()]["badge"]
	_check(badge1.visible, "closed chat shows its unread badge in the lobby")

	# Re-open after a close: the page must re-show (close hides it).
	console._expand_chat(a1)
	await process_frame
	await process_frame
	var stage2: Control = console.get("_stage")
	_check(stage2.visible and console.get("expanded") == a1,
			"a second selection re-opens the chat page")
	console._collapse_chat()
	await process_frame
	await process_frame

	# The desktop page opens and closes; its tiles open souls.
	console._open_desktop()
	await process_frame
	_check((console.get("_desktop") as Control).visible, "the viewport desktop page opens")
	console._close_desktop()
	await create_timer(0.3).timeout
	_check(not (console.get("_desktop") as Control).visible, "back closes the desktop page")

	var wrapped: String = console._ssh_wrap("python x.py {prompt}", 0)
	_check(wrapped == 'ssh -o BatchMode=yes aaron@192.168.0.33 "python x.py {prompt}"',
			"ssh wrap builds a BatchMode remote command")
	var ssh_parts := AgentWorker._split_args(wrapped)
	_check(ssh_parts.size() == 5, "wrapped ssh command splits into 5 parts (remote stays one arg)")

	var doomed: AgentWorker = console._add_agent("doomed", "cmd.exe /c exit 7")
	console._select(doomed)
	console._entry.text = "rise"
	console._send()
	var dead := await _wait_until(func() -> bool: return doomed.get_state() == "dead", 10.0)
	_check(dead, "doomed soul dies on exit code 7")
	var st: Label = console.get("_status_label")
	_check(st.text.contains("1 DEAD"), "status line reports the dead soul")

	# Idle-only broadcast skips dead souls: no whisper, no auto-revive.
	console.set("_optimize_on", true)
	console.set("_broadcast_on", true)
	console._entry.text = "opt"
	console._send()
	await process_frame
	await process_frame
	var h2: Array = console.get("history")[doomed.get_instance_id()]
	var got_opt := false
	for ev in h2:
		if ev[0] == "you" and ev[1] == "opt":
			got_opt = true
	_check(not got_opt, "idle-only broadcast skips dead souls")
	_check(doomed.get_state() == "dead", "dead soul stays dead under idle-only broadcast")

	# Heal brings it back.
	console.set("_broadcast_on", false)
	console.set("_optimize_on", false)
	console._heal_all()
	await process_frame
	await process_frame
	_check(doomed.get_state() == "idle", "heal returns the doomed soul to idle")
	var healed_evt := false
	for ev in console.get("history")[doomed.get_instance_id()]:
		if ev[0] == "heal":
			healed_evt = true
	_check(healed_evt, "heal is recorded in the transcript")

	# A dead soul that receives a whisper auto-revives and re-runs (Repeat...).
	console._select(doomed)
	console._entry.text = "rise again"
	console._send()
	var dies2 := await _wait_until(func() -> bool: return doomed.get_state() == "dead", 10.0)
	_check(dies2, "soul dies again on a fresh whisper")
	console._entry.text = "once more"
	console._send()   # doomed is dead here: auto-revive must fire
	await process_frame
	await process_frame
	var auto_evt := false
	for ev in console.get("history")[doomed.get_instance_id()]:
		if ev[0] == "heal":
			auto_evt = true
	_check(auto_evt, "whispering a dead soul auto-revives it")
	var dead3 := await _wait_until(func() -> bool: return doomed.get_state() == "dead", 10.0)
	_check(dead3, "auto-revived soul re-runs its command")

	# Plain broadcast reaches everyone.
	console.set("_broadcast_on", true)
	console._entry.text = "hi all"
	console._send()
	await process_frame
	var agents2: Array = console.get("agents")
	for a in agents2:
		var reached := false
		for ev in console.get("history")[a.get_instance_id()]:
			if ev[0] == "you" and ev[1] == "hi all":
				reached = true
		_check(reached, "broadcast reached " + a.name_text)

	console.queue_free()
	await process_frame


func _finish() -> void:
	print("")
	if fails.is_empty():
		print("GATE GREEN - %d checks" % checks)
		quit(0)
	else:
		printerr("GATE RED - %d of %d failed: %s" % [fails.size(), checks, ", ".join(PackedStringArray(fails))])
		quit(1)
