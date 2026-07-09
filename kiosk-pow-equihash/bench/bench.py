#!/usr/bin/env python3
"""
Equihash parameter benchmark for Kiosk.

Sweeps a grid of (n, k), running the reference numpy solver (solve.py) several
times per point, and reports p50/p95 wall-clock solve time and peak RSS. Used to
pick the shipped default parameters: the largest (n, k) whose p95 solve stays
under a time budget and whose peak RSS stays in a memory budget on a consumer
laptop with numpy.

Memory/time are driven by n_div = n/(k+1) (pool size N = 2^(n_div+1)); n must be
divisible by 8 and the solver assumes n_div <= 24.

Each run is a subprocess, polled for RSS and killed if it exceeds --mem-cap-mb or
--timeout — nothing hangs or thrashes the machine.

Usage:
  python3 bench/bench.py                       # default grid, 5 samples/point
  python3 bench/bench.py --samples 3 --timeout 60 --mem-cap-mb 3000
  python3 bench/bench.py --grid 160,7 168,7    # explicit points
  python3 bench/bench.py --markdown            # emit a Markdown table
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SOLVE = os.path.join(HERE, os.pardir, "solve.py")

# (n, k). n divisible by 8, n_div = n/(k+1) <= 24. n_div drives cost.
DEFAULT_GRID = [
    (144, 7),  # n_div 18  N=2^19
    (160, 7),  # n_div 20  N=2^21
    (168, 7),  # n_div 21  N=2^22
    (176, 7),  # n_div 22  N=2^23
    (184, 7),  # n_div 23  N=2^24
    (192, 7),  # n_div 24  N=2^25  (current default; the ~140s/6GB baseline)
]


def rss_kb(pid):
    """Resident set size of pid in KB, via ps. 0 if the process is gone."""
    try:
        out = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(pid)], stderr=subprocess.DEVNULL
        )
        return int(out.strip() or 0)
    except (subprocess.CalledProcessError, ValueError):
        return 0


def one_run(n, k, timeout, mem_cap_mb, poll=0.1):
    """Run solve.py once. Returns (status, seconds, peak_rss_mb).
    status: 'ok' | 'timeout' | 'oom' | 'nosol' | 'error'."""
    salt = base64.b64encode(os.urandom(32)).decode()
    challenge = json.dumps({"salt_b64": salt, "params": {"n": n, "k": k}, "header_nonce": 0})
    cap_kb = mem_cap_mb * 1024

    t0 = time.perf_counter()
    proc = subprocess.Popen(
        [sys.executable, SOLVE, challenge],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    peak_kb = 0
    status = None
    while True:
        ret = proc.poll()
        cur = rss_kb(proc.pid)
        if cur > peak_kb:
            peak_kb = cur
        if ret is not None:
            break
        if time.perf_counter() - t0 > timeout:
            proc.kill(); status = "timeout"; break
        if peak_kb > cap_kb:
            proc.kill(); status = "oom"; break
        time.sleep(poll)
    proc.wait()
    secs = time.perf_counter() - t0
    peak_mb = peak_kb / 1024.0

    if status:
        return status, secs, peak_mb
    if proc.returncode != 0:
        return "nosol" if proc.returncode == 2 else "error", secs, peak_mb
    try:
        out = json.loads(proc.stdout.read().decode() or "{}")
    except json.JSONDecodeError:
        return "error", secs, peak_mb
    return ("ok" if "indices" in out else "error"), secs, peak_mb


def pct(xs, p):
    if not xs:
        return float("nan")
    s = sorted(xs)
    i = min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1))))
    return s[i]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=5)
    ap.add_argument("--timeout", type=float, default=90.0, help="per-run kill after N seconds")
    ap.add_argument("--mem-cap-mb", type=int, default=4000, help="per-run kill above N MB RSS")
    ap.add_argument("--grid", nargs="*", default=None, help="explicit n,k points e.g. 160,7 168,7")
    ap.add_argument("--markdown", action="store_true")
    args = ap.parse_args()

    grid = DEFAULT_GRID
    if args.grid:
        grid = [tuple(int(x) for x in pt.split(",")) for pt in args.grid]

    rows = []
    for (n, k) in grid:
        n_div = n // (k + 1)
        times, peaks, oks, fails = [], [], 0, []
        for s in range(args.samples):
            status, secs, peak_mb = one_run(n, k, args.timeout, args.mem_cap_mb)
            if status == "ok":
                oks += 1
                times.append(secs)
                peaks.append(peak_mb)
            else:
                fails.append(status)
            sys.stderr.write(
                f"  n={n} k={k} ndiv={n_div} sample {s + 1}/{args.samples}: "
                f"{status} {secs:.1f}s {peak_mb:.0f}MB\n"
            )
            sys.stderr.flush()
        rows.append({
            "n": n, "k": k, "n_div": n_div, "ok": oks, "n_samples": args.samples,
            "p50_s": pct(times, 50), "p95_s": pct(times, 95),
            "peak_mb": max(peaks) if peaks else float("nan"),
            "fails": ",".join(sorted(set(fails))) or "-",
        })

    if args.markdown:
        print("| n | k | n_div | ok/N | p50 s | p95 s | peak MB | fails |")
        print("|---|---|-------|------|-------|-------|---------|-------|")
        for r in rows:
            print(f"| {r['n']} | {r['k']} | {r['n_div']} | {r['ok']}/{r['n_samples']} | "
                  f"{r['p50_s']:.1f} | {r['p95_s']:.1f} | {r['peak_mb']:.0f} | {r['fails']} |")
    else:
        print(json.dumps(rows, indent=2))


if __name__ == "__main__":
    main()
