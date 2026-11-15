class_name Ant
extends RefCounted
## Port of Sentdex/minion minion.py (MIT, https://github.com/Sentdex/minion),
## renamed Ant. OpenAI-compatible tool-loop coding agent, sandboxed to user://.

signal done(reply: String)
signal failed(message: String)
signal cancelled
signal activity(text: String)

const MAX_MODEL_TURNS := 200
const TOOL_RESULT_CHARS := 20000
const READ_FILE_LINES := 400
const EMPTY_TURN_RETRY_LIMIT := 3
const MALFORMED_RETRY_LIMIT := 2
const STALL_RETRY_LIMIT := 3
const REASONING_CAPTURE_CHARS := 8000
const FORCED_FINAL_MAX_TOKENS := 2048
# Every turn caps output explicitly: scullm-q4 opens with a ~1000-token
# reasoning preamble — without a generous cap the real answer gets truncated.
const DEFAULT_MAX_TOKENS := 2048
const WORKSPACE := "user://workspace/"
const SESSION_DIR := "user://ant/sessions/"

const SYSTEM := """You are a coding agent working in the user's project folder.
Use the provided tools to inspect and modify files. Take one concrete step at a time.
You also have a `run_python` tool: it executes Python source on this device and returns its stdout — prefer it for any computation, file manipulation or quick script; do NOT look for a shell.
If present, `run_local` runs a prompt through the on-device llama.cpp model (offline, private) and returns the completion plus timing.
If your runtime does NOT support native tool calls, emit a standalone call exactly like:
[ant_tool_call]{"name": "read_file", "arguments": {"path": "foo.gd"}}[/ant_tool_call]
Emit nothing before or after a tool call; wait for the Observation. When the task is done, reply in plain prose."""

const NUDGE_STALL := "You produced reasoning only. Stop planning. Act now: call a tool, or write the deliverable file."
const NUDGE_FINAL := "Do not continue private reasoning. Call final_answer now with a complete visible answer. If blocked, say what is blocking you."
const NUDGE_EMPTY := "Your previous response was empty. If the task is not finished, emit the next tool call now. Otherwise give a concise visible answer."
const NUDGE_LIMIT := "Turn limit reached. Give a visible checkpoint now using final_answer."

const BASE_TOOLS: Array = [
	{
		"type": "function",
		"function": {
			"name": "read_file",
			"description": "Read a file as numbered lines. Large files: pass offset (1-based) and limit to page.",
			"parameters": {
				"type": "object",
				"properties": {
					"path": {"type": "string"},
					"offset": {"type": "integer"},
					"limit": {"type": "integer"},
				},
				"required": ["path"],
			},
		},
	},
	{
		"type": "function",
		"function": {
			"name": "write_file",
			"description": "Write (overwrite) a file.",
			"parameters": {
				"type": "object",
				"properties": {
					"path": {"type": "string"},
					"content": {"type": "string"},
				},
				"required": ["path", "content"],
			},
		},
	},
	{
		"type": "function",
		"function": {
			"name": "edit_file",
			"description": "Replace one exact occurrence of old with new.",
			"parameters": {
				"type": "object",
				"properties": {
					"path": {"type": "string"},
					"old": {"type": "string"},
					"new": {"type": "string"},
				},
				"required": ["path", "old", "new"],
			},
		},
	},
	{
		"type": "function",
		"function": {
			"name": "list_dir",
			"description": "List a directory.",
			"parameters": {
				"type": "object",
				"properties": {
					"path": {"type": "string"},
				},
			},
		},
	},
]

const FINAL_ANSWER := {
	"type": "function",
	"function": {
		"name": "final_answer",
		"description": "Return a complete, concise visible answer to the user.",
		"parameters": {
			"type": "object",
			"properties": {
				"answer": {"type": "string"},
			},
			"required": ["answer"],
		},
	},
}

const RUN_PYTHON_TOOL := {"type": "function", "function": {"name": "run_python", "description": "Run short Python code and return its stdout. Only available in Android builds.", "parameters": {"type": "object", "properties": {"code": {"type": "string"}}, "required": ["code"]}}}

const RUN_LOCAL_TOOL := {"type": "function", "function": {"name": "run_local", "description": "Run a prompt through the on-device llama.cpp model (offline, private) and return its completion. Args: prompt (required), max_tokens (default 128), temp (default 0 = greedy). Only when the LlamaBridge plugin and a loaded model are available.", "parameters": {"type": "object", "properties": {"prompt": {"type": "string"}, "max_tokens": {"type": "integer"}, "temp": {"type": "number"}}, "required": ["prompt"]}}}

const NECRO_TOOL := {"type": "function", "function": {"name": "console", "description": "Control the NecroMancer console and its soul pool: op=list (no args) lists every soul; op=whisper with name+text messages another soul (read the reply with op=transcript and name); op=broadcast with text messages all; op=spawn with name+type (cli|ssh|agent) plus command or url/model summons a new soul; op=heal / op=stop / op=reap with name revive, halt or banish. op=sense (optional kind) reads task stimuli from the pheromone field; op=claim with id claims one — the stimulus payload becomes your task. LIMITS: an ant may summon up to 3 ants, up to depth 3 — the tree totals 9 summoned ants + 1 original, and depth-3 leaves cannot summon.", "parameters": {"type": "object", "properties": {"op": {"type": "string", "enum": ["list", "whisper", "broadcast", "spawn", "transcript", "heal", "stop", "reap", "sense", "claim"]}, "name": {"type": "string"}, "text": {"type": "string"}, "type": {"type": "string"}, "command": {"type": "string"}, "url": {"type": "string"}, "model": {"type": "string"}, "kind": {"type": "string"}, "id": {"type": "integer"}}, "required": ["op"]}}}

const NECRO_NOTE := "\n\nYou also hold the `console` tool and may command the whole soul pool: op=list shows every soul and its state; op=whisper with name+text sends a message to another soul (read its reply with op=transcript and name); op=spawn with name+type (cli|ssh|agent) plus command or url/model summons new workers; op=heal, op=stop and op=reap with a name revive, halt or banish a soul. You may summon up to 3 ants, up to depth 3 — the full tree is 1 original + 3 mid ants + 9 leaf ants (3 each) — and depth-3 leaf ants cannot summon further ants. You may also op=sense the pheromone field for task stimuli and op=claim with id to take one as your task. Use it when the task needs more than one worker."

var base_url := "http://localhost:8080/v1"
var model := ""
var api_key := "sk-noop"
var approve: Callable = Callable()
var session_id := ""
var soul_name := ""   # console soul name; saved into the session for restore
var http: HTTPRequest = null
var necro: Callable = Callable()   # console control, wired by the host app; valid = console tool exists
var necro_depth := 1               # this soul's orchestration depth (2 = may not summon ants)
var _messages: Array = []
var _tools: Dictionary = {}
var _tools_schema: Array = []
var _steps := 0
var _empty := 0
var _malformed := 0
var _stalls := 0
var _forced := false
var _cancelled := false
var _in_flight := false
var _settled_once := false     # one settling signal per turn, even on cancel
var fail_kind := "soft"
var _line_num: RegEx = RegEx.create_from_string("^ *\\d+\\t")
var _text_mini: RegEx = RegEx.create_from_string("^\\[ant_tool_call\\]\\s*(\\{.*?\\})\\s*\\[/ant_tool_call\\]")
var _text_legacy: RegEx = RegEx.create_from_string("^<tool_call>\\s*(\\{.*?\\})\\s*</tool_call>")


func _init(host: Node) -> void:
	http = HTTPRequest.new()
	http.timeout = 180.0
	host.add_child(http)
	http.request_completed.connect(_on_response)
	_tools = {
		"read_file": _read_file,
		"write_file": _write_file,
		"edit_file": _edit_file,
		"list_dir": _list_dir,
		"run_python": _run_python,
		"run_local": _run_local,
		"console": _console_tool,
	}
	_tools_schema = BASE_TOOLS.duplicate(true)
	_tools_schema.append(RUN_PYTHON_TOOL)
	_tools_schema.append(RUN_LOCAL_TOOL)
	_tools_schema.append(NECRO_TOOL)
	DirAccess.make_dir_recursive_absolute(WORKSPACE)
	session_id = Time.get_datetime_string_from_system().replace(":", "-") + "-%06x" % (randi() % 16777216)


func ask(prompt: String) -> void:
	_cancelled = false
	_in_flight = false
	_settled_once = false
	if _messages.is_empty():
		var sys := SYSTEM
		if necro.is_valid():
			sys += NECRO_NOTE
			if necro_depth >= 3:
				sys += "\nRecursion limit: you are a depth-3 leaf ant and may not summon further ants."
		_messages.append({"role": "system", "content": sys})
	_messages.append({"role": "user", "content": prompt})
	_steps = 0
	_empty = 0
	_malformed = 0
	_stalls = 0
	_request(false)


func load_session(id: String) -> bool:
	var path := SESSION_DIR + id + ".json"
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var msgs = data.get("messages", [])
	if typeof(msgs) != TYPE_ARRAY:
		return false
	session_id = str(data.get("id", id))
	model = str(data.get("model", model))
	_messages = msgs
	return true


## Newest saved session belonging to this soul name ("" when none). Session
## ids are ISO-timestamp+hex, so lexicographic order is chronological.
func latest_session_for(soul: String) -> String:
	var best := ""
	var d := DirAccess.open(SESSION_DIR)
	if d == null:
		return ""
	for f in d.get_files():
		if not f.ends_with(".json"):
			continue
		var fa := FileAccess.open(SESSION_DIR + f, FileAccess.READ)
		if fa == null:
			continue
		var data = JSON.parse_string(fa.get_as_text())
		fa.close()
		if typeof(data) != TYPE_DICTIONARY or str(data.get("name", "")) != soul:
			continue
		var id := str(data.get("id", ""))
		if id > best:
			best = id
	return best


## Display-side history: user whispers and assistant text replies, in order.
## System preambles, tool-call turns and tool results are skipped.
func saved_transcript() -> Array:
	var out: Array = []
	for m in _messages:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var role := str(m.get("role", ""))
		var content = m.get("content", "")
		if typeof(content) != TYPE_STRING or content.strip_edges() == "":
			continue
		if role == "user":
			out.append(["you", content])
		elif role == "assistant":
			out.append(["output", content])
	return out


func cancel() -> void:
	_cancelled = true
	if _in_flight:
		http.cancel_request()
	_emit_cancelled()


## Wire console control (host app hands in a synchronous callable). Once set,
## the `console` tool works and the system prompt advertises it.
func set_necro(cb: Callable) -> void:
	necro = cb


func _console_tool(a: Dictionary) -> String:
	if not necro.is_valid():
		return "ERROR: console control not wired for this soul"
	return str(necro.call(a))


## Godot's cancel_request() emits no completion signal, so a cancelled turn
## must emit its own settle — exactly once per turn (cancel may be called
## repeatedly, and _on_response may never fire after a cancel).
func _emit_cancelled() -> void:
	if not _settled_once:
		_settled_once = true
		cancelled.emit()


func _request(force_final: bool) -> void:
	if _cancelled:
		_emit_cancelled()
		return
	var body := {
		"model": model,
		"messages": _messages,
		"tools": _tools_schema,
		"tool_choice": "auto",
		"stream": false,
		"max_tokens": DEFAULT_MAX_TOKENS,
	}
	if force_final:
		body["tool_choice"] = {"type": "function", "function": {"name": "final_answer"}}
		body["max_tokens"] = FORCED_FINAL_MAX_TOKENS
	var headers := PackedStringArray(["Content-Type: application/json", "Authorization: Bearer " + api_key])
	var err := http.request(base_url + "/chat/completions", headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_fail("request failed to start (%d)" % err, "dead")
		return
	_in_flight = true
	_forced = force_final


func _on_response(result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
	_in_flight = false
	if _cancelled:
		_emit_cancelled()
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("transport error (result %d)" % result, "dead")
		return
	var data = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		_fail("malformed server reply")
		return
	if code == 401 or code == 403:
		_fail("HTTP %d — endpoint refused access" % code, "dead")
		return
	if code != 200:
		_fail("HTTP %d" % code)
		return
	var choices = data.get("choices", [])
	if typeof(choices) != TYPE_ARRAY or choices.is_empty():
		_fail("malformed server reply")
		return
	var choice = choices[0]
	var msg = choice.get("message", {}) if typeof(choice) == TYPE_DICTIONARY else {}
	var content = msg.get("content")
	var tcs = msg.get("tool_calls", [])
	if typeof(tcs) != TYPE_ARRAY:
		tcs = []
	var reasoning := _s(msg.get("reasoning_content", ""))
	if _forced:
		_finish_forced(tcs, _s(content))
	elif not tcs.is_empty():
		_on_native_calls(content, tcs)
	elif not _parse_text_calls(_s(content)).is_empty():
		_on_text_calls(_s(content))
	elif _s(content).strip_edges() == "":
		_on_silent(reasoning)
	else:
		_done(_s(content))


func _on_native_calls(content, tcs: Array) -> void:
	var parsed: Array = []
	for tc in tcs:
		var fn = tc.get("function", {}) if typeof(tc) == TYPE_DICTIONARY else {}
		var args = JSON.parse_string(_s(fn.get("arguments")))
		if typeof(args) != TYPE_DICTIONARY:
			if _malformed >= MALFORMED_RETRY_LIMIT:
				_fail("malformed tool call after %d recoveries" % _malformed)
				return
			_malformed += 1
			_nudge("Your previous tool call had malformed JSON arguments and was discarded. Emit a complete, valid tool call.")
			_request(false)
			return
		parsed.append({"id": _s(tc.get("id")), "name": _s(fn.get("name")), "args": args})
	_messages.append({"role": "assistant", "content": content, "tool_calls": tcs})
	for p in parsed:
		_messages.append({"role": "tool", "tool_call_id": p["id"], "content": _run_tool(p["name"], p["args"])})
	_after_tool_progress()


func _on_text_calls(content: String) -> void:
	_messages.append({"role": "assistant", "content": content})
	var obs: Array = []
	for c in _parse_text_calls(content):
		var args = c.get("arguments", {})
		if typeof(args) != TYPE_DICTIONARY:
			args = {}
		obs.append("Observation (%s): %s" % [c["name"], _run_tool(c["name"], args)])
	_messages.append({"role": "user", "content": "\n".join(obs)})
	_after_tool_progress()


func _on_silent(reasoning: String) -> void:
	if reasoning.strip_edges() != "":
		_stalls += 1
		if _stalls > STALL_RETRY_LIMIT:
			_fail("reasoning-only stall after %d attempts" % _stalls)
			return
		var cap := reasoning
		if cap.length() > REASONING_CAPTURE_CHARS:
			cap = "[...earlier reasoning truncated...]\n" + cap.substr(cap.length() - REASONING_CAPTURE_CHARS)
		_messages.append({"role": "assistant", "content": cap})
		if _stalls == STALL_RETRY_LIMIT:
			_nudge(NUDGE_FINAL)
			_request(true)
		else:
			_nudge(NUDGE_STALL)
			_request(false)
		return
	_empty += 1
	if _empty <= EMPTY_TURN_RETRY_LIMIT:
		_nudge(NUDGE_EMPTY)
		_request(false)
	else:
		_nudge(NUDGE_FINAL)
		_request(true)


func _finish_forced(tcs: Array, content: String) -> void:
	for c in tcs:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var fn = c.get("function", {})
		if _s(fn.get("name")) == "final_answer":
			var args = JSON.parse_string(_s(fn.get("arguments")))
			var answer := ""
			if typeof(args) == TYPE_DICTIONARY:
				answer = _s(args.get("answer", ""))
			if answer.strip_edges() != "":
				_done(answer)
			else:
				_fail("forced final answer was empty")
			return
	if content.strip_edges() != "":
		_done(content)
	else:
		_fail("forced final answer failed")


func _after_tool_progress() -> void:
	if _cancelled:
		_emit_cancelled()
		return
	_malformed = 0
	_empty = 0
	_steps += 1
	if _steps >= MAX_MODEL_TURNS:
		_nudge(NUDGE_LIMIT)
		_request(true)
		return
	_save()
	_request(false)


func _done(text: String) -> void:
	_messages.append({"role": "assistant", "content": text})
	_save()
	_settled_once = true
	done.emit(text)


func _fail(message: String, kind := "soft") -> void:
	fail_kind = kind
	_save()
	_settled_once = true
	failed.emit(message)


func _nudge(note: String) -> void:
	var text := "[Runtime note: %s]" % note
	for i in range(_messages.size() - 1, -1, -1):
		var m = _messages[i]
		if typeof(m) == TYPE_DICTIONARY and m.get("role") == "user" and typeof(m.get("content")) == TYPE_STRING:
			m["content"] = (str(m["content"]) + "\n\n" + text).strip_edges()
			return
	_messages.append({"role": "user", "content": text})


func _parse_text_calls(content: String) -> Array:
	var calls: Array = []
	var text := content.strip_edges()
	while text != "":
		var m := _text_mini.search(text)
		if m == null:
			m = _text_legacy.search(text)
		if m == null:
			return []
		var obj = JSON.parse_string(m.get_string(1))
		if typeof(obj) != TYPE_DICTIONARY or not obj.has("name"):
			return []
		calls.append({"name": _s(obj["name"]), "arguments": obj.get("arguments", {})})
		text = text.substr(m.get_end()).strip_edges()
	return calls


func _sanitize(text: String) -> String:
	text = text.replace("[ant_tool_call]", "&#91;ant_tool_call&#93;")
	text = text.replace("[/ant_tool_call]", "&#91;/ant_tool_call&#93;")
	text = text.replace("<tool_call", "&lt;tool_call")
	text = text.replace("</tool_call", "&lt;/tool_call")
	if text.length() > TOOL_RESULT_CHARS:
		var head := TOOL_RESULT_CHARS * 2 / 3
		var tail := TOOL_RESULT_CHARS - head
		var elided := text.length() - head - tail
		text = text.substr(0, head) + "\n... [%d chars elided; re-run more narrowly] ...\n" % elided + text.substr(text.length() - tail)
	return text


func _path(p: String) -> String:
	if p.begins_with("/") or p.contains(".."):
		return ""
	return WORKSPACE + p


func _approved(action: String) -> bool:
	return approve.is_valid() and bool(approve.call(action))


func _read_file(a: Dictionary) -> String:
	var path := _s(a.get("path"))
	var p := _path(path)
	if p == "":
		return "ERROR: invalid path"
	if not FileAccess.file_exists(p):
		return "ERROR: not found: " + path
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return "ERROR: cannot open " + path
	var content := f.get_as_text()
	f.close()
	var lines := content.split("\n")
	if lines.size() > 0 and lines[lines.size() - 1] == "":
		lines.remove_at(lines.size() - 1)
	var total := lines.size()
	if total == 0:
		return "(empty file)"
	var start := 1
	if a.has("offset") and int(a["offset"]) > 0:
		start = int(a["offset"])
	if start > total:
		return "ERROR: offset %d is past end of file (%d lines)" % [start, total]
	var limit := READ_FILE_LINES
	if a.has("limit") and int(a["limit"]) > 0:
		limit = int(a["limit"])
	var last_line := mini(start + limit - 1, total)
	var body := ""
	for i in range(start, last_line + 1):
		body += "%6d\t%s\n" % [i, lines[i - 1]]
	if start > 1 or last_line < total:
		body += "[%s: lines %d-%d of %d; call read_file with offset/limit to page]" % [path, start, last_line, total]
	return body


func _write_file(a: Dictionary) -> String:
	var path := _s(a.get("path"))
	var p := _path(path)
	if p == "":
		return "ERROR: invalid path"
	var content := _s(a.get("content"))
	if not _approved("write %s (%d bytes)" % [path, content.to_utf8_buffer().size()]):
		return "DENIED by user"
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return "ERROR: cannot open " + path
	f.store_string(content)
	f.close()
	return "wrote %d bytes to %s" % [content.to_utf8_buffer().size(), path]


func _edit_file(a: Dictionary) -> String:
	var path := _s(a.get("path"))
	var p := _path(path)
	if p == "":
		return "ERROR: invalid path"
	if not FileAccess.file_exists(p):
		return "ERROR: not found: " + path
	var src := FileAccess.get_file_as_string(p)
	var old := _s(a.get("old"))
	var new := _s(a.get("new"))
	if old == "":
		return "ERROR: `old` must not be empty"
	if src.count(old) != 1:
		var so := _strip_line_numbers(old)
		if so != old and src.count(so) == 1:
			old = so
			new = _strip_line_numbers(new)
	if src.count(old) != 1:
		return "ERROR: `old` matched %d times (need exactly 1)" % src.count(old)
	if not _approved("edit " + path):
		return "DENIED by user"
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return "ERROR: cannot open " + path
	f.store_string(src.replace(old, new))
	f.close()
	return "edited " + path


func _strip_line_numbers(text: String) -> String:
	var lines := text.split("\n")
	var nonempty := 0
	var numbered := 0
	for ln in lines:
		if ln.strip_edges() == "":
			continue
		nonempty += 1
		if _line_num.search(ln) != null:
			numbered += 1
	if nonempty == 0 or numbered != nonempty:
		return text
	var out := PackedStringArray()
	for ln in lines:
		out.append(_line_num.sub(ln, ""))
	return "\n".join(out)


func _list_dir(a: Dictionary) -> String:
	var path := _s(a.get("path"))
	var p := _path(path)
	if path.strip_edges() == "":
		p = WORKSPACE
	elif p == "":
		return "ERROR: invalid path"
	var d := DirAccess.open(p)
	if d == null:
		return "ERROR: cannot open " + path
	var names := d.get_files()
	names.append_array(d.get_directories())
	names.sort()
	return "\n".join(names)


func _save() -> void:
	DirAccess.make_dir_recursive_absolute(SESSION_DIR)
	var f := FileAccess.open(SESSION_DIR + session_id + ".json", FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"id": session_id, "name": soul_name, "model": model, "messages": _messages}))
	f.close()


func _run_python(a: Dictionary) -> String:
	var code := _s(a.get("code"))
	if Engine.has_singleton("PyBridge"):
		# Android: in-process Python via the Chaquopy bridge plugin.
		var bridge = Engine.get_singleton("PyBridge")
		return str(bridge.runPython(code))
	# Desktop: one-shot system Python subprocess (blocking, bounded by trust in
	# the model's own code — same trade as every coding agent's shell tool).
	var out := []
	var err := OS.execute("python", ["-c", code], out)
	var text := ""
	for line in out:
		text += str(line) + "\n"
	if err != 0:
		return "ERR: exit %d\n%s" % [err, text]
	return text


## On-device llama.cpp via the LlamaBridge plugin (Android). The model must
## have been loaded first — llama_load_model.gguf in user:// (pushed over adb).
## Desktop has no plugin: report honestly.
func _run_local(a: Dictionary) -> String:
	if not Engine.has_singleton("LlamaBridge"):
		return "ERR: on-device model not available on this platform"
	var bridge = Engine.get_singleton("LlamaBridge")
	if str(_llama_state).strip_edges() == "":
		var model_path := OS.get_user_data_dir().path_join("llama_load_model.gguf")
		if not FileAccess.file_exists(model_path):
			return "ERR: no model loaded — expected llama_load_model.gguf in app storage"
		var loaded := str(bridge.loadModel(model_path, 4096, 4))
		if loaded.begins_with("ERR"):
			return loaded
		_llama_state = "loaded"
	var max_tokens := int(a.get("max_tokens", 128))
	var temp := float(a.get("temp", 0.0))
	var out := str(bridge.complete(_s(a.get("prompt")), max_tokens, temp))
	var perf := str(bridge.lastPerf())
	return out + "\n[perf] " + perf

var _llama_state := ""


func _run_tool(name: String, args: Dictionary) -> String:
	activity.emit("tool: " + name + (" " + str(args.get("path")) if args.has("path") else ""))
	if not _tools.has(name):
		return _sanitize("ERROR: unknown tool " + name)
	return _sanitize(str(_tools[name].call(args)))


static func _s(v) -> String:
	return "" if v == null else str(v)
