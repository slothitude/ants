class_name McpClient
extends RefCounted
## One registered MCP server: a stdio subprocess speaking line-delimited
## JSON-RPC 2.0. Windows pipe law applies (execute_with_pipe non-blocking,
## reads polled, never a blocking get_line). All awaits tick on the host's
## process frames — the console calls this from main-thread coroutines only.

var server_name := ""
var tools: Array = []          # [{name, description, inputSchema}]

var _pid := -1
var _stdio: FileAccess
var _stderr: FileAccess
var _pending := {}             # id -> response object
var _req_id := 10              # 1..9 reserved for the handshake


func _init(p_name: String, command: String) -> void:
	server_name = p_name
	var args := AgentWorker._split_args(command)
	if args.is_empty():
		return
	var info := OS.execute_with_pipe(args[0], args.slice(1), false)
	if info.is_empty():
		return
	_pid = info["pid"]
	_stdio = info["stdio"]
	_stderr = info["stderr"]
	var t := Thread.new()
	t.start(_drain_stderr.bind(_stderr, _pid))


static func _drain_stderr(f: FileAccess, pid: int) -> void:
	while true:
		var line := f.get_line()
		if line != "":
			continue   # v1: server stderr is ignored
		if f.eof_reached() or not OS.is_process_running(pid):
			break
		OS.delay_msec(50)


func is_alive() -> bool:
	return _pid > 0 and OS.is_process_running(_pid)


func stdio_null() -> bool:
	return _stdio == null


func shutdown() -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1


func _send(id: int, method: String, params: Dictionary) -> void:
	_stdio.store_string(JSON.stringify({
		"jsonrpc": "2.0", "id": id, "method": method, "params": params,
	}) + "\n")


func _notify(method: String, params: Dictionary) -> void:
	_stdio.store_string(JSON.stringify({
		"jsonrpc": "2.0", "method": method, "params": params,
	}) + "\n")


func _drain_stdout() -> void:
	while true:
		var line := _stdio.get_line()
		if line != "":
			_handle_line(line)
			continue
		break


func _handle_line(line: String) -> void:
	var obj = JSON.parse_string(line)
	if typeof(obj) == TYPE_DICTIONARY and obj.has("id"):
		_pending[int(obj["id"])] = obj


func _await_response(id: int, host: Node, timeout: float) -> Dictionary:
	var t := 0.0
	while t < timeout:
		_drain_stdout()
		if _pending.has(id):
			var r = _pending[id]
			_pending.erase(id)
			if typeof(r) == TYPE_DICTIONARY:
				return r
			return {}
		if not is_alive():
			break
		await host.get_tree().create_timer(0.05).timeout
		t += 0.05
	return {}


func initialize(host: Node) -> bool:
	if _stdio == null:
		return false
	_send(1, "initialize", {
		"protocolVersion": "2024-11-05",
		"capabilities": {},
		"clientInfo": {"name": "necromancer-console", "version": "1.0.0"},
	})
	var r := await _await_response(1, host, 15.0)
	if r.is_empty():
		return false
	_notify("notifications/initialized", {})
	return true


func list_tools(host: Node) -> Array:
	_req_id += 1
	var id := _req_id
	_send(id, "tools/list", {})
	var r := await _await_response(id, host, 15.0)
	var result = r.get("result", {})
	if typeof(result) == TYPE_DICTIONARY and typeof(result.get("tools")) == TYPE_ARRAY:
		tools = result["tools"]
	return tools


func call_tool(tool_name: String, arguments: Dictionary, host: Node) -> Dictionary:
	var out := {"ok": false, "content": "", "error": ""}
	if _stdio == null:
		out["error"] = "server is not running"
		return out
	_req_id += 1
	var id := _req_id
	_send(id, "tools/call", {"name": tool_name, "arguments": arguments})
	var r := await _await_response(id, host, 60.0)
	if r.is_empty():
		out["error"] = "no response (timeout or server died)"
		return out
	if typeof(r.get("error")) == TYPE_DICTIONARY:
		out["error"] = str(r["error"].get("message", "server error"))
		return out
	var result = r.get("result", {})
	if typeof(result) == TYPE_DICTIONARY:
		out["ok"] = true
		var content = result.get("content", [])
		var texts := []
		if typeof(content) == TYPE_ARRAY:
			for c in content:
				if typeof(c) == TYPE_DICTIONARY:
					texts.append(str(c.get("text", "")))
		out["content"] = "\n".join(texts)
	return out
