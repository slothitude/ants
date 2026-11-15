class_name ApiServer
extends RefCounted
## Loopback HTTP JSON API so agents and MCP clients can drive the console.
## Threaded accept/read; every request is dispatched to the console on the main
## thread (call_deferred) and the socket thread waits for the computed response.
## Routes live in the console's _api_dispatch; responses come back via respond().

var port := 0

var _console: Node
var _srv: TCPServer
var _thread: Thread
var _stop := false
var _lock := Mutex.new()
var _responses := {}   # id -> {"status": int, "text": String}
var _next_id := 0


func _init(console: Node, preferred_port: int) -> void:
	_console = console
	_srv = TCPServer.new()
	# Loopback-only everywhere: Godot rejects IPAddress("") (invalid on every
	# platform — ERR_INVALID_PARAMETER before the socket opens), and the phone
	# app reaches its API through adb forward, so loopback is all it needs.
	var bind_addr := "127.0.0.1"
	for attempt in 20:
		if _srv.listen(preferred_port + attempt, bind_addr) == OK:
			port = preferred_port + attempt
			break
	if port == 0:
		push_error("ApiServer: no free port in %d..%d" % [preferred_port, preferred_port + 19])
		return
	_thread = Thread.new()
	_thread.start(_serve)


func shutdown() -> void:
	_stop = true
	if _srv != null:
		_srv.stop()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()


func respond(id: int, status: int, payload: Dictionary) -> void:
	_lock.lock()
	_responses[id] = {"status": status, "text": JSON.stringify(payload)}
	_lock.unlock()


func _serve() -> void:
	while not _stop:
		if _srv.is_connection_available():
			_handle(_srv.take_connection())
		else:
			OS.delay_msec(10)


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
	if header_end < 0:
		c.disconnect_from_host()
		return
	var head := buf.slice(0, header_end).get_string_from_ascii()
	var req_line := head.split("\r\n")[0]
	var method := req_line.get_slice(" ", 0)
	var raw_path := req_line.get_slice(" ", 1)
	var body := {}
	var body_text := buf.slice(header_end + 4, buf.size()).get_string_from_utf8()
	if body_text.strip_edges() != "":
		var parsed = JSON.parse_string(body_text)
		if typeof(parsed) == TYPE_DICTIONARY:
			body = parsed

	var id := 0
	_lock.lock()
	id = _next_id
	_next_id += 1
	_lock.unlock()
	_console.call_deferred("_api_dispatch", id, method, raw_path, body)

	var resp := {}
	var got := false
	deadline = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		_lock.lock()
		if _responses.has(id):
			resp = _responses[id]
			_responses.erase(id)
			got = true
		_lock.unlock()
		if got:
			break
		OS.delay_msec(15)
	if not got:
		resp = {"status": 504, "text": "{\"error\": \"dispatch timeout\"}"}
	var payload := str(resp.get("text", "{}"))
	var status := int(resp.get("status", 504))
	var out := payload.to_utf8_buffer()
	var resp_head := "HTTP/1.1 %d OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, out.size()]
	c.put_data(resp_head.to_ascii_buffer() + out)
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
