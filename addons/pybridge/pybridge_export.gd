@tool
extends EditorExportPlugin
## Export hook: hands the PyBridge AAR to the Android gradle build so the
## v2 plugin (manifest meta-data org.godotengine.plugin.v2.PyBridge)
## reaches the APK and registers the "PyBridge" singleton.

var _plugin_name := "PyBridge"


func _get_name() -> String:
	return _plugin_name


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid


func _get_android_libraries(_features: PackedStringArray, debug: bool) -> PackedStringArray:
	print("[pybridge-export] providing AAR (debug=", debug, ")")
	if debug:
		return PackedStringArray("addons/pybridge/libs/PyBridge-debug.aar")
	return PackedStringArray("addons/pybridge/libs/PyBridge-release.aar")


func _get_export_options(_platform: EditorExportPlatform) -> Array[Dictionary]:
	return []
