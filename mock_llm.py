#!/usr/bin/env python3
"""Minimal OpenAI-compatible mock used to exercise the agent loop end-to-end."""
import json, http.server, socketserver, sys, os

CALLS = 0
SCRIPT = []  # list of (name, args) per turn

def load_script():
    global SCRIPT
    p = os.environ.get("MOCK_SCRIPT", "script.json")
    with open(p) as f:
        SCRIPT = json.load(f)

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_POST(self):
        global CALLS
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        load_script()
        msgs = body.get("messages", [])
        tool_msgs = [m for m in msgs if m.get("role") == "tool"]

        idx = len(tool_msgs)
        if idx < len(SCRIPT):
            step = SCRIPT[idx]
            msg = {
                "role": "assistant",
                "content": step.get("content"),
                "tool_calls": [{
                    "id": f"call_{idx}",
                    "type": "function",
                    "function": {"name": step["name"], "arguments": json.dumps(step.get("args", {}))}
                }]
            }
            finish = "tool_calls"
        else:
            msg = {"role": "assistant", "content": "DONE: all steps executed."}
            finish = "stop"

        resp = {
            "id": "chatcmpl-mock", "object": "chat.completion", "created": 0,
            "model": body.get("model", "mock"),
            "choices": [{"index": 0, "message": msg, "finish_reason": finish}],
            "usage": {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120},
        }
        out = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8971
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", port), H) as httpd:
        print(f"mock llm on {port}", flush=True)
        httpd.serve_forever()
