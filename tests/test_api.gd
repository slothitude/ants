extends SceneTree
## GMP gate suite for the loopback HTTP API (M3). Headless:
##   GODOT --headless --path . --script res://tests/test_api.gd
## Boots the REAL console scene (ApiServer picks a fallback port when the GUI
## holds 8720) and drives it over HTTP like an external agent would.

var checks := 0
var fails: Array[String] = []
var _port := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var scene: PackedScene = load("res://main.tscn")
	_check(scene != null, "main.tscn loads")
	var console = scene.instantiate()
	root.add_child(console)
	await process_frame
	await process_frame
	var api = console.get("_api")
	_check(api != null, "ApiServer started with the console")
	if api == null or api.port == 0:
		printerr("API server failed to bind — aborting")
		quit(1)
		return
	_port = api.port
	print("[api] port %d" % _port)

	var up := false
	var t := 0.0
	while t < 5.0:
		var h0 := await _req("GET", "/health")
		if int(h0.get("__status", 0)) == 200:
			up = true
			break
		await create_timer(0.2).timeout
		t += 0.2
	_check(up, "health endpoint comes up")

	var h := await _req("GET", "/health")
	_check(int(h.get("__json", {}).get("souls", 0)) == 3, "health reports the 3 seeded souls")
	var s := await _req("GET", "/souls")
	_check(s.get("__json", {}).get("souls", []).size() == 3, "souls list shows the pool")

	var sp := await _req("POST", "/spawn", {"name": "api-echo", "type": "cli", "command": ""})
	_check(bool(sp.get("__json", {}).get("ok", false)), "spawn creates a cli soul via API")
	var s2 := await _req("GET", "/souls")
	_check(s2.get("__json", {}).get("souls", []).size() == 4, "pool grows to 4")

	var w := await _req("POST", "/whisper", {"target": "api-echo", "text": "api-hello"})
	_check(bool(w.get("__json", {}).get("ok", false)), "whisper accepted via API")
	var saw := false
	t = 0.0
	while t < 8.0:
		var tr := await _req("GET", "/transcript/api-echo")
		for ev in tr.get("__json", {}).get("events", []):
			if ev[0] == "output" and str(ev[1]).contains("echo: api-hello"):
				saw = true
		if saw:
			break
		await create_timer(0.3).timeout
		t += 0.3
	_check(saw, "answer recorded in the API transcript")

	var doomed := await _req("POST", "/spawn", {"name": "api-doomed", "type": "cli",
			"command": "cmd.exe /c exit 7"})
	_check(bool(doomed.get("__json", {}).get("ok", false)), "doomed soul spawned via API")
	await _req("POST", "/whisper", {"target": "api-doomed", "text": "rise"})
	var dead := false
	t = 0.0
	while t < 10.0:
		var sl := await _req("GET", "/souls")
		for entry in sl.get("__json", {}).get("souls", []):
			if entry.get("name") == "api-doomed" and entry.get("state") == "dead":
				dead = true
		if dead:
			break
		await create_timer(0.3).timeout
		t += 0.3
	_check(dead, "API soul dies on non-zero exit")
	var heal := await _req("POST", "/heal", {"name": "api-doomed"})
	_check(bool(heal.get("__json", {}).get("ok", false)), "heal via API")

	var reap := await _req("POST", "/reap", {"name": "api-doomed"})
	_check(bool(reap.get("__json", {}).get("ok", false)), "reap via API")
	var s3 := await _req("GET", "/souls")
	_check(s3.get("__json", {}).get("souls", []).size() == 4, "pool shrinks after reap")

	# signal bus: baseline + incremental reads
	var ev := await _req("GET", "/events")
	var evj: Dictionary = ev.get("__json", {})
	var ev_next := int(evj.get("next", 0))
	_check(ev_next > 0, "signal bus is sequenced")
	var ev2 := await _req("GET", "/events?since=%d" % ev_next)
	_check(ev2.get("__json", {}).get("events", []).is_empty(), "since-marker is incremental (quiet now)")

	# mcp adder: register a stdio server, list tools, call one, remove
	var addm := await _req("POST", "/mcp/add", {"name": "mock",
			"command": "python C:/Users/aaron/nm_agent/tests/mock_mcp.py"})
	_check(bool(addm.get("__json", {}).get("ok", false)), "mcp adder registers a stdio server")
	_check(addm.get("__json", {}).get("tools", []).has("mock_echo"), "mcp adder lists the server's tools")
	var callm := await _req("POST", "/mcp/call", {"server": "mock", "tool": "mock_echo",
			"arguments": {"text": "ping"}})
	_check(str(callm.get("__json", {}).get("content", "")).contains("mock says: ping"),
			"mcp call routes through the console")
	var ev3 := await _req("GET", "/events?since=%d" % ev_next)
	var kinds := {}
	for e in ev3.get("__json", {}).get("events", []):
		kinds[str(e.get("kind"))] = true
	_check(kinds.has("mcp_add") and kinds.has("mcp_call"), "mcp events flow through the signal bus")
	var rm := await _req("POST", "/mcp/remove", {"name": "mock"})
	_check(bool(rm.get("__json", {}).get("ok", false)), "mcp remove kills and unregisters")

	var nf := await _req("GET", "/nope")
	_check(int(nf.get("__status", 0)) == 404, "unknown route is a 404")

	console.queue_free()
	await process_frame
	_finish()


func _check(cond: bool, what: String) -> void:
	checks += 1
	if cond:
		print("  ok   " + what)
	else:
		fails.append(what)
		printerr("  FAIL " + what)


func _req(method: String, path: String, body: Dictionary = {}) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 10.0
	root.add_child(req)
	var headers := PackedStringArray(["Content-Type: application/json"])
	var use_post := method == "POST"
	var data := ""
	if not body.is_empty():
		data = JSON.stringify(body)
	var err := req.request("http://127.0.0.1:%d%s" % [_port, path], headers,
			HTTPClient.METHOD_POST if use_post else HTTPClient.METHOD_GET,
			data if use_post else "")
	if err != OK:
		req.queue_free()
		return {"__status": 0, "__json": {}}
	var res: Array = await req.request_completed
	req.queue_free()
	var json = JSON.parse_string(res[3].get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY:
		json = {}
	return {"__status": int(res[1]), "__json": json}


func _finish() -> void:
	print("")
	if fails.is_empty():
		print("GATE GREEN - %d checks" % checks)
		quit(0)
	else:
		printerr("GATE RED - %d of %d failed: %s" % [fails.size(), checks, ", ".join(PackedStringArray(fails))])
		quit(1)
