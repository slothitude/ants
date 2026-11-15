# Ant's — the NecroMancer agent console

Godot 4 console for driving a pool of headless agent processes. Dark-arts themed
per the owner's key art: **summon · control · heal · reap · repeat...**

## Run

Open this folder in Godot 4.7 (any Godot 4.x works) and press F5. `main.tscn` is
the main scene: `agent_console.gd` sits on its Control root, `agent_worker.gd` is
the headless worker class.

## The word map (art card → console control)

| Image card | Console control |
|---|---|
| Spawn Agent | **Spawn** — summon dialog (name + command) |
| Monitor Agents | status line + per-soul state in the pool list (IDLE / BUSY / DEAD) |
| Manage Pool | the pool list + **Stop** / **Reap** / **Stop All** |
| Restart Dead | **Heal Dead** — revives every DEAD soul with its old command |
| Optimize Load | **Optimize: idle only** — broadcasts skip busy and dead souls |

Three souls are pre-seeded with echo backends, named after the art (Qwen3.5,
GLM-5.3, Gemma). New souls take a real command, e.g.
`python my_worker.py --task {prompt}`.

## Mechanics

- Each agent = one background thread + prompt queue; the UI only emits intents
  (submit / cancel / revive). Worker threads share state only through a Mutex;
  the UI drains events each frame.
- Blank command = built-in echo backend. A command runs directly — no shell, no
  injection surface; args are split on spaces with double quotes honoured.
- `{prompt}` in the command is replaced by the message. Without the token, the
  message is written to stdin (a CLI that waits for EOF before answering will
  hang — use the `{prompt}` form for those).
- **Death**: a process that fails to start or exits non-zero marks the soul DEAD
  and the exit code lands in the transcript (`OS.get_process_exit_code`; -1 /
  unknown counts as finished). Whispering to a dead soul auto-revives it.
  **Heal Dead** revives all dead souls at once.
- **Stop** kills the process and clears that soul's queue. **Reap** removes the
  soul and waits for its thread to finish.
- **Windows pipe law (found by the gate suite)**: `OS.execute_with_pipe` pipes
  never signal EOF reliably on Windows — stdio is a duplex pipe (the parent
  keeps its write handle) and with `blocking=false` even stderr never sets
  `eof_reached`. Every read loop is therefore non-blocking and death-based:
  poll lines, stop when the process is dead and the buffer is dry. Exit codes
  come from `OS.get_process_exit_code` after death.

## SSH souls

Spawn → **Run on** picker → Lappy or Ryan. Your command is wrapped as
`ssh -o BatchMode=yes aaron@<host> "<command>"` and runs there; Rog's key is
already authorized on both hosts. The remote command is handed to the remote
shell as one string, so `&&` and pipes DO work inside ssh souls (unlike local
ones) — but keep inner quotes single, or the wrap breaks. BatchMode disables
password prompts (they would hang a headless process): if a key stops working,
the soul dies instantly with ssh's exit code instead of freezing.

## API souls (Ant — Sentdex/minion port)

Spawn → **Agent (OpenAI-compatible API)**. Fields: Base URL, Model, API key — plus an
endpoint preset picker (llama-swap LAN / OpenRouter / NVIDIA API catalog; the URL stays
editable, so any `/v1` endpoint works). The key lives in memory only — session files
never store it.

An API soul runs the Ant turn loop: OpenAI `tools` when the server supports them, else
the `[ant_tool_call]` text protocol. Tools: `read_file` / `write_file` / `edit_file` /
`list_dir`, sandboxed to `user://workspace/`, plus `run_python` (Android builds via the
PyBridge plugin — desktop answers "only available in the Android build"). Sessions save
under `user://ant/sessions/`.

Honest states: **DEAD** only for unreachable endpoints / 401 / 403 (whisper to
auto-revive); transient 5xx/429 = error line, back to idle; **Stop** cancels the turn —
idle, not death. API souls are frame-driven: a frozen UI pauses their turns (accepted).

## The layout

- **Viewport desktop**: every soul's chat is a live tile on a 2-column grid —
  all agents visible at once, transcripts scrolling. **Click a tile** (or
  double-click a pool row) to expand that chat into the main ChatGPT-style
  stage: full-size transcript with the composer beneath, live state in the
  header, `<< Desktop` collapses back to the grid.
- The composer targets the expanded/selected soul; tick **Broadcast** to reach
  every soul (with **Optimize: idle only** to skip the busy and the dead).

## Tool-callable: HTTP API + MCP

While the console is open it serves a loopback JSON API (port 8720, falls forward if
busy) — same operations as the GUI:

```
GET  /health                    GET  /souls
POST /spawn                     {"name","type":"cli|ssh|agent","command","url","model","key","host"}
POST /whisper                   {"target","text"}
POST /broadcast                 {"text"}
GET  /transcript/<name>         POST /heal {"name"?}   POST /stop {"name"?}
POST /reap {"name"}             GET  /models?url=&key=
GET  /events?since=N            POST /mcp/add {"name","command"}
GET  /mcp/servers               POST /mcp/call {"server","tool","arguments"}
POST /mcp/remove {"name"}
```

The bus: every console event (spawned, whispers, answers, deaths, heals,
stops, mcp adds/calls) is sequenced in a 500-deep ring — poll `/events?since=<seq>`
incrementally, or read the whole ring with `since=0`.

## Tailnet access

```
tailscale serve --bg 8720     # → https://rog.tailbd5ccd.ts.net/
```

Any device logged into the tailnet reaches the console at that HTTPS URL
(verified from lappy-ubuntu). The MCP bridge points at it with
`NECRO_API_HOST=rog.tailbd5ccd.ts.net` (it switches to https for `*.ts.net`).
Ant souls hold the same power natively: the `console` tool lets a soul list,
whisper, spawn, heal, stop or reap other souls — recursion law: up to 3
summons per ant, depth 3 max (**1 original + 3 mid + 9 leaf**), enforced
console-side in `api_necro_for`.

`mcp/mcp_stdio.py` is a zero-dependency MCP stdio bridge exposing those as **10
`necro_*` tools**. Registered user-scope:

```
claude mcp add --scope user necromancer -- python C:/Users/aaron/nm_agent/mcp/mcp_stdio.py
```

Start the console GUI first; the tools fail with a clear "console not running"
message otherwise. Keys never transit the bridge.

## Credits

- `ant.gd` ports [Sentdex/minion](https://github.com/Sentdex/minion) (MIT).
- Icons: [Kenney Game Icons](https://kenney.nl/assets/game-icons) White 2x (CC0).
- Markdown: [daenvil/MarkdownLabel](https://github.com/daenvil/MarkdownLabel) (MIT).
- Canon art by the owner — click the header banner for full pieces (`art/LICENSES.md`).

## GMP gates

```
GODOT --headless --path . --import
GODOT --headless --path . --script res://tests/test_console.gd   # x2, exit 0
```

Spec: `spec/jam_spec.json` · Ledger: `DIARY.md`
