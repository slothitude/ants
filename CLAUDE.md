# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Ant's** — Godot 4.7 agent console (Telegram-style lobby/chat + n8n-style nest canvas) for driving a pool of headless agent souls: CLI subprocesses, SSH souls (Lappy/Ryan), and Ant API souls (OpenAI-compatible tool loop, a port of Sentdex/minion). Ships as a desktop app and an arm64 Android APK with bundled CPython (Chaquopy) and llama.cpp (JNI).

`README.md` has the user-facing manual (soul types, HTTP API, tailnet). `spec/jam_spec.json` is the plan of record (M0–M7 + laws); `DIARY.md` is the ledger — read the latest entry before doing anything.

## Commands

Godot binary: `C:\Users\aaron\Godot\godot.bat` (Godot 4.7.1 — owner-canon, 2026-11-15). All gates run headless. **Never open the project with `C:\Users\aaron\Godot\Godot_v4.6.1-stable_win64.exe`** (stray 4.6.1 install): saving from it downgrades `config/features` and can break the 4.7 Android export templates.

```bash
# Import once (or after adding classes/files) — gates fail without it
godot.bat --headless --path . --import

# Gate suites (exit 0 = green; one line per check)
godot.bat --headless --path . --script res://tests/test_console.gd   # 51 checks
godot.bat --headless --path . --script res://tests/test_ant.gd       # 59
godot.bat --headless --path . --script res://tests/test_api.gd       # 22
godot.bat --headless --path . --script res://tests/test_bus.gd       # 13

# Boot smoke test (no errors, exit 0)
godot.bat --headless --path . --quit-after 120

# GUI
godot.bat --path .              # full app
godot.bat --path . -- nest      # boots straight onto the nest canvas
```

GMP gate law: every suite green **twice** before a milestone is done. Manual/live tests (not gates): `tests/manual_nvidia_live.gd` (needs `NM_NVAPI_KEY`), `tests/manual_md_repro.gd`, `tests/manual_repro_full.gd`, `tests/mock_mcp.py`.

Android APK: export preset "Android" in the Godot editor (gradle build, arm64-v8a only) → `builds/necromancer.apk`. The PyBridge plugin (`addons/pybridge/libs/PyBridge-release.aar`) and llama JNI libs (`pybridge/src/main/jniLibs/arm64-v8a/`) pack in automatically. Rebuilding the llama.cpp/JNI layer lives in `thirdparty/` (local-only, gitignored).

## Architecture

All game scripts live at the repo **root** (not in a `scripts/` dir); `main.tscn` is the only scene — the entire UI is built in code.

- **`soul.gd`** — `Soul` base contract (RefCounted). The console pools every soul as one `Array[Soul]` and drives it only through this surface (`submit/cancel/revive/shutdown/get_state/drain_events`).
- **`agent_worker.gd`** — thread+subprocess souls. Blank command = built-in echo backend (for testing). Otherwise `OS.execute_with_pipe` runs the split args; `{prompt}` token replaced, else message goes to stdin.
- **`ant.gd`** — the Ant turn loop (OpenAI-compatible): native `tools` when supported, else the `[ant_tool_call]` text protocol. Tools (`read_file`/`write_file`/`edit_file`/`list_dir`) are sandboxed to `user://workspace/`; `run_python` via Android PyBridge; `run_local` via on-device llama.cpp; `console` lets a soul summon others (recursion capped: 1 original + 3 mid + 9 leaf). Sessions under `user://ant/sessions/`.
- **`ant_soul.gd`** — wraps Ant as a Soul. API souls are frame-driven: a frozen UI pauses their turns (accepted). Honest states: DEAD only for unreachable/401/403; 5xx/429 = soft error + idle; Stop = cancel, not death.
- **`agent_console.gd`** — the whole console (lobby, chat pages, spawn dialog, models picker, nest canvas). ~60k chars; touch it carefully.
- **`event_bus.gd`** — single chokepoint for every console event: typed Godot signals + a 500-deep sequenced ring (`/events?since=`). Also hosts the **pheromone field** (`docs/RESEARCH_ants.md`): souls never message each other directly — they deposit stimuli and atomically claim them, capability-gated.
- **`chat_panel.gd`** — the one-true-transcript widget per soul; embedded in both the chat page and the nest-canvas node cards.
- **`api_server.gd`** — loopback HTTP API on :8720 (falls forward if busy); same operations as the GUI.
- **`mcp_client.gd` + `mcp/mcp_stdio.py`** — the console registers MCP servers (stdio spawn); `mcp_stdio.py` is a zero-dependency MCP bridge exposing `necro_*` tools over the HTTP API (`NECRO_API_HOST` for tailnet, https auto for `*.ts.net`). Registered user-scope: `claude mcp add --scope user necromancer -- python C:/Users/aaron/nm_agent/mcp/mcp_stdio.py`.
- **`pybridge/`** — Android v2 Godot plugin source: `PyBridge.java` (CPython) + `LlamaBridge.java` (llama.cpp JNI). `thirdparty/llama-jni/` is the C wrapper source (its build dir is gitignored, as is all of `thirdparty/llama.cpp`).
- **`keys.json`** — endpoint API keys; gitignored, loaded into memory only. Keys never land in session files or transit the MCP bridge.

## Repo laws (from spec/jam_spec.json)

- **Logic separate**: souls own all agent state; the UI emits intents only and drains events per frame.
- **Constants not magic**: every tunable is a named `const`.
- **No shell**: commands split locally (double quotes honoured), run directly — no injection surface. Exception: SSH souls are wrapped as one remote-shell string (`&&`/pipes work inside the wrap; keep inner quotes single).
- **GDScript 4, tabs**, Godot 4.7.
- Tests ship with the milestone; gate green ×2 before done.

## Godot gotchas learned here (don't re-learn them)

- **Windows pipe law**: `OS.execute_with_pipe` pipes never signal EOF (duplex stdio; `blocking=false` breaks stderr EOF too). All read loops are non-blocking + death-based: poll lines, stop when the process is dead and the buffer is dry. Exit codes via `OS.get_process_exit_code` after death.
- Godot ignores injected clicks on desktop — UI reachability is proven by gates or real phone touches, never synthetic desktop input. Gates assert flags, not animation.
- SceneTree tweens never advance on Android builds — page slides are driven from `_process` by hand.
- `GraphEdit.get_child_count()` counts its internal controls — count your own node dicts.
- Pages are parked offscreen (never `visible = false`) — visibility checks must account for that.
- On Rog, adb pushes need `MSYS_NO_PATHCONV=1` + Windows-style local paths (Git Bash rewrites `/data/...`).
