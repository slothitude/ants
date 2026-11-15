@tool
extends EditorPlugin
## Registers the PyBridge export plugin so the Android gradle build
## bundles the PyBridge AAR into the exported APK.

var export_plugin := PyBridgeExportPlugin.new()


func _enter_tree() -> void:
	add_export_plugin(export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(export_plugin)


class PyBridgeExportPlugin:
	extends EditorExportPlugin

	var _plugin_name := "PyBridge"

	func _get_name() -> String:
		return _plugin_name

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		print("[pybridge-export] providing AAR")
		var arr := PackedStringArray()
		arr.append("pybridge/libs/PyBridge-release.aar")
		return arr
