package com.necromancer.pybridge;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

// NecroMancer LlamaBridge: on-device llama.cpp inference (CPU, arm64).
// The model file lives on device storage (not in the APK); pass its absolute
// path. Timing of the last completion comes back as JSON from lastPerf().
public class LlamaBridge extends GodotPlugin {

	static {
		System.loadLibrary("llama-jni");   // DT_NEEDED pulls llama/ggml from the APK lib dir
	}

	public LlamaBridge(Godot godot) {
		super(godot);
	}

	@Override
	public String getPluginName() {
		return "LlamaBridge";
	}

	private long handle = 0L;

	// Load a gguf from device storage. Returns "ok" or "ERR: ..." text.
	@UsedByGodot
	public String loadModel(String path, int ctxSize, int threads) {
		unload();
		long h = nativeLoadModel(path, ctxSize, threads);
		if (h == 0L) {
			return "ERR: model load failed — " + path;
		}
		handle = h;
		return "ok";
	}

	// Run a prompt. temp <= 0 = greedy. Returns the generated text.
	@UsedByGodot
	public String complete(String prompt, int maxTokens, double temp) {
		if (handle == 0L) {
			return "ERR: no model loaded";
		}
		return nativeComplete(handle, prompt, maxTokens, temp);
	}

	// JSON timing of the last complete(): prompt_ms, gen_ms, n_*, *_tps.
	@UsedByGodot
	public String lastPerf() {
		return nativeLastPerf(handle);
	}

	@UsedByGodot
	public String unload() {
		if (handle != 0L) {
			nativeFree(handle);
			handle = 0L;
		}
		return "ok";
	}

	private static native long nativeLoadModel(String path, int ctxSize, int threads);
	private static native String nativeComplete(long handle, String prompt, int maxTokens, double temp);
	private static native String nativeLastPerf(long handle);
	private static native void nativeFree(long handle);
}
