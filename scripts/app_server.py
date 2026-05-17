#!/usr/bin/env python3
import json
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

import refresh_data


ROOT = Path(__file__).resolve().parents[1]
HOST = "127.0.0.1"
PORT = 5174

sync_lock = threading.RLock()
sync_state = {
    "running": False,
    "stage": "idle",
    "message": "Ready",
    "result": None,
    "error": None,
}


def metadata_payload():
    return refresh_data.read_metadata()


def update_sync(stage, message):
    with sync_lock:
        sync_state["stage"] = stage
        sync_state["message"] = message


def run_sync_job():
    try:
        result = refresh_data.sync_if_needed(update_sync)
        with sync_lock:
            sync_state["result"] = {
                "refreshed": result["refreshed"],
                "metadata": result["metadata"],
                "watermark": result["watermark"],
            }
            sync_state["error"] = None
    except Exception as error:
        with sync_lock:
            sync_state["stage"] = "error"
            sync_state["message"] = str(error)
            sync_state["error"] = str(error)
    finally:
        with sync_lock:
            sync_state["running"] = False


class AppHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def is_uncached_path(self):
        path = urlparse(self.path).path
        return (
            path in {"/", "/index.html"}
            or path.startswith("/src/")
            or path.startswith("/data/")
            or path.startswith("/api/")
        )

    def end_headers(self):
        if self.is_uncached_path():
            self.send_header("Cache-Control", "no-store, max-age=0, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
        super().end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/sync/status":
            self.write_json({
                "sync": current_sync_state(),
                "metadata": metadata_payload(),
            })
            return
        self.disable_conditional_cache()
        super().do_GET()

    def do_HEAD(self):
        self.disable_conditional_cache()
        super().do_HEAD()

    def disable_conditional_cache(self):
        if not self.is_uncached_path():
            return
        for header in ("If-Modified-Since", "If-None-Match"):
            if header in self.headers:
                del self.headers[header]

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/api/sync":
            self.send_error(404)
            return

        with sync_lock:
            if sync_state["running"]:
                self.write_json({"sync": current_sync_state()}, status=202)
                return
            sync_state.update({
                "running": True,
                "stage": "queued",
                "message": "Starting BigQuery sync...",
                "result": None,
                "error": None,
            })

        thread = threading.Thread(target=run_sync_job, daemon=True)
        thread.start()
        self.write_json({"sync": current_sync_state()}, status=202)

    def write_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def current_sync_state():
    with sync_lock:
        return dict(sync_state)


def main():
    server = ThreadingHTTPServer((HOST, PORT), AppHandler)
    print(f"Serving ServiceOS Promises at http://{HOST}:{PORT}/")
    print("Sync endpoint available at /api/sync")
    server.serve_forever()


if __name__ == "__main__":
    main()
