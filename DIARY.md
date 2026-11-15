# Ant's — DIARY

## FIX — nest node selection actually selects (2026-11-15)
- Found in the exit log of the API-test run: every nest-canvas node click
  spammed `node_selected … Method expected 1 argument(s), but called with 0`
  and `selected` never updated (broadcast/composer targeting degraded from
  the canvas). `GraphNode.node_selected` is a 0-arg signal in this build;
  the M7 lambda declared one.
- Fix: `agent_console.gd` lambda now takes no args (comment marks why) +
  console gate emits `node_selected` on a node and asserts the soul is
  targeted (50 → **51**). GATES ×2: console 51 · ant 59 · api 22 · bus 13 ·
  zero signal errors in the gate log.

## FIX — agent chat history now restores (2026-11-15)
- Owner report: "the agent chat is not bringing up the chat history." Root
  cause: ant sessions were SAVED to `user://ant/sessions/` but the payload had
  no soul name and the console never called `load_session` — every restart or
  re-summon started an agent chat from zero. The save/load plumbing existed
  since M2; only the console-side half was missing.
- Fix: `_save()` now writes `"name": soul_name`; Ant gained
  `latest_session_for(name)` (newest match — session ids are timestamps, so
  lexicographic = chronological) and `saved_transcript()` (user→"you",
  assistant text→"output"; system preambles, tool-call turns and tool results
  skipped). `_add_ant_soul` (the GUI+API spawn chokepoint) sets the name and
  restores the newest matching session into the panel with a
  "restored N messages" system line.
- Pre-fix session files (no name inside) stay orphans — unmappable. Two souls
  sharing a name share history by design. Restores happen at spawn only;
  live events can't race (no turn in flight yet).
- GATES ×2: ant **59** (6 new restore checks) · console 50 · api 22 · bus 13 ·
  boot clean.

## M7 — the nest map: an n8n-style node canvas (2026-11-15)
- Owner directive: "research n8n and lets make our desktop simmlar". The
  viewport-tile desktop became **the nest map** — a GraphEdit canvas
  (research first: n8n canvas anatomy + Godot GraphEdit API fit, both
  subagent-verified; GraphEdit's wires/pan/zoom/port-dots are native).
- **Agent node cards**: title = soul name, embedded **mini ChatPanel** = the
  soul's one-true transcript rendered INSIDE the card (the ComfyUI steal —
  the node is the live preview), a state dot + status line, and input/output
  port slots. SubViewports are gone — panels embed directly.
- **Wires = whisper pipes**: connection_request records
  `{from, from_port, to, to_port}` + a bus event; disconnection prunes;
  reaping a soul prunes its wires (reverse-iterate — removing while walking
  forward skips). Duplicate wires deduped.
- Interactions: double-click a node opens its chat page; right-click opens
  the per-soul menu (Stop/Heal/Reap/Broadcast); drag moves; GraphEdit zoom
  toolbar native. Dead nodes dim (modulate), state text updates per frame
  with change-detection. Dev affordance: `godot --path . -- nest` boots
  straight onto the canvas (desktop synthetic clicks are dead — Godot law).
- Gate lesson: GraphEdit.get_child_count() counts its INTERNAL controls —
  count your own node dict, not the tree.
- GATES (all ×2): console **49** (nest nodes, wire record, soul-meta checks)
  · ant 53 · api 22 · bus 13 · boot clean. Visual: docs/m7_nest_canvas.png.

## M6 — llama.cpp in the APK + the on-device speed numbers (2026-11-15)
- **llama.cpp runs on the phone.** Built master (32bdc3a) for arm64-v8a with
  NDK r26.3: static `llama-cli` (20.5MB, `-march=armv8.2-a+dotprod -g0`) and
  shared libs (libllama/libggml/libggml-cpu/libggml-base ≈ 8.6MB) for the APK.
- **The JNI bridge**: `thirdparty/llama-jni/llama_jni.c` (load/complete/perf/
  free; greedy or temp sampling; batched prefill; llama_detokenize — the
  detokenize SAMPLER doesn't exist in this header) wrapped as a second v2
  plugin class `LlamaBridge` inside the PyBridge AAR; jniLibs auto-packaged.
  Ant gained the `run_local` tool (Android: LlamaBridge singleton, model from
  `user://llama_load_model.gguf`; desktop reports honestly). Gates stayed
  green: console 47 · ant 53 · api 22 · bus 13 ×2, boot clean.
- **Speed protocol results** (5B Q4_K_M, temp 0, -n 128, -t 4, ctx 4096, 3
  runs): generation **7.0 tok/s** (7.2/6.9/6.9), prefill 127 tok/s (600-tok
  prompt; 40-72 on short), load ~4.5s from storage, **~4.1GB RSS** (includes
  the mmap'd weights). LAN leg Rog→:8477: **~87 tok/s** (128-tok reply in
  1.5s), first token <100ms warm. Verdict for the owner: **hybrid — LAN
  default, device fallback**; RAM is the bigger phone constraint than 7 tok/s.
- **Speed research applied** (subagent, 2025-26 sources): KleidiAI kernels
  (~2× prefill; `-DGGML_CPU_KLEIDIAI=ON -DGGML_CPU_ARM_ARCH=...+i8mm+fp16`),
  big-core pinning (`--cpu-range 4-7`, decode wins), Q4_0 auto-repack
  (fastest ARM quant, quantize on-device), prompt-cache reuse for TTFT;
  speculative decoding is a LOSS on CPU for general text — skip. KleidiAI
  llama-cli + llama-quantize built; on-phone re-test pending USB.
- Paid-for lessons: adb pushes need `MSYS_NO_PATHCONV=1` + Windows-style local
  paths (Git Bash rewrote `/data/...` into `C:/Program Files/Git/data/...`);
  the 2.83GB model streams into app storage via `adb shell cat | run-as tee`
  in 18s; Rog's 476GB disk hit 25MB free mid-export (cleaned ~2.6GB: old
  APKs, gradle intermediates, Temp-minus-claude, and the gradle caches —
  which broke a live daemon's metadata until `gradlew --stop` + re-purge).

## M5b — the chat page slide finally opens (2026-11-15)
- Four phone build cycles to find it: the chat page rendered NOTHING on tap
  while every gate stayed green. Root cause: **pages are never `visible =
  false` — they are parked offscreen**, so `_stage.visible` was true from
  boot and the `if not was_visible: slide-in` branch never ran. The
  always-animate fix (`_animate(_stage, _stage.offset_left, 0.0)`) works.
  The gates couldn't catch it: they assert flags, not animation.
- Second fix in the same chase: **SceneTree tweens never advanced on the
  Android build** (traced: page stuck at its offscreen offset) — slides are
  now driven from `_process` (`_advance_slides`, cubic ease-out by hand).
- Third: the chat page's bg ColorRect inside a VBox collapsed to zero height
  (lobby showed through) — the page is now a plain Control with anchored
  bands (bar TOP_WIDE@64, scroll 64..-76, input BOTTOM_WIDE@-76).
- Fourth: touches over the row's name area died on a PASS container under an
  IGNORE parent — `name_row.mouse_filter = IGNORE` lets hits fall through to
  the row Button.
- Debug lesson: Godot ignores injected clicks on desktop (mouse_event AND
  PostMessage-with-client-coords both tried) — UI reachability is proven by
  real touches on the phone or by gates, never by synthetic desktop input.

## M5 — the Telegram look: lobby + chat pages (2026-11-14)
- Owner pasted a Telegram-style reference UI and asked for the lobby + chat to
  look like it. Adopted wholesale: **540×960 portrait canvas** (canvas_items
  stretch, expand aspect), Telegram palette (0e1621 / 17212b / 2aabee accent),
  safe-area page placement, slide-in pages, Android back button.
- **Lobby page**: header bar (title + "+" summon + "…" menu), "Search souls"
  pill, avatar rows — colored circle avatar (per-soul color from name hash),
  state dot, name, last-message preview, timestamp, accent unread badge.
  Footer keeps the pool status line.
- **Chat page**: slide-in header ("‹" back, avatar, name, status line that
  doubles as the **typing indicator** — a busy soul shows "typing..."),
  Telegram bubbles (out 2b5278 / in 182533, radius 16, timestamps inside,
  MarkdownLabel bodies kept), per-chat input bar. "…" menu: Broadcast toggle,
  Optimize toggle, Stop / Heal / Reap.
- **Viewport desktop survives** as a second page (lobby "…" → "Viewport
  desktop"); tiles restyled; column count adapts to window width (1 on phone,
  up to 3 on wide desktops); a tile click opens that soul's chat page.
- Broadcast/Optimize checkboxes became state bools + checkable menu items.
- Gate lessons (paid for):
  1. `Label.icon` does not exist in Godot 4.7 — the state dot is a TextureRect.
  2. **`clip_text = true` zeroes a Label's minimum width** — in an HBox the
     label collapsed to 1px until given SIZE_EXPAND_FILL (clip inside the
     expanded slot instead).
  3. Avatar circles need `SIZE_SHRINK_CENTER` in a taller HBox or they render
     as ovals.
  4. Godot ignores PostMessage/synthetic mouse clicks (mouse_event and
     WM_LBUTTONDOWN both tried) — desktop UI must be driven by gates or real
     input; keyboard reached the GUI in earlier sessions.
- Disk-full lesson: a 476GB drive at 25MB free killed an export mid-strip
  ("There is not enough space on the disk"); cleaned ~2.6GB (old APKs, gradle
  intermediates, Temp minus the live claude folder). builds/ now .gdignore'd
  so Godot never imports screenshots as textures again.
- **scullm-q4 is the primary model** (owner directive via scullm-a0): console
  defaults flipped to :8477, endpoint list reordered (think twin :8478 added,
  llama-swap scullm entry queued), walker-duo demoted everywhere. Ant sends
  max_tokens=2048 on every turn now (scullm's ~1000-token reasoning preamble
  otherwise truncates real answers).
- GATES (all ×2): console **47** (8 new: search filter, chat page + avatar,
  typing indicator, unread badges open/closed, desktop page open/close) ·
  ant 53 · api 22 · bus 13 · boot `--quit-after 120` clean.

## M4 — CPython lives in the APK: PyBridge green on the phone (2026-11-14)
- **Chaquopy 17.2.0 (Python 3.13) embedded in the Android export** through the
  gradle build template: `id 'com.chaquo.python' version '17.2.0'` +
  `chaquopy { defaultConfig { version "3.13" } }`, abiFilters pinned
  arm64-v8a. Chaquopy is on Maven Central now (chaquo.com/maven is dead);
  the Java API is `com.chaquo.python.runtime:chaquopy_java:17.2.0`.
- **PyBridge** = Godot v2 Android plugin (no .gdap in 4.5+): AAR with manifest
  meta-data `org.godotengine.plugin.v2.PyBridge`, project side `plugin.cfg` +
  an @tool EditorPlugin registering an inner EditorExportPlugin whose
  `_get_android_libraries` returns the AAR path **relative to res://addons/**
  (`pybridge/libs/PyBridge-release.aar` — a leading addons/ doubles the path).
- **Ant's `run_python` tool** calls `Engine.get_singleton("PyBridge")` on
  Android; desktop degrades gracefully ("not available on this platform").
- THE BUG (three build cycles to root-cause): on-device exec raised
  `SystemError: frame does not exist`. Not a wiring failure — PyBridge was
  registered and reaching Python from turn one. Chaquopy's JNI shim has **no
  calling Python frame**, and bare `exec(code)` (and even
  `exec(compile(code))`) inherits the caller's frame → SystemError. Fix:
  pass an explicit globals dict — `exec(code, globals)` builds its own fresh
  module-level frame. The dict is kept across calls, so run_python state
  persists like REPL globals. Verified the rebuilt AAR via javap (the
  `globals` field proves the new code shipped).
- **Phone proof (USB, adb forward tcp:8721→8720)**: NVIDIA ant
  (minimax-m3.1-flash) summoned on the phone → native tool call
  `run_python` → Chaquopy executed `print("NECROMANCER MOBILE ONLINE")` +
  `print(6*7)` → transcript `[output] NECROMANCER MOBILE ONLINE\n42` →
  finished. Lobby preview line carries the output on-screen. Session JSON
  pulled via run-as; screencap `builds/phone_runpython_green.png`.
  (minimax 503s intermittently — one retry needed; transient catalog flake.)
- Android socket law (from the earlier forensics lane, kept): bind
  `"127.0.0.1"` explicitly — `TCPServer.listen(port, "")` fails everywhere
  because IPAddress("") is invalid; INTERNET permission set in the preset.
- GATES (all ×2 after the AAR swap): console **39** · ant **53** · api **22** ·
  bus **13** · boot `--quit-after 120` clean.

## M3.3c — markdown rendering + hardened expansion (2026-11-14)
- Vendored [daenvil/MarkdownLabel](https://github.com/daenvil/MarkdownLabel) (MIT)
  into `addons/markdownlabel/` — bubble bodies are now MarkdownLabel: agent
  replies render **bold**, lists, `code`, headers, links formatted. User bubbles
  and dim rows unchanged.
- Hardened expand/collapse: set_mini and _expand/_collapse bail on queued-for-
  deletion / freed panels (stray clicks after a Reap used to hit freed labels).
- Gate lesson: MarkdownLabel parses only once IN the tree — an out-of-tree
  instance returns empty get_parsed_text(). And ChatPanel v3's rewrite dropped
  `_log` while a later guard still referenced it — a dependency parse error that
  surfaces as "could not parse global class" in the consumer (same class of
  confusion as the ApiServer duplicate-var incident; grep first, always).
- GATES (all ×2): console **39** (markdown render + syntax-consumed checks)
  · ant 51 · api 22 · boot clean.

## M3.3b — OpenWebUI bubbles + chat lobby (2026-11-14)
- ChatPanel v3: real bubble rows (PanelContainer, rounded stylebox, autowrap,
  fixed column width) — **you** right-aligned accent bubbles, the soul left in
  dark bubbles with name · timestamp above; system/error/dead/heal stay dim
  lines. Mini tiles keep compact one-line rows; expanding rebuilds into full
  bubbles. bbcode `[table][cell bg=… radius=…]` bubbles were tried first and
  rendered LITERALLY (this RichTextLabel build rejects those cell attributes)
  — native Controls instead, zero bbcode risk.
- Chat lobby: pool rows now show a colored state dot (idle/busy/dead), live
  state, queue depth, and a **last-message preview** — ChatGPT-sidebar style.
- Drove the GUI via API only (owner watches the screen): whisper → bubble +
  lobby preview appeared; PowerShell SendKeys expanded the chat (Enter fires
  `item_activated`) to verify the bubble layout visually.
- GATES (all ×2): console 37 · ant 51 · api 22 · boot clean.

## M3.3 — the viewport desktop (ChatGPT-style chats, 2026-11-14)
- Right side rebuilt: the main area is now a **viewport desktop** — every soul's
  chat lives in its own SubViewport tile (380×230, 2-column grid), transcripts
  scrolling live. **Click a tile (or double-click a pool row)** and that chat
  expands into the main ChatGPT-style stage: full-size transcript + composer
  beneath, header showing name/state live, `<< Desktop` button collapses back.
- One-transcript-per-soul: `chat_panel.gd` (ChatPanel) holds the real log; the
  desktop tile and the expanded stage are the same node re-parented — nothing
  duplicated, mini tiles read at 12px, expanded at 16px. Composer stays global
  (targets the expanded/selected soul; broadcast + idle-only optimize apply).
- Old single `_chat` label + `_redraw`/`_write` removed; Reap and the API share
  `_teardown_soul` (collapse-if-expanded → free panel+tile → shutdown).
- Gate lesson: ItemList has NO `item_double_clicked` signal — double-click is
  `item_activated`. The missed signal aborted _ready silently (no UI, no seeds,
  confusing downstream Nils) — check the log head before theorizing.
- GATES (all ×2): console **37** (4 new: 3 viewports on boot, expand → stage,
  desktop hidden while expanded, collapse returns) · ant 51 · api 22 · boot clean.

## M3.2 — tailnet access + full signal bus + MCP adder + the Orchestrator law (2026-11-14)
- **Tailnet**: console API reachable at `https://rog.tailbd5ccd.ts.net/` via
  `tailscale serve --bg 8720` (verified from lappy-ubuntu over HTTPS). Direct
  Godot binds to the tailscale TUN address were attempted first and
  **hard-crashed the process** (Windows/TUN socket poll bug) — reverted; serve
  proxy is the blessed path. Bridge gained NECRO_API_HOST (https for .ts.net).
- **Full signal bus** (`event_bus.gd`): every event (spawned, whispers,
  answers, deaths, heals, stops, reaps, mcp_add/call/remove) flows through one
  chokepoint — Godot signals for in-app listeners + a 500-deep sequenced ring
  polled as `GET /events?since=<seq>`.
- **MCP adder**: `mcp_client.gd` — register any stdio MCP server by command
  (GUI "MCP" button / `POST /mcp/add`); initialize handshake + tools/list +
  tools/call through the console; bridge tools necro_mcp_add/servers/call/
  remove. LIVE: registered a mock server via MCP and called its tool through
  the visible window ("mock says: hello from the tailnet").
- **Orchestrator law** (owner decree): Ant gained the `console` tool —
  list / whisper / broadcast / spawn / transcript / heal / stop / reap — wired
  DIRECTLY to console api methods (a loopback HTTP self-call would deadlock:
  both run on the main thread). Recursion limits console-side in
  `api_necro_for(caller, args)`: **1 original + 3 mid + 9 leaf (3 each),
  depth-3 leaves cannot summon**; lineage `depth`/`children` on AntSoul; the
  law is stated in the tool description, the system prompt, and the depth-3
  denial line.
- GATES (all ×2): console 33 · ant 51 (recursion law + unwired-denial checks)
  · api 22 (adder + bus incremental reads) · boot clean. Bridge: 15 tools.
- Lesson (paid for): a misplaced Edit can wedge a duplicate `var` into the
  middle of `_ready` — the parse error surfaces as a confusing "could not
  parse global class" in the *consumer*; grep the file before theorizing.

## M3.1 — the Orchestrator law: ants command the pool (2026-11-14)
- Ant gained the `console` tool: list / whisper / broadcast / spawn / transcript /
  heal / stop / reap — wired DIRECTLY to the console's api methods via a callable,
  NOT loopback HTTP (API dispatch + Ant tools both run on the main thread; an HTTP
  self-call would deadlock until timeout).
- RECURSION LAW (owner decree): an ant may summon up to 3 ants, up to depth 3 —
  the full tree is **1 original + 3 mid ants + 9 leaf ants (3 each)**; depth-3
  leaves cannot summon. Limits live console-side in `api_necro_for(caller, args)`
  with `depth`/`children` lineage on AntSoul; the tool description and the system
  prompt both state the law, and depth-3 ants get an explicit denial line.
- `run_python` note: still desktop-off; the recursion tooling is pure GDScript +
  direct calls, so M2 gates carry it with no new walls.
- GATES: test_ant.gd **51 checks ×2** green (recursion law: depth-1 summons 3,
  4th hits budget, mid summons 3 leaves, leaves are depth 3, leaf summon denied,
  unwired ant reports "not wired") + console 33 ×2 + api 15 ×2 + boot clean.
  GUI relaunched, API live on :8720.

## M3 — tool-callable console: HTTP API + MCP bridge (2026-11-14)
- `api_server.gd`: loopback HTTP JSON API inside the console (threaded accept,
  deferred-to-main dispatch, port fallback 8720..8739 so gates/GUI never collide).
  Routes: /health /souls /spawn /whisper /broadcast /transcript/<name> /heal /stop
  /reap /models. Blank command via API = echo soul (console semantics).
- `mcp/mcp_stdio.py`: zero-dependency MCP stdio bridge (haiku lane, protocol-verified:
  initialize/tools/list/ping/-32601/-32700) exposing 10 necro_* tools over the API.
  Keys never transit it; NECRO_API_PORT env override.
- Registered: `claude mcp add --scope user necromancer` → ✔ Connected. LIVE tools/call
  drove the visible window: necro_spawn summoned mcp-demo, necro_whisper whispered it,
  necro_transcript read it back.
- GATES: test_api.gd 15 ×2 green (HTTP against the live console) + console 33 ×2 +
  ant 39 ×2 + boot clean. Lesson: `head` declared twice in one function = parse error
  that surfaces as a confusing "could not parse global class" in the consumer.
- Android (Chaquopy) shifts to M4.

## M2 — Ant API souls + art in the GUI (2026-11-14)
- `ant.gd`: owner-supplied port of Sentdex/minion (MIT) as class Ant — OpenAI-compatible
  tool loop, `[ant_tool_call]` text fallback, user://workspace file tools, sessions in
  user://ant/sessions/, run_python gated on the PyBridge singleton (Android). Additions:
  `activity` signal and `cancel()` with `_settled_once` dedup (cancel_request() emits
  nothing — caught in design review; without it Stop mid-turn would hang the pump).
- Soul base class: AgentWorker + AntSoul pooled as `Array[Soul]` (7 retype sites).
  Fan-out per owner order: ant.gd and ant_soul.gd by two haiku lanes, console by Muse,
  single-writer per file; both lanes' output reviewed and patched (SYSTEM/NUDGE prose
  restored to the owner's texts — the lane had models "call final_answer" in normal
  turns, where that tool doesn't exist).
- Honest API-soul semantics: DEAD = transport / 401 / 403 only; 5xx = error + idle;
  Stop = idle not death; Heal clears the mark; idle-only optimize + auto-revive apply.
- Console: soul-type spawn picker (Echo / CLI / SSH / Agent-API) with endpoint presets
  (llama-swap / OpenRouter / NVIDIA catalog — key runtime-only), canon-art banner
  (click = full-art dialog), Ant sigil strip in the pool, Kenney CC0 icons on every
  button (owner supplied the pack).
- Gate lessons paid for: StreamPeerTCP has `get_data`, not `get_bytes`; GDScript lambdas
  capture locals BY VALUE (reassign inside never propagates — mutate containers in
  place); a `| tail` pipe eats the gate's exit code; mock-server polls must ACCUMULATE
  drained events or a fast settle races the state flip; `--import` before every gate
  that adds class_names.
- GATES: test_console.gd 33 ×2 green · test_ant.gd 35 ×2 green · boot --quit-after 120
  clean, zero errors — with art + icons imported and exercised by every run.
- LIVE GREEN: NVIDIA catalog (integrate.api.nvidia.com, minimaxai/minimax-m3.1-flash)
  on the first run — real native write_file tool call, greeting.txt landed with a
  haiku, turn settled in ~40s. Manual script tests/manual_nvidia_live.gd (key via
  NM_NVAPI_KEY env, never in the repo). Endpoint presets expanded to all known lanes
  (llama-swap, dory, Ollama, local llama.cpp, OpenRouter, NVIDIA, z.ai).

## M1 — ssh souls (2026-11-14)
- Spawn dialog gained a **Run on** picker: Local CLI / Lappy / Ryan. A remote
  pick wraps the command as `ssh -o BatchMode=yes aaron@<host> "<cmd>"` — the
  whole remote command travels as one quoted arg to the remote shell.
- Key auth Rog→Lappy+Ryan was already live (BatchMode echo green on both);
  live fidelity check: the exact wrapped form ran on lappy-ubuntu.
- Local vs remote: remote commands go through the remote shell, so `&&` and
  pipes work inside ssh souls; inner double quotes break the wrap — single
  quotes only. BatchMode kills password prompts: a missing key dies fast with
  ssh's exit code instead of hanging.
- GATE: green ×2 — 33 checks (2 new: wrap format, splitter keeps the remote
  command as one arg).

## M0 — the circle is drawn (2026-11-13)
- Themed Godot 4 agent console per owner's NecroMancer key art: pool list with
  IDLE/BUSY/DEAD souls, séance transcript, broadcast, idle-only optimize,
  gothic purple theme; Spawn / Heal Dead / Stop / Reap / Stop All.
- Worker gained a real DEAD state: failed start or non-zero exit marks the soul
  dead (exit code surfaced via `OS.get_process_exit_code`); `revive()` +
  **Heal Dead** restore; whispering a dead soul auto-revives it (Repeat...).
- GATE: `tests/test_console.gd` green ×2 — 31 checks each run; boot
  `--quit-after 120` clean (exit 0, no errors).
- Two bugs found and fixed by the gate (paid-for lessons):
  1. `OS.execute_with_pipe` pipes NEVER signal EOF on Windows — stdio is a
     duplex pipe (the parent keeps its write handle) and with `blocking=false`
     even stderr never sets `eof_reached`. The original blocking read loop hung
     forever on any quiet or dead process. Every read loop is now non-blocking
     and death-based: poll lines, stop when the process is dead and the buffer
     is dry.
  2. Test-suite race: waiting for "idle" can pass before the worker thread even
     wakes (idle is the initial state). Waits for terminal states now wait for
     "busy" first.
- Haiku relay skipped (deliberate): owner supplied the complete base
  implementation inline; the milestone was a themed extension + death/heal
  loop, gated directly.
