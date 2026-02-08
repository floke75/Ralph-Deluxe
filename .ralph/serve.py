#!/usr/bin/env python3
"""
serve.py — HTTP server for the Ralph Deluxe operator dashboard.

PURPOSE: Bridges the dashboard UI (dashboard.html) to the orchestrator's file-based
control plane. Serves static files from the project root and exposes two POST endpoints
for dashboard-to-orchestrator communication.

ARCHITECTURE:
  dashboard.html (browser) → HTTP POST → serve.py → writes files → orchestrator reads files
  orchestrator writes state/handoffs → serve.py serves as static files → dashboard polls

ENDPOINTS:
    GET  /*              — Static file serving from project root
    POST /api/command    — Enqueue operator command to .ralph/control/commands.json
    POST /api/settings   — Update whitelisted settings in .ralph/config/ralph.conf

CONCURRENCY SAFETY:
  The orchestrator and this server may access the same files concurrently.
  All writes use atomic write-to-temp-then-rename (via atomic_write()) to prevent
  the orchestrator from reading partially-written files.

SECURITY:
  - Settings updates are restricted to ALLOWED_SETTINGS whitelist
  - Setting values must match ^[a-zA-Z0-9_-]+$ (no injection risk)
  - Binds to 127.0.0.1 by default (no external access)

DEPENDENCIES:
    Read by: dashboard.html (polls every 3s)
    Writes: .ralph/control/commands.json (operator commands for telemetry.sh to process)
            .ralph/config/ralph.conf (settings updates)
    Reads: project root directory tree (static file serving)
"""

import argparse
import json
import os
import re
import sys
import tempfile
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path


# Resolve project root: serve.py lives at .ralph/serve.py, so root is parent
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
CONTROL_FILE = SCRIPT_DIR / "control" / "commands.json"
CONFIG_FILE = SCRIPT_DIR / "config" / "ralph.conf"


def atomic_write(filepath: Path, data: str) -> None:
    """Write data atomically via temp-file-then-rename.

    WHY: The orchestrator reads commands.json and ralph.conf at arbitrary times.
    Without atomicity, it could read a half-written file and crash or misbehave.
    os.replace() is atomic on POSIX systems within the same filesystem.
    """
    filepath.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=filepath.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.replace(tmp_path, filepath)
    except Exception:
        os.unlink(tmp_path)
        raise


def enqueue_command(command_obj: dict) -> dict:
    """Append an operator command to the pending queue in commands.json.

    The orchestrator's telemetry.sh process_control_commands() reads and clears
    this queue at the top of each main loop iteration. Supported commands:
    pause, resume, inject-note, skip-task.

    SIDE EFFECT: Mutates .ralph/control/commands.json on disk.
    """
    CONTROL_FILE.parent.mkdir(parents=True, exist_ok=True)

    # Read current state
    if CONTROL_FILE.exists():
        with open(CONTROL_FILE, "r") as f:
            control = json.load(f)
    else:
        control = {"pending": []}

    if "pending" not in control:
        control["pending"] = []

    control["pending"].append(command_obj)

    atomic_write(CONTROL_FILE, json.dumps(control, indent=2) + "\n")
    return control


def update_settings(settings: dict) -> dict:
    """Update whitelisted settings in ralph.conf via regex line replacement.

    Only settings in ALLOWED_SETTINGS can be modified (prevents arbitrary config
    injection). Values are sanitized to alphanumeric + hyphens + underscores.

    SIDE EFFECT: Mutates .ralph/config/ralph.conf on disk.
    CALLER: Dashboard settings panel via POST /api/settings.
    """
    if not CONFIG_FILE.exists():
        return {"error": "ralph.conf not found"}

    with open(CONFIG_FILE, "r") as f:
        content = f.read()

    # Whitelist: only these settings can be changed from the dashboard
    ALLOWED_SETTINGS = {
        "RALPH_VALIDATION_STRATEGY",
        "RALPH_COMPACTION_INTERVAL",
        "RALPH_COMPACTION_THRESHOLD_BYTES",
        "RALPH_DEFAULT_MAX_TURNS",
        "RALPH_MIN_DELAY_SECONDS",
        "RALPH_MODE",
    }

    updated = []
    for key, value in settings.items():
        if key not in ALLOWED_SETTINGS:
            continue
        # Sanitize: reject values that could inject shell syntax
        safe_value = str(value)
        if not re.match(r'^[a-zA-Z0-9_\-]+$', safe_value):
            continue
        # Replace existing line (must already exist in config)
        pattern = re.compile(rf'^({re.escape(key)}=).*$', re.MULTILINE)
        if pattern.search(content):
            content = pattern.sub(rf'\g<1>"{safe_value}"', content)
            updated.append(key)

    if updated:
        atomic_write(CONFIG_FILE, content)

    return {"updated": updated}


class RalphHandler(SimpleHTTPRequestHandler):
    """HTTP handler: serves static files from project root + API endpoints.

    Static serving lets the dashboard poll state.json, plan.json, handoffs/,
    events.jsonl, progress-log.json directly as files.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(PROJECT_ROOT), **kwargs)

    def do_POST(self):
        if self.path == "/api/command":
            self._handle_command()
        elif self.path == "/api/settings":
            self._handle_settings()
        else:
            self.send_error(404, "Not Found")

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw)

    def _send_json(self, status: int, data: dict):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        """Handle CORS preflight requests (dashboard may run on different port)."""
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def _handle_command(self):
        try:
            body = self._read_body()
            if "command" not in body:
                self._send_json(400, {"error": "Missing 'command' field"})
                return
            result = enqueue_command(body)
            self._send_json(200, {"ok": True, "pending_count": len(result["pending"])})
        except json.JSONDecodeError:
            self._send_json(400, {"error": "Invalid JSON"})
        except Exception as e:
            self._send_json(500, {"error": str(e)})

    def _handle_settings(self):
        try:
            body = self._read_body()
            if not body:
                self._send_json(400, {"error": "Empty body"})
                return
            result = update_settings(body)
            self._send_json(200, {"ok": True, **result})
        except json.JSONDecodeError:
            self._send_json(400, {"error": "Invalid JSON"})
        except Exception as e:
            self._send_json(500, {"error": str(e)})

    def log_message(self, format, *args):
        """Suppress static file request logging; only log API calls."""
        if self.path.startswith("/api/"):
            sys.stderr.write(f"[ralph-serve] {self.address_string()} {format % args}\n")


def main():
    parser = argparse.ArgumentParser(description="Ralph Deluxe dashboard server")
    parser.add_argument("--port", type=int, default=8080, help="Port to listen on")
    parser.add_argument("--bind", default="127.0.0.1", help="Address to bind to")
    args = parser.parse_args()

    os.chdir(PROJECT_ROOT)

    server = HTTPServer((args.bind, args.port), RalphHandler)
    print(f"Ralph Deluxe server running at http://{args.bind}:{args.port}/")
    print(f"Dashboard: http://{args.bind}:{args.port}/.ralph/dashboard.html")
    print(f"Project root: {PROJECT_ROOT}")
    print("Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()


if __name__ == "__main__":
    main()
