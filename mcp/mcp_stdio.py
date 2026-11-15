#!/usr/bin/env python3
"""NecroMancer console - MCP stdio bridge.

A Model Context Protocol server speaking newline-delimited JSON-RPC 2.0
over stdio. Python 3.13 standard library only (sys/json/os/re/urllib) -
zero third-party dependencies.

Every tool is a thin proxy to the NecroMancer console's local HTTP JSON
API. Base URL: http://127.0.0.1:<port>, port from env NECRO_API_PORT
(default 8720).

Diagnostics go to stderr only; stdout carries protocol messages, one
compact JSON object per line. On EOF or broken pipe the server exits 0.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "necromancer-console"
SERVER_VERSION = "1.0.0"
HTTP_TIMEOUT = 30
DEFAULT_PORT = "8720"
DEFAULT_AGENT_URL = "http://192.168.0.33:8180/v1"
CONSOLE_DOWN = (
    "console not running — start the NecroMancer console GUI "
    "(it serves the API on the port above)"
)


def _api_base():
    port = (os.environ.get("NECRO_API_PORT") or DEFAULT_PORT).strip() or DEFAULT_PORT
    host = (os.environ.get("NECRO_API_HOST") or "127.0.0.1").strip() or "127.0.0.1"
    return "http://" + host + ":" + port


def _log(msg):
    sys.stderr.write("necromancer-console: %s\n" % msg)
    sys.stderr.flush()


TOOLS = [
    {
        "name": "necro_health",
        "description": "Console heartbeat: soul counts and states.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_souls_list",
        "description": "List every soul: name, kind (cli or agent), state (idle/busy/dead), queued count.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_spawn",
        "description": "Summon a new soul into the pool.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Soul name."},
                "type": {
                    "type": "string",
                    "enum": ["cli", "ssh", "agent"],
                    "description": "Soul kind.",
                },
                "command": {
                    "type": "string",
                    "description": "cli/ssh command line; {prompt} marks where the message goes.",
                },
                "url": {
                    "type": "string",
                    "description": "agent base URL (default llama-swap " + DEFAULT_AGENT_URL + ").",
                },
                "model": {
                    "type": "string",
                    "description": "agent model (default walker-duo).",
                },
                "key": {"type": "string", "description": "agent API key."},
                "host": {
                    "type": "integer",
                    "description": "ssh host index: 0=Lappy, 1=Ryan.",
                },
            },
            "required": ["name", "type"],
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_whisper",
        "description": "Send a message to one soul by exact name; auto-revives dead souls.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Message to deliver."},
                "target": {"type": "string", "description": "Exact soul name."},
            },
            "required": ["text", "target"],
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_broadcast",
        "description": "Whisper to every soul in the pool.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Message to deliver to all souls."},
            },
            "required": ["text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_transcript",
        "description": "Read a soul's transcript (events oldest-first).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Exact soul name."},
                "limit": {
                    "type": "integer",
                    "description": "Max events returned (default 50).",
                    "default": 50,
                },
            },
            "required": ["name"],
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_heal",
        "description": "Revive dead souls. Omit name to heal all.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Soul to heal; omit to heal all."},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_stop",
        "description": "Halt work. Omit name to stop all souls. Cancellation is not death.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Soul to stop; omit to stop all."},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_reap",
        "description": "Banish a soul from the pool permanently.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Exact soul name to banish."},
            },
            "required": ["name"],
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_models",
        "description": "List the models an endpoint offers (GET /models). Defaults to llama-swap.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "Endpoint base URL (default llama-swap " + DEFAULT_AGENT_URL + ").",
                },
                "key": {
                    "type": "string",
                    "description": "API key (sent only if non-empty).",
                },
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_events",
        "description": "Read the console's full signal bus: every soul event (spawned, whispers, answers, deaths, heals, stops, reaps) newest-last, incrementally via since.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "since": {
                    "type": "integer",
                    "description": "Sequence number to read from (0 = whole ring). Pass the returned next value for incremental reads.",
                },
                "limit": {
                    "type": "integer",
                    "description": "Max events returned (default 100, newest kept).",
                },
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_mcp_add",
        "description": "MCP adder: register an MCP stdio server (spawn its command, initialize handshake, list its tools) into the console.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Local name for the server."},
                "command": {"type": "string", "description": "Command line that launches the MCP server (stdio)."},
            },
            "required": ["name", "command"],
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_mcp_servers",
        "description": "List registered MCP servers and the tools each offers.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_mcp_call",
        "description": "Call a tool on a registered MCP server through the console.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "server": {"type": "string", "description": "Registered server name."},
                "tool": {"type": "string", "description": "Tool name on that server."},
                "arguments": {
                    "type": "object",
                    "description": "Arguments for the tool call.",
                },
            },
            "required": ["server", "tool"],
            "additionalProperties": False,
        },
    },
    {
        "name": "necro_mcp_remove",
        "description": "Kill and unregister an MCP server.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Registered server name."},
            },
            "required": ["name"],
            "additionalProperties": False,
        },
    },
]


def _http(method, path, body=None, query=None):
    """One request to the console API. Returns (body_text, None) or (None, error_text)."""
    url = _api_base() + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.read().decode("utf-8", "replace"), None
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read().decode("utf-8", "replace").strip()
        except Exception:
            detail = ""
        return None, "HTTP %s from %s: %s" % (exc.code, path, detail or exc.reason)
    except urllib.error.URLError as exc:
        reason = getattr(exc, "reason", None)
        text = str(reason or "").lower()
        if isinstance(reason, TimeoutError) or "timed out" in text:
            return None, "console request timed out after %ss: %s" % (HTTP_TIMEOUT, reason)
        return None, CONSOLE_DOWN
    except (TimeoutError, OSError) as exc:
        return None, "console request failed: %s" % exc


def _safe_json(raw):
    """Parse a JSON body; returns the value or None for non-JSON."""
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        return None


def _pretty(raw):
    """Re-render a JSON body readable; pass through anything that is not JSON."""
    try:
        return json.dumps(json.loads(raw), indent=2)
    except (ValueError, TypeError):
        return raw


def _trim_transcript(raw, limit):
    """Keep only the LAST `limit` events of a transcript JSON body."""
    try:
        limit = int(limit)
    except (TypeError, ValueError):
        return raw
    if limit <= 0:
        return raw
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return raw
    if not isinstance(data, dict):
        return raw
    events = data.get("events")
    if isinstance(events, list) and len(events) > limit:
        data["events"] = events[-limit:]
    return json.dumps(data)


def _text_result(text, is_error=False):
    result = {"content": [{"type": "text", "text": text}]}
    if is_error:
        result["isError"] = True
    return result


def _tool_call(name, args):
    """Execute one tool against the console API. Always returns a result dict."""
    body = None
    err = None
    try:
        if name == "necro_health":
            body, err = _http("GET", "/health")
        elif name == "necro_souls_list":
            body, err = _http("GET", "/souls")
        elif name == "necro_spawn":
            body, err = _http("POST", "/spawn", body=dict(args))
        elif name == "necro_whisper":
            body, err = _http(
                "POST",
                "/whisper",
                body={"text": args.get("text", ""), "target": args.get("target", "")},
            )
        elif name == "necro_broadcast":
            body, err = _http("POST", "/broadcast", body={"text": args.get("text", "")})
        elif name == "necro_transcript":
            path = "/transcript/" + urllib.parse.quote(str(args.get("name", "")), safe="")
            body, err = _http("GET", path)
            if body is not None and "limit" in args:
                body = _trim_transcript(body, args["limit"])
        elif name == "necro_heal":
            payload = {"name": args["name"]} if "name" in args else {}
            body, err = _http("POST", "/heal", body=payload)
        elif name == "necro_stop":
            payload = {"name": args["name"]} if "name" in args else {}
            body, err = _http("POST", "/stop", body=payload)
        elif name == "necro_reap":
            body, err = _http("POST", "/reap", body={"name": args.get("name", "")})
        elif name == "necro_models":
            query = {"url": args.get("url") or DEFAULT_AGENT_URL}
            key = args.get("key") or ""
            if key:
                query["key"] = key
            body, err = _http("GET", "/models", query=query)
        elif name == "necro_events":
            query = {}
            if "since" in args:
                query["since"] = args["since"]
            body, err = _http("GET", "/events", query=query)
            if err is None:
                parsed = _safe_json(body)
                if isinstance(parsed, dict) and isinstance(parsed.get("events"), list):
                    limit = args.get("limit", 100)
                    try:
                        limit = max(1, int(limit))
                    except (TypeError, ValueError):
                        limit = 100
                    if len(parsed["events"]) > limit:
                        parsed["events"] = parsed["events"][-limit:]
                        parsed["truncated"] = True
                    body = json.dumps(parsed)
        elif name == "necro_mcp_add":
            body, err = _http("POST", "/mcp/add", body={
                "name": args.get("name", ""),
                "command": args.get("command", ""),
            })
        elif name == "necro_mcp_servers":
            body, err = _http("GET", "/mcp/servers")
        elif name == "necro_mcp_call":
            body, err = _http("POST", "/mcp/call", body={
                "server": args.get("server", ""),
                "tool": args.get("tool", ""),
                "arguments": args.get("arguments", {}),
            })
        elif name == "necro_mcp_remove":
            body, err = _http("POST", "/mcp/remove", body={"name": args.get("name", "")})
        else:
            return _text_result("unknown tool: %s" % name, is_error=True)
    except Exception as exc:  # never let one call kill the server
        return _text_result("tool %s failed: %s" % (name, exc), is_error=True)
    if err is not None:
        return _text_result(err, is_error=True)
    return _text_result(_pretty(body))


def _handle(msg):
    """Handle one decoded JSON-RPC message. Returns a response dict or None."""
    if not isinstance(msg, dict) or "id" not in msg:
        return None  # notification or non-request: never answered
    rid = msg.get("id")
    method = msg.get("method")
    params = msg.get("params")
    if not isinstance(params, dict):
        params = {}
    if method == "initialize":
        result = {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        }
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        args = params.get("arguments")
        if not isinstance(args, dict):
            args = {}
        result = _tool_call(params.get("name"), args)
    elif method == "ping":
        result = {}
    else:
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "error": {"code": -32601, "message": "method not found"},
        }
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def _salvage_id(line):
    """Best-effort id extraction from a malformed line, else None."""
    match = re.search(
        r'"id"\s*:\s*(-?\d+|"(?:[^"\\]|\\.)*"|\btrue\b|\bfalse\b|\bnull\b)', line
    )
    if not match:
        return None
    try:
        return json.loads(match.group(1))
    except ValueError:
        return None


def _write(obj):
    """One compact JSON line to stdout. False on broken pipe."""
    try:
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        return True
    except (BrokenPipeError, OSError):
        return False


def main():
    _log(
        "MCP stdio server ready (tools=%d, console API=%s)"
        % (len(TOOLS), _api_base())
    )
    while True:
        try:
            line = sys.stdin.readline()
        except (KeyboardInterrupt, EOFError, OSError):
            break
        if not line:  # EOF
            break
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            rid = _salvage_id(line)
            if rid is not None:
                if not _write(
                    {
                        "jsonrpc": "2.0",
                        "id": rid,
                        "error": {"code": -32700, "message": "parse error"},
                    }
                ):
                    break
            else:
                _log("skipped malformed line: %r" % line[:120])
            continue
        try:
            resp = _handle(msg)
        except Exception as exc:
            _log("handler error: %r" % exc)
            if isinstance(msg, dict) and "id" in msg:
                resp = {
                    "jsonrpc": "2.0",
                    "id": msg["id"],
                    "error": {"code": -32603, "message": "internal error"},
                }
            else:
                resp = None
        if resp is not None and not _write(resp):
            break  # broken pipe
    _log("stdin closed, exiting 0")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
