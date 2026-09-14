#!/usr/bin/env python3
# ploopy curve editor server: polls hyprland cursor, streams speed over SSE,
# POSTs slider changes to hyprctl eval. Serves editor.html fresh per request.
import http.server, socket, os, json, glob, time, threading, subprocess

BASE = os.path.dirname(os.path.abspath(__file__))
RUN = os.environ.get('XDG_RUNTIME_DIR', '/run/user/1000')
socks = sorted(glob.glob(RUN + '/hypr/*/.socket.sock'), key=os.path.getmtime)
SOCK = socks[-1]
DEV = "ploopy-corporation-ploopy-adept-trackball-mouse"
CURVE_FILE = os.path.join(BASE, 'curve.json')
HTML_FILE = os.path.join(BASE, 'editor.html')
BAKED_FALLBACK = "{\"step\": 2.2, \"points\": [0.010725455777575553, 0.03481132427897955, 0.10802142029952082, 0.28513045152573563, 0.6011738354029882, 1.4118664540198298, 1.986602780602482, 2.314534020945035, 2.745505250181486, 2.9237747316656617, 3.198709559996233, 5.0133648028866045, 6.624072807188476, 6.744212988241895, 7.512221021535088, 8.000000000000004]}"

def cursorpos():
    s = socket.socket(socket.AF_UNIX); s.settimeout(0.5)
    try:
        s.connect(SOCK); s.sendall(b'cursorpos')
        data = b''
        while True:
            c = s.recv(64)
            if not c: break
            data += c
            if b'\n' in data or b',' in data: break
        x, y = data.decode().split(',')
        return int(x), int(y)
    finally:
        s.close()

state = {"t": time.time(), "v": 0.0, "raw": 0.0, "x": 0, "y": 0}
def poller():
    last = cursorpos(); lastt = time.time(); ema = 0.0
    while True:
        time.sleep(1/90.0)
        try:
            cur = cursorpos()
        except Exception:
            continue
        now = time.time()
        dt = now - lastt
        if dt <= 0: continue
        d = ((cur[0]-last[0])**2 + (cur[1]-last[1])**2) ** 0.5
        v = d / (dt * 1000.0)  # px per ms (dt seconds -> ms)
        ema = ema * 0.7 + v * 0.3
        state.update(t=now, v=ema, raw=v, x=cur[0], y=cur[1])
        last, lastt = cur, now
threading.Thread(target=poller, daemon=True).start()

def read_curve():
    try:
        return json.load(open(CURVE_FILE))
    except Exception:
        return json.loads(BAKED_FALLBACK)

def fmt(v): return "%g" % v

def apply_curve(c):
    step = float(c["step"]); pts = [float(p) for p in c["points"]]
    if not (0 < step <= 10000): raise ValueError("step out of range")
    if not (2 <= len(pts) <= 64): raise ValueError("need 2-64 points")
    if any(p < 0 or p > 10000 for p in pts): raise ValueError("point out of range")
    profile = "custom " + " ".join([fmt(step)] + [fmt(p) for p in pts])
    lua = 'hl.device({name="' + DEV + '", accel_profile="' + profile + '"}); return "slider-tune"'
    r = subprocess.run(["hyprctl", "eval", lua], capture_output=True, text=True, timeout=5)
    if "ok" not in r.stdout: raise RuntimeError(r.stdout + r.stderr)
    json.dump({"step": step, "points": pts}, open(CURVE_FILE, 'w'))

def read_html():
    return open(HTML_FILE).read()

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/':
            body = read_html().encode()
            self.send_response(200); self.send_header('Content-Type','text/html')
            self.send_header('Content-Length', str(len(body))); self.end_headers()
            self.wfile.write(body)
        elif self.path == '/stream':
            self.send_response(200)
            self.send_header('Content-Type','text/event-stream')
            self.send_header('Cache-Control','no-cache'); self.end_headers()
            sent_curve = None
            while True:
                try:
                    c = read_curve()
                    if c != sent_curve:
                        sent_curve = c
                        self.wfile.write(b'event: curve\ndata: ' + json.dumps(c).encode() + b'\n\n')
                    msg = json.dumps({"t": state["t"], "v": round(state["v"], 5), "raw": round(state["raw"], 5), "x": state["x"], "y": state["y"]})
                    self.wfile.write(b'data: ' + msg.encode() + b'\n\n')
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return
                time.sleep(1/30.0)
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        if self.path != '/curve':
            self.send_response(404); self.end_headers(); return
        try:
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            apply_curve(json.loads(body))
            ok = b'{"ok": true}'
            self.send_response(200); self.send_header('Content-Type','application/json')
            self.send_header('Content-Length', str(len(ok))); self.end_headers(); self.wfile.write(ok)
        except Exception as e:
            ok = ('{"ok": false, "err": %s}' % json.dumps(str(e))).encode()
            self.send_response(400); self.send_header('Content-Type','application/json')
            self.send_header('Content-Length', str(len(ok))); self.end_headers(); self.wfile.write(ok)

http.server.ThreadingHTTPServer(('127.0.0.1', 8799), H).serve_forever()
