#!/usr/bin/env python3
"""Minimal stdio MCP server for gate tests: initialize + tools/list (one
echo tool) + tools/call. Stdlib only; exits when stdin closes."""
import sys
import json


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "mock-mcp", "version": "1.0.0"},
        }})
    elif method == "notifications/initialized":
        pass
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{
            "name": "mock_echo",
            "description": "Echoes the given text back.",
            "inputSchema": {
                "type": "object",
                "properties": {"text": {"type": "string"}},
                "required": ["text"],
            },
        }]}})
    elif method == "tools/call":
        args = msg.get("params", {}).get("arguments", {})
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{
            "type": "text",
            "text": "mock says: " + str(args.get("text", "")),
        }]}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
