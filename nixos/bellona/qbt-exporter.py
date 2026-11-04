#!/usr/bin/env python3
"""tiny qBittorrent prometheus exporter.

nixpkgs has no qbittorrent exporter package and the box has no docker, so this
scrapes the local qBittorrent API and prints prometheus text. qBittorrent's web
UI is loopback-only and skips auth from localhost, so no credentials here.
"""
import urllib.request
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

QBT = "http://127.0.0.1:8080"


def get(path):
    with urllib.request.urlopen(QBT + path, timeout=4) as r:
        return json.load(r)


def collect():
    lines = []
    try:
        info = get("/api/v2/transfer/info")
        torrents = get("/api/v2/torrents/info")
        lines.append("# HELP qbittorrent_up qBittorrent API reachable")
        lines.append("# TYPE qbittorrent_up gauge")
        lines.append("qbittorrent_up 1")
        for name, key, help_ in [
            ("qbittorrent_download_bytes_total", "dl_info_data", "all-time downloaded bytes"),
            ("qbittorrent_upload_bytes_total", "up_info_data", "all-time uploaded bytes"),
            ("qbittorrent_download_speed_bytes", "dl_info_speed", "current download speed"),
            ("qbittorrent_upload_speed_bytes", "up_info_speed", "current upload speed"),
        ]:
            lines.append(f"# HELP {name} {help_}")
            lines.append(f"# TYPE {name} gauge")
            lines.append(f"{name} {float(info.get(key, 0))}")
        states = {}
        for t in torrents:
            states[t.get("state", "unknown")] = states.get(t.get("state", "unknown"), 0) + 1
        lines.append("# HELP qbittorrent_torrents torrents by state")
        lines.append("# TYPE qbittorrent_torrents gauge")
        for state, count in states.items():
            lines.append(f'qbittorrent_torrents{{state="{state}"}} {count}')
        lines.append("# HELP qbittorrent_torrents_total total torrents")
        lines.append("# TYPE qbittorrent_torrents_total gauge")
        lines.append(f"qbittorrent_torrents_total {len(torrents)}")
    except Exception:
        lines = [
            "# HELP qbittorrent_up qBittorrent API reachable",
            "# TYPE qbittorrent_up gauge",
            "qbittorrent_up 0",
        ]
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path.split("?", 1)[0] != "/metrics":
            self.send_error(404)
            return
        body = collect().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 9877), Handler).serve_forever()
