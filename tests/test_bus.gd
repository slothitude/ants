extends SceneTree
## GMP gate suite for the pheromone field (chem comms gating, M5). Headless:
##   GODOT --headless --path . --script res://tests/test_bus.gd
## Exit 0 = green.

var checks := 0
var fails: Array[String] = []
var bus := EventBus.new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	print("[bus] deposit + sense")
	var id := bus.deposit_pheromone("task", "summarize docs", 0.5, 300.0)
	_check(id > 0, "deposit returns an id")
	var sensed := bus.sense_pheromones()
	_check(sensed.size() == 1 and str(sensed[0]["payload"]) == "summarize docs",
			"sense returns the deposited stimulus")

	print("[bus] strongest-first ordering")
	var id2 := bus.deposit_pheromone("task", "high priority", 0.9, 300.0)
	sensed = bus.sense_pheromones()
	_check(sensed.size() == 2 and str(sensed[0]["payload"]) == "high priority",
			"strongest stimulus sorts first")

	print("[bus] claim atomicity")
	var c1: Dictionary = bus.claim_pheromone(id, "ant-a", 1.0)
	_check(c1.has("payload"), "first claim wins")
	var c2: Dictionary = bus.claim_pheromone(id, "ant-b", 1.0)
	_check(c2.has("error"), "second claim is denied")
	_check(bus.sense_pheromones().size() == 1, "claimed stimulus leaves the field")

	print("[bus] strength gating")
	var c3: Dictionary = bus.claim_pheromone(id2, "leaf-ant", 0.5)
	_check(c3.has("error") and str(c3["error"]) == "below threshold",
			"low-capability ant denied strong stimulus")
	var c4: Dictionary = bus.claim_pheromone(id2, "mid-ant", 0.95)
	_check(c4.has("payload"), "capable ant claims the strong stimulus")

	print("[bus] ttl evaporation")
	var id3 := bus.deposit_pheromone("task", "ephemeral", 1.0, 0.3)
	_check(bus.pheromone_count() == 3, "three stimuli in the field")
	await create_timer(0.6).timeout
	var gone := bus.sense_pheromones()
	var still_there := false
	for e in gone:
		if str(e["payload"]) == "ephemeral":
			still_there = true
	_check(not still_there, "expired stimulus evaporates from sense")
	_check(bus.sense_pheromones("missing-kind").is_empty(), "kind filter returns empty")

	print("[bus] necro ops sense + claim")
	var console = load("res://main.tscn").instantiate()
	root.add_child(console)
	await process_frame
	var bus_ant: Soul = console._add_ant_soul("bus-ant", "http://127.0.0.1:9/v1", "m", "")
	var id4: int = console.bus.deposit_pheromone("task", "via-necro", 0.4, 300.0)
	var got: Dictionary = console.api_necro_for(bus_ant, {"op": "sense"})
	var found := false
	for s in got.get("stimuli", []):
		if str(s.get("payload")) == "via-necro":
			found = true
	_check(found, "necro sense sees the stimulus")
	var cl: Dictionary = console.api_necro_for(bus_ant, {"op": "claim", "id": id4})
	_check(bool(cl.get("claimed", false)) and str(cl.get("payload")) == "via-necro",
			"necro claim routes through the bus")
	console.queue_free()
	await process_frame

	print("[bus] done")
	_finish()


func _check(cond: bool, what: String) -> void:
	checks += 1
	if cond:
		print("  ok   " + what)
	else:
		fails.append(what)
		printerr("  FAIL " + what)


func _finish() -> void:
	print("")
	if fails.is_empty():
		print("GATE GREEN - %d checks" % checks)
		quit(0)
	else:
		printerr("GATE RED - %d of %d failed: %s" % [fails.size(), checks, ", ".join(PackedStringArray(fails))])
		quit(1)
