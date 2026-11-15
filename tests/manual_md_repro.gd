extends SceneTree
## Diagnostic: desktop run_python via OS.execute.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var ant := Ant.new(root)
	var out := []
	var err := OS.execute("python", ["-c", "print('py-ok')"], out)
	print("raw err=", err, " out=", out)
	var r: String = ant._run_python({"code": "print('py-ok')"})
	print("tool r=", r.left(200))
	var r2: String = ant._run_python({"code": "raise ValueError('boom')"})
	print("tool r2=", r2.left(200))
	ant.http.queue_free()
	quit(0)
