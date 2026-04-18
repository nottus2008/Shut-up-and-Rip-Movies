from flask import Flask, request, jsonify, Response, send_from_directory
import os
import re
import subprocess
import threading
import uuid
import queue

HERE = os.path.dirname(os.path.abspath(__file__))
app = Flask(__name__, static_folder=HERE)

# ── Adjust this path to wherever suarip lives ──────────────────────────────
SCRIPT_PATH = os.path.join(HERE, "suarip-beta1_9_5.sh")

# Single active-job slot (the bash script has its own lock file too)
_job = {
    "id":      None,
    "proc":    None,
    "lines":   [],          # full history for late-joining clients
    "status":  "idle",      # idle | running | done | error
    "lock":    threading.Lock(),
}
_queues: dict[str, queue.Queue] = {}   # job_id → per-client SSE queues

ANSI_RE = re.compile(r'\x1b\[[0-9;]*m')


def _strip_ansi(s: str) -> str:
    return ANSI_RE.sub('', s)


def _broadcast(job_id: str, line: str | None) -> None:
    """Push a line (or None sentinel) to every SSE client watching this job."""
    dead = []
    for cid, q in list(_queues.items()):
        if cid.startswith(job_id + ':'):
            try:
                q.put_nowait(line)
            except queue.Full:
                dead.append(cid)
    for cid in dead:
        _queues.pop(cid, None)


# ── Routes ──────────────────────────────────────────────────────────────────

@app.route('/')
def index():
    return send_from_directory(HERE, 'index.html')


@app.route('/start', methods=['POST'])
def start():
    data = request.get_json(force=True, silent=True) or {}

    with _job["lock"]:
        if _job["status"] == "running":
            return jsonify({"error": "A rip is already running"}), 409

        content_type   = data.get("type", "movie")      # "movie" | "tv"
        rescue_mode    = bool(data.get("rescue", False))
        drive          = data.get("drive", "internal")   # "internal" | "usb"
        series_name    = data.get("series_name", "").strip()
        season         = str(data.get("season", "1"))
        episode_start  = str(data.get("episode_start", "1"))

        # Build the environment the script will run with
        env = os.environ.copy()
        env["SUARIP_TYPE"]     = "tv" if content_type == "tv" else "movie"
        env["SUARIP_RESCUE"]   = "1" if rescue_mode else ""
        env["SUARIP_DRIVE"]    = "/dev/sr1" if drive == "usb" else "/dev/sr0"
        if content_type == "tv":
            env["SUARIP_SERIES"]    = series_name
            env["SUARIP_SEASON"]    = season
            env["SUARIP_EP_START"]  = episode_start

        job_id = uuid.uuid4().hex[:8]
        _job["id"]     = job_id
        _job["status"] = "running"
        _job["lines"]  = []

        def _runner():
            # HandBrake uses \r to overwrite progress in place.
            # Read char-by-char so we catch both \n and \r as line endings.
            PROGRESS_RE = re.compile(
                r'Encoding:.*?(\d+\.\d+)\s*%'
                r'(?:.*?(\d+\.\d+)\s*fps)?'
                r'(?:.*?ETA\s*(\S+))?'
            )
            try:
                proc = subprocess.Popen(
                    ["bash", SCRIPT_PATH, "--no-inhibit"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    stdin=subprocess.DEVNULL,   # prevent script from seeing a terminal
                    text=True,
                    env=env,
                    bufsize=0,
                )
                _job["proc"] = proc

                buf = []
                while True:
                    ch = proc.stdout.read(1)
                    if not ch:
                        break
                    if ch in ('\n', '\r'):
                        raw = ''.join(buf).strip()
                        buf = []
                        if not raw:
                            continue
                        line = _strip_ansi(raw)

                        # Check for HandBrake progress line
                        m = PROGRESS_RE.search(line)
                        if m:
                            pct = m.group(1) or '0'
                            fps = m.group(2) or '—'
                            eta = m.group(3) or '—'
                            _broadcast(job_id, f"__PROGRESS__:{pct}:{fps}:{eta}")
                        else:
                            _job["lines"].append(line)
                            _broadcast(job_id, line)
                    else:
                        buf.append(ch)

                proc.wait()
                final_status = "done" if proc.returncode == 0 else "error"

            except Exception as exc:
                final_status = "error"
                err = f"[INTERNAL ERROR] {exc}"
                _job["lines"].append(err)
                _broadcast(job_id, err)
            finally:
                _job["status"] = final_status
                _job["proc"]   = None
                _broadcast(job_id, None)   # sentinel → clients close stream

        threading.Thread(target=_runner, daemon=True).start()
        return jsonify({"job_id": job_id})


@app.route('/stream/<job_id>')
def stream(job_id: str):
    """Server-Sent Events endpoint. Replays history then streams live output."""
    if job_id != _job.get("id"):
        return Response("data: [ERROR] Unknown job\n\n", mimetype='text/event-stream')

    client_id = f"{job_id}:{uuid.uuid4().hex[:6]}"
    q: queue.Queue = queue.Queue(maxsize=500)
    _queues[client_id] = q

    def generate():
        try:
            # Replay already-captured lines so a page refresh doesn't lose history
            for line in list(_job["lines"]):
                yield f"data: {line}\n\n"

            # If job already finished before we started streaming, send sentinel
            if _job["status"] != "running":
                yield "data: [DONE]\n\n"
                return

            # Live tail
            while True:
                try:
                    line = q.get(timeout=25)
                except queue.Empty:
                    yield ": heartbeat\n\n"   # keep connection alive
                    continue

                if line is None:             # sentinel from _runner
                    yield "data: [DONE]\n\n"
                    break
                yield f"data: {line}\n\n"
        finally:
            _queues.pop(client_id, None)

    return Response(
        generate(),
        mimetype='text/event-stream',
        headers={
            "Cache-Control":    "no-cache",
            "X-Accel-Buffering": "no",      # disable nginx proxy buffering
        },
    )


@app.route('/status')
def status():
    return jsonify({"status": _job["status"], "job_id": _job["id"]})


@app.route('/stop', methods=['POST'])
def stop():
    proc = _job.get("proc")
    if proc and proc.poll() is None:
        proc.terminate()
        _job["status"] = "idle"
        return jsonify({"ok": True})
    return jsonify({"error": "No active process"}), 400


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)
