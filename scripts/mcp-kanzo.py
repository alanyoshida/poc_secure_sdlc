#!/usr/bin/env python3
# Cliente MCP minimo para o Kanzo via HTTP (change kanban-agent).
# Uso: mcp-kanzo.py <tool> [json-args]   (args como objeto JSON)
# Ex.: mcp-kanzo.py list_projects
#      mcp-kanzo.py list_tasks '{"filter":"status:todo","project":"agent-workspace"}'
# Cada invocacao faz o handshake initialize + tools/call (stateless).
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("KANZO_MCP_URL", "http://localhost:4242/mcp")


def post(payload, session=None):
    # O Kanzo valida o header Host (anti DNS-rebinding) e so aceita o seu
    # endereco local; clientes remotos spoofam o Host.
    req = urllib.request.Request(BASE, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    req.add_header("Host", "localhost:4242")
    if session:
        req.add_header("mcp-session-id", session)
    with urllib.request.urlopen(req, json.dumps(payload).encode(), timeout=60) as r:
        sid = r.headers.get("mcp-session-id")
        raw = r.read().decode()
        return sid, raw


def parse(raw):
    for line in raw.splitlines():
        if line.startswith("data:"):
            line = line[5:].strip()
            if line:
                return json.loads(line)
    return json.loads(raw)


def call_tool(name, args):
    sid, raw = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "kanban-agent-loop", "version": "1.0"}}})
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    _, raw = post({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": name, "arguments": args}}, sid)
    result = parse(raw).get("result", {})
    # conteudo do tool: lista de {type: text, text: ...}
    texts = [c.get("text", "") for c in result.get("content", []) if c.get("type") == "text"]
    return "\n".join(texts)


def main():
    if len(sys.argv) < 2:
        print("uso: mcp-kanzo.py <tool> [json-args]", file=sys.stderr)
        return 1
    name = sys.argv[1]
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    print(call_tool(name, args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
