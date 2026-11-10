#!/usr/bin/env python3
"""homelab summary API for Glance and the Noctalia widget.

Loopback/LAN only, bearer token for anything non-local. Every upstream call is
best-effort: a missing exporter or an unconfigured HA token yields null, never a
500.
"""
import json
import os
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

VM = "http://127.0.0.1:8428"
QBT = "http://127.0.0.1:8080"
HA = "http://127.0.0.1:8123"
TOKEN_FILE = "/run/agenix/homelab-api-token"
HA_TOKEN_FILE = "/run/agenix/ha-token"


def read(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


TOKEN = read(TOKEN_FILE)
HA_TOKEN = read(HA_TOKEN_FILE)


def get_json(url, headers=None, timeout=4):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def prom(query):
    try:
        data = get_json(VM + "/api/v1/query?" + urllib.parse.urlencode({"query": query}))
        result = data.get("data", {}).get("result", [])
        if not result:
            return None
        return float(result[0]["value"][1])
    except Exception:
        return None


def sparks():
    # phobos runs the EXL3/tensorfold build, whose Prometheus names are
    # `tensorfold:*`, not upstream vLLM's `vllm:*`. kv_cache_usage_ratio is the
    # 0-1 form (there is also a `_perc` that is already 0-100).
    gpu = prom("sum(tensorfold:kv_cache_usage_ratio)")
    reqs = prom("sum(tensorfold:num_requests_running)")
    tok = prom("sum(rate(tensorfold:generation_tokens_total[5m]))")
    out = []
    if gpu is not None:
        out.append({"host": "phobos", "line": f"phobos kv {gpu * 100:.0f}%"})
    if reqs is not None:
        out.append({"host": "phobos", "line": f"phobos {reqs:.0f} reqs"})
    if tok is not None:
        out.append({"host": "phobos", "line": f"phobos {tok:.0f} tok/s"})
    if not out:
        out.append({"host": "phobos", "line": "phobos down"})
    # deimos has no tailnet address of its own; it is scraped through phobos
    # once an agent is deployed there.
    out.append({"host": "deimos", "line": "deimos via phobos"})
    return out


def torrents():
    try:
        info = get_json(QBT + "/api/v2/transfer/info")
        torrents = get_json(QBT + "/api/v2/torrents/info")
        up = float(info.get("up_info_data", 0)) / 1e9
        dl = float(info.get("dl_info_data", 0)) / 1e9
        ratio = (up / dl) if dl else 0.0
        line = f"{up:.1f}G up / {dl:.1f}G down · ratio {ratio:.2f} · {len(torrents)} torrents"
        return {"line": line, "ratio": round(ratio, 3), "count": len(torrents)}
    except Exception:
        return None


def presence():
    if not HA_TOKEN:
        return None
    try:
        states = get_json(HA + "/api/states", headers={"Authorization": f"Bearer {HA_TOKEN}"})
        people = []
        for s in states:
            if s.get("entity_id", "").startswith("person."):
                people.append({"name": s["entity_id"].split(".", 1)[1], "state": s.get("state")})
        return people or None
    except Exception:
        return None


def summary():
    spark_lines = sparks()
    tor = torrents()
    headline = " · ".join(
        [s["line"] for s in spark_lines] + ([tor["line"]] if tor else [])
    )
    return {
        "headline": headline,
        "sparks": spark_lines,
        "torrents": tor,
        "presence": presence(),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _authorized(self):
        if self.client_address[0] in ("127.0.0.1", "::1"):
            return True
        if not TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def do_GET(self):
        if self.path.split("?", 1)[0] != "/summary":
            self.send_error(404)
            return
        if not self._authorized():
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"unauthorized"}')
            return
        body = json.dumps(summary()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8091), Handler).serve_forever()
