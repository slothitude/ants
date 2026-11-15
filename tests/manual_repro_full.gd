extends SceneTree
## Full-sequence repro on the REAL console: spawn an NVIDIA ant through the
## loopback API, whisper an orchestration task, poll the transcript.
## Requires NM_NVAPI_KEY in the environment.

const TASK := "Use your console tool: 1) op=spawn a cli soul named worker with command: python -c \"print('worker alive')\"  2) op=whisper name=worker text=run  3) op=transcript name=worker  4) report what happened. Then reply."

var _console
var _port := 8720
var _seen := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var key: String = OS.get_environment("NM_NVAPI_KEY").strip_edges()
	if key == "":
		print("NM_NVAPI_KEY not set")
		quit(2)
		return
	var console = load("res://main.tscn").instantiate()
	root.add_child(console)
	await process_frame
	await process_frame
	var api = console.get("_api")
	_port = api.port
	print("[repro] api port=", _port)

	var r := await _req("POST", "/spawn", {
		"name": "nvidia-ant", "type": "agent",
		"url": "https://integrate.api.nvidia.com/v1",
		"model": "minimaxai/minimax-m3.1-flash", "key": key,
	})
	print("[repro] spawn: ", JSON.stringify(r))
	if not bool(r.get("ok", false)):
		quit(1)
		return

	var w := await _req("POST", "/whisper", {"target": "nvidia-ant", "text": TASK})
	print("[repro] whisper: ", JSON.stringify(w))

	var ant: Soul = console._soul_by_name("nvidia-ant")
	var t := 0.0
	var last_len := -1
	while t < 240.0:
		await create_timer(3.0).timeout
		t += 3.0
		var st: String = ant.get_state()
		var h: Array = console.get("history")[ant.get_instance_id()]
		print("[repro] t=%d state=%s transcript_len=%d" % [int(t), st, h.size()])
		if st == "idle" or st == "dead":
			break
	print("[repro] final state=", ant.get_state())
	print("[repro] transcript:")
	for e in console.get("history")[ant.get_instance_id()]:
		print("  [", e[0], "] ", str(e[1]).left(200).replace("\n", " | "))
	print("[repro] SURVIVED - process alive after full turn")
	console.queue_free()
	await process_frame
	quit(0)


func _req(method: String, path: String, body: Dictionary) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 30.0
	root.add_child(req)
	var headers := PackedStringArray(["Content-Type: application/json"])
	var data := ""
	if not body.is_empty():
		data = JSON.stringify(body)
	var use_post := method == "POST"
	var err := req.request("http://127.0.0.1:%d%s" % [_port, path], headers,
			HTTPClient.METHOD_POST if use_post else HTTPClient.METHOD_GET,
			data if use_post else "")
	if err != OK:
		req.queue_free()
		return {"ok": false, "error": "request failed to start"}
	var res: Array = await req.request_completed
	req.queue_free()
	var json = JSON.parse_string(res[3].get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY:
		json = {}
	json["__status"] = int(res[1])
	return json
