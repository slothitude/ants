class_name Soul
extends RefCounted
## The contract every console soul obeys. AgentWorker (thread/subprocess souls)
## and AntSoul (API souls) both extend this, so the console pools them as one
## typed array and drives them through this surface only.


var name_text: String


func get_state() -> String:
	return "idle"


func queued() -> int:
	return 0


func submit(_text: String) -> void:
	pass


func cancel() -> void:
	pass


func shutdown() -> void:
	pass


func wait_done() -> void:
	pass


func drain_events() -> Array:
	return []


func revive() -> void:
	pass
