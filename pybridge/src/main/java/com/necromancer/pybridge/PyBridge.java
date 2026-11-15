package com.necromancer.pybridge;

import android.app.Activity;
import com.chaquo.python.PyObject;
import com.chaquo.python.Python;
import com.chaquo.python.android.AndroidPlatform;
import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

// NecroMancer PyBridge: exposes in-process Python (Chaquopy) to GDScript.
public class PyBridge extends GodotPlugin {

	public PyBridge(Godot godot) {
		super(godot);
	}

	@Override
	public String getPluginName() {
		return "PyBridge";
	}

	private Python py() {
		if (!Python.isStarted()) {
			Activity activity = getActivity();
			if (activity == null) {
				return null;
			}
			Python.start(new AndroidPlatform(activity));
		}
		return Python.getInstance();
	}

	// Run Python source, capturing stdout; returns "OK" plus captured output.
	// exec MUST get an explicit globals dict: bare exec inherits the caller's
	// frame, and Chaquopy's JNI shim has no Python frame — that is the
	// "SystemError: frame does not exist". A dict argument makes exec build a
	// fresh module-level frame of its own. The dict is reused across calls so
	// run_python state persists (like REPL globals).
	private PyObject globals;

	@UsedByGodot
	public String runPython(String code) {
		Python py = py();
		if (py == null) {
			return "ERR: python runtime unavailable";
		}
		try {
			PyObject sys = py.getModule("sys");
			PyObject io = py.getModule("io");
			PyObject buf = io.callAttr("StringIO");
			PyObject old = sys.get("stdout");
			sys.put("stdout", buf);
			PyObject builtins = py.getModule("builtins");
			if (globals == null) {
				globals = builtins.callAttr("dict");
			}
			builtins.callAttr("exec", code, globals);
			sys.put("stdout", old);
			String text = buf.callAttr("getvalue").toString();
			return "OK\n" + text;
		} catch (Throwable e) {
			return "ERR: " + e.getMessage();
		}
	}

	@UsedByGodot
	public String hello() {
		py();
		return "necromancer-online";
	}
}
