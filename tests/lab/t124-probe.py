#!/usr/bin/env python3
"""T-124 user probe (ADR-022): what a user outside the cluster sees while a control-plane node is down.

Run it on a machine OUTSIDE the cluster that reaches the ingress address (hybrid-gpu-lab: the lab host). Inside the
cluster kube-proxy answers the MetalLB address itself, so a probe there never sees the address move between nodes.
Every 5 s, in parallel and each within 10 s:
  ui       the Run:ai UI page loads
  login    a real login (Keycloak, the database, Run:ai's backend) and an API call with the token
  grafana  a Grafana login and a dashboard search (Grafana's state is in the database)
Settings come from the environment (secrets never printed): RUNAI_URL, RUNAI_USER, RUNAI_PASSWORD, GRAFANA_URL,
GRAFANA_USER, GRAFANA_PASSWORD, OIF_CA (the oif CA certificate). It writes one line per round to stdout
("seconds time ui login grafana", 1 = answered) and at the end, after --seconds or SIGTERM, the longest outage of
each and how long each was disturbed (first failure to the last recovery); exit status 1 if any was disturbed longer
than --max seconds (default 90).
"""
import argparse
import base64
import json
import os
import signal
import ssl
import sys
import threading
import time
import urllib.request

CTX = ssl.create_default_context(cafile=os.environ["OIF_CA"])
TIMEOUT = 10


def get(url: str, headers: dict | None = None, body: dict | None = None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, headers=headers or {})
    if body is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, context=CTX, timeout=TIMEOUT) as r:
        return r.status, r.read()


def ui() -> bool:
    return get(os.environ["RUNAI_URL"] + "/")[0] == 200


def login() -> bool:
    url = os.environ["RUNAI_URL"]
    status, raw = get(url + "/api/v1/token", body={"grantType": "password", "username": os.environ["RUNAI_USER"],
                                                    "password": os.environ["RUNAI_PASSWORD"]})
    token = json.loads(raw).get("accessToken") if status == 200 else None
    return bool(token) and get(url + "/api/v1/clusters", headers={"Authorization": "Bearer " + token})[0] == 200


def grafana() -> bool:
    auth = base64.b64encode(f'{os.environ["GRAFANA_USER"]}:{os.environ["GRAFANA_PASSWORD"]}'.encode()).decode()
    status, raw = get(os.environ["GRAFANA_URL"] + "/api/search?query=OIF", headers={"Authorization": "Basic " + auth})
    return status == 200 and len(json.loads(raw)) > 0


CHECKS = {"ui": ui, "login": login, "grafana": grafana}


def ok(fn) -> bool:
    try:
        return fn()
    except Exception:   # any failure (refused, timeout, HTTP error, bad answer) is what a user would see as down
        return False


def round_once() -> dict:
    out = {}
    threads = [threading.Thread(target=lambda n=n, f=f: out.__setitem__(n, ok(f))) for n, f in CHECKS.items()]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return out


def longest_gap(rows: list, name: str) -> float:
    """First failed round to the next answered one; an outage still open at the end counts to the end."""
    worst, start = 0.0, None
    for t, r in rows:
        if not r[name] and start is None:
            start = t
        elif r[name] and start is not None:
            worst, start = max(worst, t - start), None
    if start is not None:
        worst = max(worst, rows[-1][0] - start + 5)
    return worst


def disturbed(rows: list, name: str) -> float:
    """First failed round to the answered round after the last failure: what a user calls 'it was broken'."""
    fails = [i for i, (_, r) in enumerate(rows) if not r[name]]
    if not fails:
        return 0.0
    end = rows[fails[-1] + 1][0] if fails[-1] + 1 < len(rows) else rows[-1][0] + 5
    return end - rows[fails[0]][0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=1200)
    ap.add_argument("--max", type=int, default=90)
    a = ap.parse_args()
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    rows, t0 = [], time.monotonic()
    while not stop.is_set() and time.monotonic() - t0 < a.seconds:
        t = time.monotonic() - t0
        r = round_once()
        rows.append((t, r))
        print(f"{t:.0f} {time.strftime('%H:%M:%S', time.gmtime())} " + " ".join(str(int(r[n])) for n in CHECKS), flush=True)
        stop.wait(max(0.0, 5 - (time.monotonic() - t0 - t)))
    gaps = {n: longest_gap(rows, n) for n in CHECKS}
    spans = {n: disturbed(rows, n) for n in CHECKS}
    print("longest outage: " + ", ".join(f"{n} {g:.0f} s" for n, g in gaps.items()), flush=True)
    print("disturbed for (first failure to the last recovery, flapping included): "
          + ", ".join(f"{n} {s:.0f} s" for n, s in spans.items()) + f" (limit {a.max} s)", flush=True)
    return 1 if any(s > a.max for s in spans.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
