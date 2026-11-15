extends SceneTree
## LIVE one-off (manual, NOT a gate suite — network + key):
##   NM_NVAPI_KEY=<key> GODOT --headless --path . --script res://tests/manual_nvidia_live.gd
## Drives an Ant soul against NVIDIA's OpenAI-compatible catalog endpoint with a
## real reasoning model, exercising the tool loop end to end.

const BASE_URL := "https://integrate.api.nvidia.com/v1"
const MODEL := "minimaxai/minimax-m3.1-flash"
const TASK := "Create a file called greeting.txt containing a short haiku about rain, then reply with the haiku text."

var _ant: Ant
var _res := {"done": "", "failed": "", "done_flag": false, "failed_flag": false}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var key := OS.get_environment("NM_NVAPI_KEY")
	if key.strip_edges() == "":
		print("NM_NVAPI_KEY not set — aborting")
		quit(2)
		return
	_ant = Ant.new(root)
	_ant.base_url = BASE_URL
	_ant.model = MODEL
	_ant.api_key = key.strip_edges()
	_ant.approve = func(_action: String) -> bool: return true
	_ant.done.connect(_on_done)
	_ant.failed.connect(_on_failed)
	_ant.activity.connect(func(t: String) -> void: print("  activity: " + t))
	print("asking NVIDIA %s (%s) — task: %s" % [MODEL, BASE_URL, TASK])
	_ant.ask(TASK)
	var t := 0.0
	while t < 240.0:
		if bool(_res["done_flag"]) or bool(_res["failed_flag"]):
			break
		await create_timer(2.0).timeout
		t += 2.0
		if int(t) % 20 == 0:
			print("  ...waiting (%ds, %d messages so far)" % [int(t), _ant._messages.size()])
	if bool(_res["done_flag"]):
		print("DONE: " + str(_res["done"]))
		var p := "user://workspace/greeting.txt"
		if FileAccess.file_exists(p):
			print("FILE greeting.txt: " + FileAccess.get_file_as_string(p))
			print("LIVE GREEN")
			quit(0)
		else:
			print("model replied but wrote no greeting.txt — see transcript above")
			quit(1)
	elif bool(_res["failed_flag"]):
		print("FAILED: " + str(_res["failed"]))
		print("fail_kind: " + _ant.fail_kind)
		_dump()
		quit(1)
	else:
		print("TIMEOUT after 240s — dumping transcript")
		_dump()
		quit(1)


func _dump() -> void:
	for m in _ant._messages:
		if typeof(m) == TYPE_DICTIONARY:
			print("MSG %s: %s" % [m.get("role"), str(m.get("content", "")).left(300)])


func _on_done(reply: String) -> void:
	_res["done"] = reply
	_res["done_flag"] = true


func _on_failed(message: String) -> void:
	_res["failed"] = message
	_res["failed_flag"] = true
