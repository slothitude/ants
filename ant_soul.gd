class_name AntSoul
extends Soul
## A frame-driven "soul" wrapper around an Ant agent (ant.gd) for the console.
## No threads: the turn loop is a coroutine that ticks on process_frame and
## settles when Ant emits exactly one of done / failed / cancelled per turn.
## Event and drain patterns mirror agent_worker.gd so the console can treat
## this like any other soul. A dead Ant is transport death (connect failure,
## HTTP 401/403) or a forced-final failure; cancellation is NOT death.

var _mutex := Mutex.new()
var _queue: Array[String] = []
var _events: Array = []       # [kind, text] pairs, guarded by _mutex
var _status := "idle"
var _dead := false
var _stop := false
var _awaiting := false        # a turn's pump loop is active
var _settled := true          # the in-flight turn has fired its settling signal
var _pump_busy := false       # coalesces deferred _pump calls
var _gen := 0                 # turn generation; guards a stale loop
var _cleaned := false         # _cleanup() idempotence guard
var _ant: Ant
var _host: Node
var _self_keep: AntSoul = null


func _init(p_name: String, base_url: String, model: String, key: String, host: Node) -> void:
	name_text = p_name
	_host = host
	_ant = Ant.new(host)
	_ant.base_url = base_url
	_ant.model = model
	_ant.api_key = key if key != "" else "sk-noop"
	_ant.done.connect(_on_done)
	_ant.failed.connect(_on_failed)
	_ant.cancelled.connect(_on_cancelled)
	_ant.activity.connect(_on_activity)


# ---------- console surface ----------

func submit(text: String) -> void:
	_mutex.lock()
	if _stop:
		_mutex.unlock()
		return
	_queue.append(text)
	_mutex.unlock()
	_pump.call_deferred()


func queued() -> int:
	_mutex.lock()
	var n := _queue.size()
	_mutex.unlock()
	return n


func get_state() -> String:
	_mutex.lock()
	var s := _status
	var d := _dead
	_mutex.unlock()
	return "dead" if d else s


func drain_events() -> Array:
	_mutex.lock()
	var out := _events
	_events = []
	_mutex.unlock()
	return out


func cancel() -> void:
	_mutex.lock()
	_queue.clear()
	_mutex.unlock()
	if _ant == null:
		return
	_ant.cancel()   # cancellation is not death; the turn settles via _on_cancelled


func shutdown() -> void:
	_mutex.lock()
	if _stop:
		_mutex.unlock()
		return
	_stop = true
	_mutex.unlock()
	if _ant == null:
		return
	_ant.cancel()
	var awaiting := true
	_mutex.lock()
	awaiting = _awaiting
	_mutex.unlock()
	if not awaiting:
		_cleanup()   # idle: tear down right now; a mid-flight turn cleans up itself


func wait_done() -> void:
	pass   # no Thread exists — nothing to join, never block here


func revive() -> void:
	_mutex.lock()
	var was := _dead
	_dead = false
	_mutex.unlock()
	if was:
		_emit("heal", "revived — ready to serve")


## Live access to the wrapped Ant (null after shutdown) — the console uses it
## to wire console control into the soul's tool loop.
func ant_ref() -> Ant:
	return _ant


# Orchestration lineage (managed by the console): depth 1 = summoned by the
# owner/API; depth 2 = summoned by a depth-1 ant; depth 3 = summoned by a
# depth-2 ant (leaves — may not summon). Per-soul summon budget: 3.
var depth := 1
var children := 0


# ---------- event machinery ----------

func _emit(kind: String, text: String) -> void:
	_mutex.lock()
	_events.append([kind, text])
	_mutex.unlock()


# ---------- pump / turn loop (main thread, frame-driven) ----------

func _pump() -> void:
	_mutex.lock()
	if _pump_busy or _stop or _queue.is_empty():
		_mutex.unlock()
		return
	var prompt: String = _queue.pop_front()
	_status = "busy"
	_pump_busy = true
	_awaiting = true
	_gen += 1
	var gen := _gen
	# RefCounted self-keep: the console may drop its reference mid-turn; the
	# suspended coroutine must not run on a freed instance.
	_self_keep = self
	_mutex.unlock()
	_turn_loop(gen, prompt)


func _turn_loop(gen: int, prompt: String) -> void:
	_mutex.lock()
	_settled = false
	_mutex.unlock()
	_ant.ask(prompt)
	while true:
		await _host.get_tree().process_frame
		var settled := false
		var stop := false
		var superseded := false
		_mutex.lock()
		settled = _settled
		stop = _stop
		superseded = gen != _gen
		_mutex.unlock()
		if stop and not settled:
			_ant.cancel()   # safe to call repeatedly
		if settled or superseded:
			break
	_mutex.lock()
	var was_stop := _stop
	_settled = true
	_awaiting = false
	_pump_busy = false
	if not was_stop:
		_status = "idle"
	_mutex.unlock()
	if was_stop:
		_cleanup()
		_self_keep = null
		return
	_self_keep = null
	_pump.call_deferred()   # next queued whisper, if any


# ---------- Ant signal handlers ----------

func _on_done(reply: String) -> void:
	_mutex.lock()
	_events.append(["output", reply])
	_events.append(["system", "finished"])
	_settled = true
	_mutex.unlock()


func _on_failed(message: String) -> void:
	var kind := _ant.fail_kind
	_mutex.lock()
	if kind == "dead":
		_dead = true
		_events.append(["dead", message])
	else:
		_events.append(["error", message])
	_settled = true
	_mutex.unlock()


func _on_cancelled() -> void:
	_mutex.lock()
	_events.append(["system", "cancelled"])
	_settled = true
	_mutex.unlock()


func _on_activity(text: String) -> void:
	_emit("system", text)


# ---------- teardown ----------

func _cleanup() -> void:
	if _cleaned:
		return
	_cleaned = true
	if _ant == null:
		_self_keep = null
		return
	if _ant.done.is_connected(_on_done):
		_ant.done.disconnect(_on_done)
	if _ant.failed.is_connected(_on_failed):
		_ant.failed.disconnect(_on_failed)
	if _ant.cancelled.is_connected(_on_cancelled):
		_ant.cancelled.disconnect(_on_cancelled)
	if _ant.activity.is_connected(_on_activity):
		_ant.activity.disconnect(_on_activity)
	if is_instance_valid(_ant.http):
		_ant.http.queue_free()
	_ant = null
	_self_keep = null
