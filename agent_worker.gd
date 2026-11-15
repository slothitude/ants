class_name AgentWorker
extends Soul
## A headless agent: one background thread, one prompt queue, one optional subprocess.
## Blank command = built-in echo backend (for testing the UI).
## Otherwise the command runs with its args. The token {prompt} is replaced by the
## message. If {prompt} is absent, the message is written to the process's stdin.
## A command agent turns DEAD when its process fails to start or exits non-zero;
## revive() clears the mark so the next whisper re-runs the command.

const PROMPT_TOKEN := "{prompt}"
const ECHO_TICKS := 10
const ECHO_TICK_MS := 200
const POLL_MS := 50

var command: String
var _args_template: PackedStringArray

var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _queue: Array[String] = []
var _events: Array = []       # [kind, text] pairs, guarded by _mutex
var _status := "idle"
var _dead := false
var _cancel := false
var _stop := false
var _pid := -1
var _thread: Thread


func _init(p_name: String, p_command: String) -> void:
	name_text = p_name
	command = p_command.strip_edges()
	_args_template = _split_args(command)
	_thread = Thread.new()
	_thread.start(_run)


# ---------- called from the main thread ----------

func submit(text: String) -> void:
	_mutex.lock()
	_queue.append(text)
	_mutex.unlock()
	_sem.post()


func queued() -> int:
	_mutex.lock()
	var n := _queue.size()
	_mutex.unlock()
	return n


func get_status() -> String:
	_mutex.lock()
	var s := _status
	_mutex.unlock()
	return s


func get_state() -> String:
	_mutex.lock()
	var s := _status
	var d := _dead
	_mutex.unlock()
	return "dead" if d else s


func revive() -> void:
	_mutex.lock()
	var was := _dead
	_dead = false
	_mutex.unlock()
	if was:
		_emit("heal", "revived — ready to serve")


func cancel() -> void:
	_mutex.lock()
	_queue.clear()
	_cancel = true
	var pid := _pid
	_mutex.unlock()
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)


func shutdown() -> void:
	_mutex.lock()
	_stop = true
	_mutex.unlock()
	cancel()
	_sem.post()


func wait_done() -> void:
	_thread.wait_to_finish()


func drain_events() -> Array:
	_mutex.lock()
	var out := _events
	_events = []
	_mutex.unlock()
	return out


# ---------- worker thread ----------

func _emit(kind: String, text: String) -> void:
	_mutex.lock()
	_events.append([kind, text])
	_mutex.unlock()


func _set_dead(reason: String) -> void:
	_mutex.lock()
	_dead = true
	_mutex.unlock()
	_emit("dead", reason)


func _is_cancelled() -> bool:
	_mutex.lock()
	var c := _cancel
	_mutex.unlock()
	return c


func _run() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		if _stop:
			_mutex.unlock()
			break
		if _queue.is_empty():
			_mutex.unlock()
			continue
		var prompt: String = _queue.pop_front()
		_cancel = false
		_status = "busy"
		_mutex.unlock()

		if command.is_empty():
			_run_echo(prompt)
		else:
			_run_process(prompt)

		_mutex.lock()
		_status = "idle"
		_pid = -1
		_mutex.unlock()


func _run_echo(prompt: String) -> void:
	_emit("output", "%s working..." % name_text)
	for i in ECHO_TICKS:
		OS.delay_msec(ECHO_TICK_MS)
		if _is_cancelled():
			_emit("system", "cancelled")
			return
	_emit("output", "echo: " + prompt)


func _run_process(prompt: String) -> void:
	if _args_template.is_empty():
		_emit("error", "empty command")
		return

	var use_stdin := not _args_template.has(PROMPT_TOKEN)
	var args := PackedStringArray()
	for a in _args_template:
		args.append(prompt if a == PROMPT_TOKEN else a)

	var exe := args[0]
	var rest := args.slice(1)
	# Windows pipe gotcha (found by the gate suite): Godot's execute_with_pipe
	# pipes never signal EOF reliably (stdio is duplex — the parent keeps its
	# write handle; with blocking=false even stderr never sets eof_reached).
	# So every read loop here is non-blocking and death-based: poll, emit lines,
	# stop when the process is dead and the buffer is dry.
	var info := OS.execute_with_pipe(exe, rest, false)
	if info.is_empty():
		_emit("error", "could not start: " + exe)
		_set_dead("died — could not start " + exe)
		return

	var pid: int = info["pid"]
	var stdio: FileAccess = info["stdio"]
	var stderr: FileAccess = info["stderr"]

	_mutex.lock()
	_pid = pid
	var cancelled_early := _cancel
	_mutex.unlock()
	if cancelled_early:
		OS.kill(pid)

	if use_stdin:
		stdio.store_string(prompt + "\n")

	# Drain stderr on its own thread so a full stderr pipe can't deadlock us.
	# EOF never fires on these Windows duplex pipes, so the drain loop is
	# death-based: read non-blocking, stop when the process is dead and dry.
	var err_thread := Thread.new()
	err_thread.start(_drain_stderr.bind(stderr, pid))

	while true:
		var line := stdio.get_line()
		if line != "":
			_emit("output", line)
			continue
		if stdio.eof_reached() or not OS.is_process_running(pid):
			break
		OS.delay_msec(POLL_MS)
	err_thread.wait_to_finish()

	var code := OS.get_process_exit_code(pid)
	if _is_cancelled():
		_emit("system", "cancelled")
	elif code != 0 and code != -1:
		_set_dead("died — exit code %d" % code)
	else:
		_emit("system", "finished (exit %d)" % code)


func _drain_stderr(f: FileAccess, pid: int) -> void:
	while true:
		var line := f.get_line()
		if line != "":
			_emit("error", line)
			continue
		if f.eof_reached() or not OS.is_process_running(pid):
			break
		OS.delay_msec(POLL_MS)


static func _split_args(s: String) -> PackedStringArray:
	# Splits on spaces, honouring double quotes. Not a full shell parser.
	var out := PackedStringArray()
	var cur := ""
	var in_quotes := false
	var has := false
	for c in s:
		if c == '"':
			in_quotes = not in_quotes
			has = true
		elif c == " " and not in_quotes:
			if has:
				out.append(cur)
				cur = ""
				has = false
		else:
			cur += c
			has = true
	if has:
		out.append(cur)
	return out
