extends SceneTree
## GMP gate suite for the Ant API souls (M2). Run headless AFTER --import:
##   GODOT --headless --path . --script res://tests/test_ant.gd
## Exit 0 = green. Includes a deterministic in-process mock OpenAI server
## (loopback, port 0, ordered canned responses) so no network or GPU is needed.

var checks := 0
var fails: Array[String] = []

var _srv: TCPServer
var _srv_thread: Thread
var _srv_stop := false
var _port := 0
var _responses: Array = []      # ordered canned {status, body, delay_ms}
var _models_body := ""          # canned GET /models reply (routed separately from chat)
var _resp_lock := Mutex.new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_start_mock()

	await _test_native_tool_call()
	await _test_text_protocol_write()
	await _test_write_denied()
	await _test_edit_and_numbered_fallback()
	await _test_stall_ladder_forced_final()
	await _test_malformed_recovery()
	await _test_401_dead_and_revive()
	await _test_500_soft_error()
	await _test_cancel_midflight()
	await _test_run_python_desktop()
	await _test_sessions()
	await _test_console_integration()
	await _test_console_models()
	await _test_necro_limits()
	_test_run_python()

	_stop_mock()
	_finish()


# ---------------- mock server ----------------

func _start_mock() -> void:
	_srv = TCPServer.new()
	var err := _srv.listen(0, "127.0.0.1")
	if err != OK:
		printerr("mock server failed to listen: %d" % err)
		quit(1)
		return
	_port = _srv.get_local_port()
	_srv_thread = Thread.new()
	_srv_thread.start(_serve)


func _stop_mock() -> void:
	_srv_stop = true
	if _srv != null:
		_srv.stop()
	if _srv_thread != null:
		_srv_thread.wait_to_finish()   # join before quit — a dangling mock thread corrupts the exit code


func _base_url() -> String:
	return "http://127.0.0.1:%d/v1" % _port


func _load(resps: Array) -> void:
	_resp_lock.lock()
	_responses = resps
	_resp_lock.unlock()


func _load_models(body: String) -> void:
	_resp_lock.lock()
	_models_body = body
	_resp_lock.unlock()


func _serve() -> void:
	while not _srv_stop:
		if not _srv.is_connection_available():
			OS.delay_msec(5)
			continue
		_handle(_srv.take_connection())


func _handle(c: StreamPeerTCP) -> void:
	var buf := PackedByteArray()
	var header_end := -1
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var avail := c.get_available_bytes()
		if avail > 0:
			buf.append_array(c.get_data(avail)[1])
			if header_end < 0:
				header_end = _find_header_end(buf)
		if header_end >= 0:
			var clen := _content_length(buf, header_end)
			if buf.size() >= header_end + 4 + clen:
				break
		OS.delay_msec(2)
	var status := 200
	var body := "{}"
	var req_line := ""
	if header_end > 0:
		req_line = buf.slice(0, header_end).get_string_from_ascii().split("\r\n")[0]
	_resp_lock.lock()
	if _srv_stop:
		_resp_lock.unlock()
		c.disconnect_from_host()
		return
	if req_line.contains("/models") and _models_body != "":
		# path-routed: GET /models is served separately from the chat queue
		body = _models_body
		_resp_lock.unlock()
	elif not _responses.is_empty():
		var r: Dictionary = _responses.pop_front()
		status = int(r.get("status", 200))
		body = str(r.get("body", "{}"))
		var delay := int(r.get("delay_ms", 0))
		_resp_lock.unlock()
		if delay > 0:
			OS.delay_msec(delay)
	else:
		_resp_lock.unlock()
	var payload := body.to_utf8_buffer()
	var head := "HTTP/1.1 %d OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, payload.size()]
	c.put_data(head.to_ascii_buffer() + payload)
	c.disconnect_from_host()


func _find_header_end(buf: PackedByteArray) -> int:
	for i in range(0, maxi(0, buf.size() - 3)):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
	return -1


func _content_length(buf: PackedByteArray, header_end: int) -> int:
	if header_end <= 0:
		return 0
	var head := buf.slice(0, header_end).get_string_from_ascii()
	for line in head.split("\r\n"):
		var parts := line.split(":")
		if parts.size() == 2 and parts[0].strip_edges().to_lower() == "content-length":
			return int(parts[1].strip_edges())
	return 0


# ---------------- canned response builders ----------------

func _msg(content: String, tool_calls: Array = [], reasoning := "") -> String:
	var m := {"role": "assistant", "content": content}
	if reasoning != "":
		m["reasoning_content"] = reasoning
	if not tool_calls.is_empty():
		m["tool_calls"] = tool_calls
	return JSON.stringify({"choices": [{"message": m}]})


func _tc(id: String, name: String, args: Dictionary) -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": name, "arguments": JSON.stringify(args)}}


# ---------------- harness ----------------

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


func _new_ant(approve_all: bool) -> Ant:
	var a := Ant.new(root)
	a.base_url = _base_url()
	a.model = "mock-model"
	a.api_key = "test-key"
	if approve_all:
		a.approve = func(_action: String) -> bool: return true
	return a


func _results(ant: Ant) -> Dictionary:
	var res := {"done": "", "failed": "", "done_flag": false, "failed_flag": false,
			"cancelled_flag": false, "activities": []}
	ant.done.connect(_sig_done.bind(res))
	ant.failed.connect(_sig_failed.bind(res))
	ant.cancelled.connect(_sig_cancelled.bind(res))
	ant.activity.connect(_sig_activity.bind(res))
	return res


func _sig_done(reply: String, res: Dictionary) -> void:
	res["done"] = reply
	res["done_flag"] = true


func _sig_failed(message: String, res: Dictionary) -> void:
	res["failed"] = message
	res["failed_flag"] = true


func _sig_cancelled(res: Dictionary) -> void:
	res["cancelled_flag"] = true


func _sig_activity(text: String, res: Dictionary) -> void:
	(res["activities"] as Array).append(text)


func _drop(ant: Ant) -> void:
	if is_instance_valid(ant.http):
		ant.http.queue_free()


func _settled(res: Dictionary) -> bool:
	return bool(res["done_flag"]) or bool(res["failed_flag"]) or bool(res["cancelled_flag"])


func _messages_contain(ant: Ant, needle: String) -> bool:
	for m in ant._messages:
		if typeof(m) == TYPE_DICTIONARY and str(m.get("content", "")).contains(needle):
			return true
	return false


# ---------------- tests ----------------

func _test_native_tool_call() -> void:
	print("[ant native tool call]")
	_load([
		{"status": 200, "body": _msg("", [_tc("c1", "read_file", {"path": "notes.txt"})])},
		{"status": 200, "body": _msg("All done.")},
	])
	var ant := _new_ant(false)
	var res := _results(ant)
	ant.ask("check notes")
	var ok := await _wait_until(func() -> bool: return _settled(res), 10.0)
	_check(ok, "native tool-call turn settles")
	_check(str(res["done"]) == "All done.", "native tool-call loop reaches done")
	var saw_tool := false
	for m in ant._messages:
		if typeof(m) == TYPE_DICTIONARY and m.get("role") == "tool":
			saw_tool = true
	_check(saw_tool, "tool observation lands in the transcript")
	_check((res["activities"] as Array).size() >= 1, "activity emitted for the tool run")
	_drop(ant)


func _test_text_protocol_write() -> void:
	print("[ant text-protocol write]")
	var name := "haiku-%d.txt" % Time.get_ticks_usec()
	var call := "[ant_tool_call]" + JSON.stringify({"name": "write_file",
			"arguments": {"path": name, "content": "rain falls soft"}}) + "[/ant_tool_call]"
	_load([
		{"status": 200, "body": _msg(call)},
		{"status": 200, "body": _msg("Written up.")},
	])
	var ant := _new_ant(true)
	var res := _results(ant)
	ant.ask("write a haiku")
	var ok := await _wait_until(func() -> bool: return _settled(res), 10.0)
	_check(ok and str(res["done"]) == "Written up.", "text-protocol turn reaches done")
	_check(FileAccess.file_exists("user://workspace/" + name), "text-protocol write_file created the file")
	_check(FileAccess.get_file_as_string("user://workspace/" + name) == "rain falls soft",
			"text-protocol write_file content is exact")
	_drop(ant)


func _test_write_denied() -> void:
	print("[ant write denied]")
	var name := "denied-%d.txt" % Time.get_ticks_usec()
	var call := "[ant_tool_call]" + JSON.stringify({"name": "write_file",
			"arguments": {"path": name, "content": "nope"}}) + "[/ant_tool_call]"
	_load([
		{"status": 200, "body": _msg(call)},
		{"status": 200, "body": _msg("Understood, moving on.")},
	])
	var ant := _new_ant(false)   # no approve callable = deny every write
	var res := _results(ant)
	ant.ask("try to write")
	var ok := await _wait_until(func() -> bool: return _settled(res), 10.0)
	_check(ok, "denied write turn settles")
	_check(_messages_contain(ant, "DENIED by user"), "denied write is reported as an observation")
	_check(not FileAccess.file_exists("user://workspace/" + name), "denied write created no file")
	_drop(ant)


func _test_edit_and_numbered_fallback() -> void:
	print("[ant edit + numbered fallback]")
	var name := "edit-%d.txt" % Time.get_ticks_usec()
	var wf := FileAccess.open("user://workspace/" + name, FileAccess.WRITE)
	wf.store_string("alpha\nbeta\n")
	wf.close()
	var e1 := "[ant_tool_call]" + JSON.stringify({"name": "edit_file",
			"arguments": {"path": name, "old": "beta", "new": "gamma"}}) + "[/ant_tool_call]"
	var e2 := "[ant_tool_call]" + JSON.stringify({"name": "edit_file",
			"arguments": {"path": name, "old": "     1\talpha\n     2\tgamma", "new": "     1\talpha\n     2\tdelta"}}) + "[/ant_tool_call]"
	_load([
		{"status": 200, "body": _msg(e1)},
		{"status": 200, "body": _msg(e2)},
		{"status": 200, "body": _msg("Edits complete.")},
	])
	var ant := _new_ant(true)
	var res := _results(ant)
	ant.ask("edit the file")
	var ok := await _wait_until(func() -> bool: return _settled(res), 10.0)
	_check(ok, "edit turn settles")
	_check(FileAccess.get_file_as_string("user://workspace/" + name) == "alpha\ndelta\n",
			"plain and numbered-line edits both applied")
	_drop(ant)


func _test_stall_ladder_forced_final() -> void:
	print("[ant stall ladder -> forced final]")
	var stall := {"status": 200, "body": _msg("", [], "thinking through the problem...")}
	_load([stall, stall.duplicate(), stall.duplicate(),
		{"status": 200, "body": _msg("", [_tc("cf", "final_answer", {"answer": "checkpoint done"})])},
	])
	var ant := _new_ant(true)
	var res := _results(ant)
	ant.ask("long task")
	var ok := await _wait_until(func() -> bool: return _settled(res), 15.0)
	_check(ok, "stall ladder settles")
	_check(str(res["done"]) == "checkpoint done", "forced final_answer delivers the checkpoint")
	_check(_messages_contain(ant, "[Runtime note:"), "nudges applied as runtime notes")
	_drop(ant)


func _test_malformed_recovery() -> void:
	print("[ant malformed recovery]")
	var bad_call := {"id": "c1", "type": "function",
			"function": {"name": "read_file", "arguments": "not-json"}}
	_load([
		{"status": 200, "body": _msg("", [bad_call])},
		{"status": 200, "body": _msg("Recovered.")},
	])
	var ant := _new_ant(false)
	var res := _results(ant)
	ant.ask("try again")
	var ok := await _wait_until(func() -> bool: return _settled(res), 10.0)
	_check(ok and str(res["done"]) == "Recovered.", "malformed tool call recovers via nudge")
	_check(_messages_contain(ant, "[Runtime note:"), "malformed nudge applied")
	_drop(ant)


func _test_401_dead_and_revive() -> void:
	print("[ant 401 dead and revive]")
	_load([{"status": 401, "body": '{"error": "bad key"}'}])
	var soul := AntSoul.new("soul-401", _base_url(), "mock", "wrong-key", root)
	soul.submit("hi")
	var evs: Array = []   # shared array — lambdas capture locals by value, mutate in place
	var dead := await _wait_until(func() -> bool:
		evs.append_array(soul.drain_events())
		return soul.get_state() == "dead" and evs.size() > 0, 10.0)
	_check(dead, "401 marks the API soul dead")
	var saw_dead := false
	for ev in evs:
		if ev[0] == "dead":
			saw_dead = true
	_check(saw_dead, "dead event carries the failure")
	soul.revive()
	_check(soul.get_state() == "idle", "revive restores the API soul to idle")
	soul.shutdown()
	await process_frame


func _test_500_soft_error() -> void:
	print("[ant 500 soft error]")
	_load([{"status": 500, "body": '{"error": "boom"}'}])
	var soul := AntSoul.new("soul-500", _base_url(), "mock", "k", root)
	soul.submit("hi")
	var evs: Array = []
	await _wait_until(func() -> bool:
		evs.append_array(soul.drain_events())
		return evs.size() > 0 and soul.get_state() == "idle", 10.0)
	var saw_err := false
	var saw_dead := false
	for ev in evs:
		if ev[0] == "error":
			saw_err = true
		if ev[0] == "dead":
			saw_dead = true
	_check(saw_err and not saw_dead, "5xx is an error event, not death")
	_check(soul.get_state() == "idle", "soul returns to idle after a soft failure")
	soul.shutdown()
	await process_frame


func _test_cancel_midflight() -> void:
	print("[ant cancel midflight]")
	_load([{"status": 200, "delay_ms": 1500, "body": _msg("late")}])
	var soul := AntSoul.new("soul-cancel", _base_url(), "mock", "k", root)
	soul.submit("slow task")
	soul.submit("queued task")
	await create_timer(0.4).timeout
	soul.cancel()
	var evs: Array = []
	var settled_idle := await _wait_until(func() -> bool:
		evs.append_array(soul.drain_events())
		var cancelled := false
		for ev in evs:
			if ev[0] == "system" and str(ev[1]) == "cancelled":
				cancelled = true
		return cancelled and soul.get_state() == "idle" and soul.queued() == 0, 8.0)
	_check(settled_idle, "cancelled turn settles to idle with the queue cleared")
	_check(soul.get_state() != "dead", "cancellation is not death")
	soul.shutdown()
	await process_frame


func _test_run_python_desktop() -> void:
	print("[ant run_python on desktop]")
	_load([
		{"status": 200, "body": _msg("", [_tc("cp", "run_python", {"code": "print('py-ok')"})])},
		{"status": 200, "body": _msg("Done.")},
	])
	var ant := _new_ant(false)
	var res := _results(ant)
	ant.ask("run some python")
	var ok := await _wait_until(func() -> bool: return _settled(res), 10.0)
	_check(ok and str(res["done"]) == "Done.", "run_python turn settles on desktop")
	_check(_messages_contain(ant, "py-ok"), "desktop run_python executes via system python")
	_drop(ant)


func _test_sessions() -> void:
	print("[ant sessions]")
	_load([
		{"status": 200, "body": _msg("", [_tc("c1", "list_dir", {})])},
		{"status": 200, "body": _msg("First turn done.")},
	])
	var ant := _new_ant(false)
	var res := _results(ant)
	ant.ask("list the workspace")
	await _wait_until(func() -> bool: return _settled(res), 10.0)
	var sid := ant.session_id
	_check(FileAccess.file_exists("user://ant/sessions/%s.json" % sid), "session saved to user://ant/sessions/")
	var ant2 := _new_ant(false)
	_check(ant2.load_session(sid), "load_session restores the saved session")
	_check(ant2._messages.size() >= 4, "restored session carries the message history")
	_load([{"status": 200, "body": _msg("Session continued.")}])
	var res2 := _results(ant2)
	ant2.ask("continue")
	var ok := await _wait_until(func() -> bool: return _settled(res2), 10.0)
	_check(ok and str(res2["done"]) == "Session continued.", "restored session continues the turn loop")

	# restore-by-name: the console path (latest_session_for + saved_transcript)
	ant.soul_name = "ant-restore-check"
	ant._save()
	var found := ant.latest_session_for("ant-restore-check")
	_check(found == ant.session_id, "latest_session_for finds the session by soul name")
	_check(ant.latest_session_for("no-such-soul") == "", "latest_session_for misses unknown souls")
	var ant3 := _new_ant(false)
	var sid3 := ant3.latest_session_for("ant-restore-check")
	_check(ant3.load_session(sid3), "restore-by-name loads the saved session")
	var st := ant3.saved_transcript()
	_check(st.size() >= 2, "saved_transcript replays user and assistant lines")
	_check(str(st[0][0]) == "you" and str(st[0][1]) == "list the workspace", "first replayed line is the user whisper")
	_check(str(st[st.size() - 1][0]) == "output", "last replayed line is an assistant reply")
	_drop(ant3)
	_drop(ant)
	_drop(ant2)


func _test_console_integration() -> void:
	print("[console API soul integration]")
	_load([{"status": 200, "body": _msg("Ant replies to the console.")}])
	var scene: PackedScene = load("res://main.tscn")
	_check(scene != null, "main.tscn loads")
	var console = scene.instantiate()
	root.add_child(console)
	await process_frame
	await process_frame
	var soul: Soul = console._add_ant_soul("ant-console", _base_url(), "mock", "")
	_check(soul != null and soul.get_state() == "idle", "API soul summoned into the pool")
	_check(soul.ant_ref().necro.is_valid(), "console wired into the ant tool loop")
	_check(soul.depth == 1, "API-summoned ant is depth 1")
	console._entry.text = "say hi"
	console._send()
	# The mock answers in milliseconds — poll the transcript, not the busy window.
	var answered := await _wait_until(func() -> bool:
		var hh: Array = console.get("history")[soul.get_instance_id()]
		for ev in hh:
			if ev[0] == "output":
				return true
		return false, 10.0)
	_check(answered, "whisper reaches the API soul and its answer is recorded")
	var idle := await _wait_until(func() -> bool: return soul.get_state() == "idle", 15.0)
	_check(idle, "API soul settles back to idle")
	var h: Array = console.get("history")[soul.get_instance_id()]
	var got := false
	for ev in h:
		if ev[0] == "output" and str(ev[1]) == "Ant replies to the console.":
			got = true
	_check(got, "Ant answer recorded in the console transcript")
	console.queue_free()
	await process_frame


func _test_console_models() -> void:
	print("[console model browser]")
	_load_models(JSON.stringify({"data": [
		{"id": "mock-a"}, {"id": "Mock-B"}, {"id": "mock-c"},
	]}))
	var scene: PackedScene = load("res://main.tscn")
	var console = scene.instantiate()
	root.add_child(console)
	await process_frame
	await process_frame
	console._url_edit.text = _base_url()
	console._key_edit.text = "k"
	console._on_fetch_models()
	var filled := await _wait_until(func() -> bool:
		return console.get("_models_all").size() == 3, 10.0)
	_check(filled, "models fetch fills the list from the endpoint")
	_check(console.get("_models_list").item_count == 3, "all models listed")
	console._model_search.text = "mock-b"
	console._on_model_search_changed("mock-b")
	_check(console.get("_models_list").item_count == 1, "search box filters models")
	console._on_model_selected(0)
	_check(console.get("_model_edit").text == "Mock-B", "clicking a model fills the model field")
	console.queue_free()
	await process_frame


func _test_necro_limits() -> void:
	print("[necro recursion law]")
	# No network: agent souls only spawn here, never whispered.
	var scene: PackedScene = load("res://main.tscn")
	var console = scene.instantiate()
	root.add_child(console)
	await process_frame
	await process_frame
	var orig: Soul = console._add_ant_soul("orch", _base_url(), "mock", "")
	_check(orig.depth == 1, "owner-summoned ant is depth 1")
	_check(orig.ant_ref().necro.is_valid(), "console wired into the ant tool loop")

	var mid_ok := true
	for i in 3:
		var r: Dictionary = console.api_necro_for(orig, {"op": "spawn", "type": "agent",
				"name": "mid-%d" % i, "url": _base_url(), "model": "mock"})
		if not bool(r.get("ok", false)):
			mid_ok = false
	_check(mid_ok and orig.children == 3, "depth-1 ant summons 3 mid ants")
	var mid1: Soul = console._soul_by_name("mid-0")
	_check(mid1 != null and mid1.depth == 2, "mid ants are depth 2")
	var denied_budget: Dictionary = console.api_necro_for(orig, {"op": "spawn", "type": "agent",
			"name": "mid-4", "url": _base_url(), "model": "mock"})
	_check(str(denied_budget.get("error", "")).contains("budget"), "4th summon hits the 3-ant budget")

	var leaf_ok := true
	for i in 3:
		var r2: Dictionary = console.api_necro_for(mid1, {"op": "spawn", "type": "agent",
				"name": "leaf-%d" % i, "url": _base_url(), "model": "mock"})
		if not bool(r2.get("ok", false)):
			leaf_ok = false
	_check(leaf_ok and mid1.children == 3, "depth-2 ant summons 3 leaf ants")
	var leaf: Soul = console._soul_by_name("leaf-0")
	_check(leaf != null and leaf.depth == 3, "leaf ants are depth 3")
	var rec: Dictionary = console.api_necro_for(leaf, {"op": "spawn", "type": "agent",
			"name": "sub-leaf", "url": _base_url(), "model": "mock"})
	_check(str(rec.get("error", "")).contains("recursion"), "depth-3 leaf cannot summon")

	var lone := Ant.new(root)
	_check(not lone.necro.is_valid(), "unwired ant has no console control")
	_check(str(lone._console_tool({"op": "list"})).contains("not wired"),
			"unwired console tool says so")
	lone.http.queue_free()

	console.queue_free()
	await process_frame


func _test_run_python() -> void:
	print("[ant run_python desktop]")
	var ant := Ant.new(root)
	var out: String = ant._run_python({"code": "print('py-ok')"})
	_check(str(out).contains("py-ok"), "desktop run_python executes via system python")
	var err_out: String = ant._run_python({"code": "raise ValueError('boom')"})
	_check(str(err_out).contains("ERR") or str(err_out).contains("ValueError"),
			"python errors surface in the tool output")


func _finish() -> void:
	print("")
	if fails.is_empty():
		print("GATE GREEN - %d checks" % checks)
		quit(0)
	else:
		printerr("GATE RED - %d of %d failed: %s" % [fails.size(), checks, ", ".join(PackedStringArray(fails))])
		quit(1)
