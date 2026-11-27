#!/usr/bin/env python3
"""homelab status API for Glance and the Noctalia widget.

Everything reported here comes from something already running on the box:
VictoriaMetrics (node_exporter's systemd collector, the qbt exporter and the
sparks' vLLM metrics), each app's own loopback listener, sysfs for the iGPU and
the apps' own unauthenticated health endpoints. Every upstream call is
best-effort: a missing exporter, a refused connection or an unconfigured HA
token yields null/"unknown", never a 500.

The app table is passed in as JSON by the flake (me.bellona.apps in
registry.nix), so this service never keeps its own copy of the service list.
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

VM = "http://127.0.0.1:8428"
QBT = "http://127.0.0.1:8080"
HA = "http://127.0.0.1:8123"
TOKEN_FILE = "/run/agenix/homelab-api-token"
HA_TOKEN_FILE = "/run/agenix/ha-token"
ZPOOL = "/run/current-system/sw/bin/zpool"

REGISTRY_FILE = sys.argv[1] if len(sys.argv) > 1 else ""
REGISTRY = {}
if REGISTRY_FILE:
    try:
        with open(REGISTRY_FILE, "r", encoding="utf-8") as f:
            REGISTRY = json.load(f)
    except (OSError, ValueError):
        REGISTRY = {}
APPS = REGISTRY.get("apps", {})
DOMAIN = REGISTRY.get("domain", "packet.dog")

CACHE = {}
CACHE_TTL = 10.0


def read(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


TOKEN = read(TOKEN_FILE)
HA_TOKEN = read(HA_TOKEN_FILE)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # a vhost answers 302 to the authelia portal; following that redirect walks
    # out to the public DNS name and measures the wrong thing. the status code
    # itself is the health signal we want.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def get_json(url, headers=None, timeout=4):
    req = urllib.request.Request(url, headers=headers or {})
    with OPENER.open(req, timeout=timeout) as r:
        return json.load(r)


def get_text(url, timeout=3):
    req = urllib.request.Request(url)
    with OPENER.open(req, timeout=timeout) as r:
        return r.read(4096).decode("utf-8", "replace").strip()


def probe(port, path="/"):
    url = f"http://127.0.0.1:{port}{path}"
    t0 = time.time()
    try:
        with OPENER.open(url, timeout=2) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception:
        return {"up": False, "ms": 0, "code": None}
    return {"up": code < 500, "ms": int((time.time() - t0) * 1000), "code": code}


def prom(query):
    try:
        data = get_json(VM + "/api/v1/query?" + urllib.parse.urlencode({"query": query}))
        result = data.get("data", {}).get("result", [])
        if not result:
            return None
        return float(result[0]["value"][1])
    except Exception:
        return None


def pct(v):
    return "—" if v is None else f"{v * 100:.2f}%"


def info_for(app):
    flavor = app.get("flavor", "generic")
    try:
        if flavor == "qbittorrent":
            info = get_json(QBT + "/api/v2/transfer/info")
            listing = get_json(QBT + "/api/v2/torrents/info")
            up = float(info.get("up_info_data", 0)) / 1e9
            dl = float(info.get("dl_info_data", 0)) / 1e9
            ratio = (up / dl) if dl else 0.0
            return f"{up:.1f}G up / {dl:.1f}G down · ratio {ratio:.2f} · {len(listing)} torrents"
        if flavor == "home-assistant":
            if not HA_TOKEN:
                return app.get("note") or "token not configured"
            states = get_json(HA + "/api/states", headers={"Authorization": f"Bearer {HA_TOKEN}"})
            people = [s for s in states if s.get("entity_id", "").startswith("person.")]
            home = [p["entity_id"].split(".", 1)[1] for p in people if p.get("state") == "home"]
            return f"{len(home)} home / {len(people) - len(home)} away" + (
                f" ({', '.join(home)})" if home else ""
            )
        if flavor == "grafana":
            h = get_json("http://127.0.0.1:3000/api/health")
            return f"{h.get('version', '?')} · db {h.get('database', '?')}"
        if flavor == "forgejo":
            v = get_json("http://127.0.0.1:3001/api/v1/version")
            return f"forgejo {v.get('version', '?')}"
        if flavor == "jellyfin":
            return get_text("http://127.0.0.1:8096/health")[:24] or app.get("note", "")
        if flavor == "slskd":
            return get_text("http://127.0.0.1:5030/health")[:24] or app.get("note", "")
        if flavor == "navidrome":
            # navidrome's /ping answers a bare "."; fall back to the note.
            txt = get_text("http://127.0.0.1:4533/ping")[:24]
            return txt if txt not in ("", ".") else app.get("note", "")
        if flavor == "immich":
            return get_text("http://127.0.0.1:2283/api/server/ping")[:24] or app.get("note", "")
    except Exception:
        return app.get("note", "")
    return app.get("note", "")


def app_report(slug, app):
    unit = app.get("unit")
    pr = probe(app.get("port"), app.get("healthPath") or "/")
    now = None
    up_24 = up_7 = up_30 = None
    restarts = 0
    if unit:
        q = f'node_systemd_unit_state{{name="{unit}",state="active"}}'
        now = prom(q)
        up_24 = prom(f"avg_over_time({q}[24h])")
        up_7 = prom(f"avg_over_time({q}[7d])")
        up_30 = prom(f"avg_over_time({q}[30d])")
        changes = prom(f"changes({q}[30d])")
        restarts = int(round(changes / 2)) if changes is not None else 0
    elif slug == "qbittorrent":
        # a user unit: node_exporter's systemd collector only walks the system
        # bus, so the exporter's own `up` is the availability signal.
        q = 'up{job="qbittorrent"}'
        up_24 = prom(f"avg_over_time({q}[24h])")
        up_7 = prom(f"avg_over_time({q}[7d])")
        up_30 = prom(f"avg_over_time({q}[30d])")
    alive = pr["up"] and (now is None or now >= 1)
    return {
        "slug": slug,
        "title": app.get("title", slug),
        "url": f"https://{app['subdomain']}.{DOMAIN}"
        if app.get("subdomain")
        else f"http://127.0.0.1:{app.get('port')}",
        "up": alive,
        "status": "UP" if alive else "DOWN",
        "unit": unit or "—",
        "uptime_24h": pct(up_24),
        "uptime_7d": pct(up_7),
        "uptime_30d": pct(up_30),
        "restarts_30d": restarts,
        "latency_ms": pr["ms"],
        "code": "—" if pr["code"] is None else str(pr["code"]),
        "info": info_for(app),
    }


def cached_app(slug):
    hit = CACHE.get(slug)
    if hit and time.time() - hit[0] < CACHE_TTL:
        return hit[1]
    app = APPS.get(slug)
    if not app:
        return None
    report = app_report(slug, app)
    CACHE[slug] = (time.time(), report)
    return report


# ── machine ────────────────────────────────────────────────────────────────


def cpu_pct():
    def snap():
        line = open("/proc/stat", "r", encoding="utf-8").readline()
        parts = [int(x) for x in line.split()[1:]]
        idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
        return idle, sum(parts)

    try:
        i1, t1 = snap()
        time.sleep(0.3)
        i2, t2 = snap()
    except (OSError, ValueError, IndexError):
        return 0.0
    dt = t2 - t1
    if dt <= 0:
        return 0.0
    return round(100.0 * (1.0 - (i2 - i1) / dt), 1)


def meminfo():
    out = {}
    try:
        for line in open("/proc/meminfo", "r", encoding="utf-8"):
            k, _, rest = line.partition(":")
            out[k] = int(rest.split()[0]) * 1024
    except (OSError, ValueError):
        return {"used": 0, "total": 0, "used_gib": 0.0, "total_gib": 0.0}
    total = out.get("MemTotal", 0)
    avail = out.get("MemAvailable", 0)
    used = max(total - avail, 0)
    return {"used": used, "total": total, "used_gib": used / 2**30, "total_gib": total / 2**30}


def temps():
    out = []
    for path in glob.glob("/sys/class/hwmon/hwmon*/temp*_input"):
        try:
            milli = int(read(path) or 0)
        except ValueError:
            continue
        c = milli / 1000.0
        if not 0 < c < 150:
            continue
        base = os.path.dirname(path)
        idx = os.path.basename(path).split("_")[0][len("temp") :]
        label = read(os.path.join(base, f"temp{idx}_label"))
        if not label:
            label = read(os.path.join(base, "name")) or os.path.basename(base)
        out.append({"label": label, "c": round(c, 1)})
    out.sort(key=lambda t: t["c"], reverse=True)
    return out[:6]


def gpu():
    busy = 0.0
    temp = ""
    power = ""
    try:
        for p in glob.glob("/sys/class/drm/card*/device/gpu_busy_percent"):
            busy = float(read(p) or 0)
            break
    except ValueError:
        pass
    for p in glob.glob("/sys/class/drm/card*/device/hwmon/hwmon*/temp1_input"):
        try:
            temp = f"{int(read(p)) / 1000.0:.0f}C"
        except ValueError:
            temp = ""
        break
    for p in glob.glob("/sys/class/drm/card*/device/hwmon/hwmon*/power1_input"):
        try:
            power = f"{int(read(p)) / 1e6:.1f}W"
        except ValueError:
            power = ""
        break
    return busy, temp, power


def disks():
    out = []
    for label, path in (("root", "/"), ("tank", "/tank")):
        if not os.path.isdir(path):
            continue
        try:
            u = shutil.disk_usage(path)
        except OSError:
            continue
        out.append(
            {"label": label, "pct": f"{100.0 * u.used / u.total:.0f}", "free": f"{u.free / 2**30:.0f}G"}
        )
    return out


def zfs():
    if not os.path.exists(ZPOOL):
        return []
    try:
        r = subprocess.run(
            [ZPOOL, "list", "-H", "-p", "-o", "name,size,alloc,health"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return []
    out = []
    for line in r.stdout.strip().splitlines():
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        try:
            size = int(parts[1])
            alloc = int(parts[2])
        except ValueError:
            continue
        out.append(
            {
                "name": parts[0],
                "size": f"{size / 2**40:.1f}T" if size >= 2**40 else f"{size / 2**30:.0f}G",
                "alloc": f"{alloc / 2**40:.1f}T" if alloc >= 2**40 else f"{alloc / 2**30:.0f}G",
                "health": parts[3],
            }
        )
    return out


def machine():
    mem = meminfo()
    busy, gpu_temp, gpu_power = gpu()
    uptime_s = 0
    try:
        uptime_s = int(float(read("/proc/uptime").split()[0]))
    except (ValueError, IndexError):
        pass
    return {
        "cpu_pct": cpu_pct(),
        "mem_pct": round(100.0 * mem["used"] / mem["total"], 1) if mem["total"] else 0.0,
        "mem_used": f"{mem['used_gib']:.1f}G",
        "mem_total": f"{mem['total_gib']:.0f}G",
        "load": read("/proc/loadavg").split()[0],
        "uptime_days": f"{uptime_s / 86400:.1f}",
        "temps": temps(),
        "gpu_pct": busy,
        "gpu_temp": gpu_temp,
        "gpu_power": gpu_power,
        "disks": disks(),
        "zfs": zfs(),
    }


# ── sparks / seedbox / presence ────────────────────────────────────────────


def sparks():
    nodes = []
    kv = prom("sum(tensorfold:kv_cache_usage_ratio)")
    reqs = prom("sum(tensorfold:num_requests_running)")
    wait = prom("sum(tensorfold:num_requests_waiting)")
    tok = prom("sum(rate(tensorfold:generation_tokens_total[5m]))")
    mem = prom("sum(tensorfold:device_memory_bytes)")
    up = prom('up{job="vllm"}')
    lines = []
    if kv is not None:
        lines.append(f"kv {kv * 100:.0f}%")
    if reqs is not None:
        lines.append(f"{reqs:.0f} running")
    if wait is not None:
        lines.append(f"{wait:.0f} waiting")
    if tok is not None:
        lines.append(f"{tok:.0f} tok/s")
    if mem is not None:
        lines.append(f"{mem / 2**30:.1f}G vram")
    nodes.append(
        {
            "host": "phobos",
            "up": bool(up),
            "status": "UP" if up else "DOWN",
            "lines": lines or ["no metrics"],
        }
    )
    broken = prom("tensorfold:pair_broken")
    stalled = prom("tensorfold:pair_stalled")
    if broken is None:
        d_lines = ["via phobos (no pair metrics)"]
        d_up = False
    else:
        d_lines = ["pair ok" if broken == 0 else "PAIR BROKEN"]
        if stalled is not None:
            d_lines.append(f"{stalled:.0f} stalled")
        d_up = broken == 0
    nodes.append(
        {"host": "deimos", "up": d_up, "status": "UP" if d_up else "DOWN", "lines": d_lines}
    )
    return {"nodes": nodes}


def torrents():
    try:
        info = get_json(QBT + "/api/v2/transfer/info")
        listing = get_json(QBT + "/api/v2/torrents/info")
        up = float(info.get("up_info_data", 0)) / 1e9
        dl = float(info.get("dl_info_data", 0)) / 1e9
        ratio = (up / dl) if dl else 0.0
        return {
            "up": f"{up:.1f}G",
            "down": f"{dl:.1f}G",
            "ratio": round(ratio, 3),
            "count": len(listing),
            "line": f"{up:.1f}G up / {dl:.1f}G down · ratio {ratio:.2f} · {len(listing)} torrents",
        }
    except Exception:
        return None


def presence():
    if not HA_TOKEN:
        return {"people": []}
    try:
        states = get_json(HA + "/api/states", headers={"Authorization": f"Bearer {HA_TOKEN}"})
    except Exception:
        return {"people": []}
    people = []
    for s in states:
        eid = s.get("entity_id", "")
        if eid.startswith("person."):
            people.append({"name": eid.split(".", 1)[1], "state": s.get("state")})
    return {"people": people}


def summary():
    spark_lines = [
        {"host": n["host"], "line": " · ".join(n["lines"])} for n in sparks()["nodes"]
    ]
    tor = torrents()
    headline = " · ".join(
        [s["line"] for s in spark_lines] + ([tor["line"]] if tor else [])
    )
    return {
        "headline": headline,
        "sparks": spark_lines,
        "torrents": tor,
        "presence": presence()["people"] or None,
    }


def torrents_widget():
    tor = torrents()
    if tor is None:
        return {"up": "—", "down": "—", "ratio": 0, "count": 0, "line": "seedbox unreachable"}
    return tor


ROUTES = {
    "/summary": summary,
    "/apps": lambda: {"apps": [cached_app(s) for s in APPS]},
    "/machine": machine,
    "/sparks": sparks,
    "/torrents": torrents_widget,
    "/presence": presence,
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

    def _send(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if not self._authorized():
            self._send({"error": "unauthorized"}, 401)
            return
        if path.startswith("/app/"):
            slug = path[len("/app/") :]
            report = cached_app(slug)
            if report is None:
                self._send({"error": "unknown app", "slug": slug}, 404)
                return
            self._send(report)
            return
        fn = ROUTES.get(path)
        if fn is None:
            self._send({"error": "not found", "path": path}, 404)
            return
        try:
            self._send(fn())
        except Exception as exc:  # a broken upstream must not take the widget down
            self._send({"error": str(exc)})


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8091), Handler).serve_forever()
