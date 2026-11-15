class_name EventBus
extends RefCounted
## The console's full signal bus: every event that happens anywhere in the
## console (souls, whispers, deaths, heals, lifecycle, API actions) flows
## through emit_event once — as a Godot signal for in-app listeners AND as a
## sequenced entry in a bounded ring buffer that HTTP/MCP clients poll with
## GET /events?since=<seq>.

signal event_occurred(seq: int, kind: String, name: String, text: String)
signal soul_spawned(name: String)
signal soul_removed(name: String)
signal soul_state_changed(name: String, state: String)
signal soul_died(name: String, reason: String)
signal soul_healed(name: String)
signal whisper_sent(name: String, text: String)

const RING_CAP := 500

var _lock := Mutex.new()
var _ring: Array = []         # [{seq, kind, name, text}] oldest first
var _seq := 0


## Single chokepoint: append to the ring, fire the matching typed signal.
func emit_event(kind: String, soul_name: String, text := "") -> int:
	_lock.lock()
	_seq += 1
	var seq := _seq
	_ring.append({"seq": seq, "kind": kind, "name": soul_name, "text": text})
	if _ring.size() > RING_CAP:
		_ring.pop_front()
	_lock.unlock()
	event_occurred.emit(seq, kind, soul_name, text)
	match kind:
		"spawned":
			soul_spawned.emit(soul_name)
		"removed":
			soul_removed.emit(soul_name)
		"dead":
			soul_died.emit(soul_name, text)
		"heal":
			soul_healed.emit(soul_name)
		"you":
			whisper_sent.emit(soul_name, text)
	return seq


## Everything newer than `since_seq` (pass 0 for the whole ring).
## Returns {events, next} — next is the sequence to hand back as since.
func events_since(since_seq: int) -> Dictionary:
	_lock.lock()
	var out := []
	var next := _seq
	for e in _ring:
		if int(e["seq"]) > since_seq:
			out.append(e)
	_lock.unlock()
	return {"events": out, "next": next}


func current_seq() -> int:
	_lock.lock()
	var s := _seq
	_lock.unlock()
	return s


# ---------- chem comms: the pheromone field ----------
# Ant-research law (docs/RESEARCH_ants.md): communication is environment-
# mediated. Souls never message each other directly — they deposit stimuli
# into the shared field and sense what's available. Claiming is atomic
# (one ant per stimulus) and strength-gated by the claiming ant's capability.

var _pheromones := {}   # id -> {kind, payload, strength, expires_ms, claimed_by}
var _ph_lock := Mutex.new()
var _ph_seq := 0


## Deposit a stimulus into the pheromone field. Returns its id.
func deposit_pheromone(kind: String, payload: String, strength := 1.0, ttl_sec := 300.0) -> int:
	_ph_lock.lock()
	_ph_seq += 1
	var id := _ph_seq
	_pheromones[id] = {
		"kind": kind,
		"payload": payload,
		"strength": strength,
		"expires_ms": Time.get_ticks_msec() + int(ttl_sec * 1000.0),
		"claimed_by": "",
	}
	_ph_lock.unlock()
	emit_event("pheromone", kind, payload)
	return id


## Sense the field: unclaimed, unexpired stimuli, strongest first.
## Pass kind to filter (e.g. "task").
func sense_pheromones(kind := "") -> Array:
	_ph_lock.lock()
	var now := Time.get_ticks_msec()
	var out := []
	for id_key in _pheromones.keys():
		var p: Dictionary = _pheromones[id_key]
		if now > int(p["expires_ms"]):
			_pheromones.erase(id_key)
			continue
		if kind != "" and str(p["kind"]) != kind:
			continue
		if str(p.get("claimed_by", "")) != "":
			continue
		out.append({"id": id_key, "kind": p["kind"], "payload": p["payload"],
				"strength": p["strength"]})
	out.sort_custom(func(a, b): return float(a["strength"]) > float(b["strength"]))
	_ph_lock.unlock()
	return out


## Atomically claim a stimulus. Returns its payload, or {error} if taken,
## expired, or below the claimant's capability threshold.
func claim_pheromone(id: int, claimant: String, capability := 1.0) -> Dictionary:
	_ph_lock.lock()
	if not _pheromones.has(id):
		_ph_lock.unlock()
		return {"error": "stimulus gone"}
	var p: Dictionary = _pheromones[id]
	if str(p.get("claimed_by", "")) != "":
		_ph_lock.unlock()
		return {"error": "already claimed"}
	if capability < float(p["strength"]):
		_ph_lock.unlock()
		return {"error": "below threshold"}
	p["claimed_by"] = claimant
	var payload := str(p["payload"])
	_ph_lock.unlock()
	emit_event("claimed", p["kind"], "%s claimed %s" % [claimant, p["kind"]])
	return {"payload": payload}


func pheromone_count() -> int:
	_ph_lock.lock()
	var n := _pheromones.size()
	_ph_lock.unlock()
	return n
