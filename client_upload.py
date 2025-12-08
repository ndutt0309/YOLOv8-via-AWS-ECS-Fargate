#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import csv
import json
import os
import random
import sys
import time
from datetime import datetime, timezone
from typing import Iterable, List, Tuple

import numpy as np
import requests


def now_utc_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def load_manifest(path: str, limit: int) -> List[str]:
  
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    urls = []
    for item in data:
        url = None
        if isinstance(item, str):
            url = item
        elif isinstance(item, dict):
            # common keys
            for key in ("image_url", "url"):
                if key in item and isinstance(item[key], str):
                    url = item[key]
                    break
            # nested patterns
            if url is None and "input" in item and isinstance(item["input"], dict):
                for key in ("image_url", "url"):
                    if key in item["input"] and isinstance(item["input"][key], str):
                        url = item["input"][key]
                        break
            
            if url is None:
                for v in item.values():
                    if isinstance(v, str) and v.startswith("http"):
                        url = v
                        break
                    if isinstance(v, dict):
                        for vv in v.values():
                            if isinstance(vv, str) and vv.startswith("http"):
                                url = vv
                                break
                        if url:
                            break

        if isinstance(url, str) and url.startswith("http"):
            urls.append(url)

    if not urls:
        print("manifest parsed but contains 0 urls", file=sys.stderr)
        return []


    if limit <= len(urls):
        return urls[:limit]
    else:
      
        out = []
        i = 0
        while len(out) < limit:
            out.append(urls[i % len(urls)])
            i += 1
        return out


def pct(a: Iterable[float], q: float) -> float:
    arr = np.asarray(list(a), dtype=float)
    if arr.size == 0:
        return float('nan')
    return float(np.quantile(arr, q))


def stats_ms(lat_ms: List[float]) -> dict:
    arr = np.asarray(lat_ms, dtype=float)
    if arr.size == 0:
        return dict(avg=float('nan'), p90=float('nan'),
                    p95=float('nan'), p99=float('nan'), max=float('nan'))
    return dict(
        avg=float(arr.mean()),
        p90=pct(arr, 0.90),
        p95=pct(arr, 0.95),
        p99=pct(arr, 0.99),
        max=float(arr.max())
    )


def post_image(api: str, image_url: str, timeout: float = 30.0):
    t0 = time.perf_counter()
    try:
        payload = {"image_url": image_url, "url": image_url, "image": image_url}
        r = requests.post(api, json=payload, headers={"Content-Type":"application/json"}, timeout=timeout)
        status = r.status_code
    except Exception:
        status = 0
    t1 = time.perf_counter()
    return status, (t1 - t0) * 1000.0



def announce_start(mode: str, api: str, count: int):
    print("=" * 60)
    print(f"Start: {datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S')}Z | mode={mode} | api={api} | count={count}")
    print("=" * 60)




def run_quiet(api: str, urls: List[str], rps: float, tag: str, csv_path: str, mode_label: str):
   
    if rps <= 0:
        rps = 1.0
    period = 1.0 / rps

    lat_ms = []
    ok = 0
    rows = []

    announce_start(mode_label, api, len(urls))
    last_progress = 0

    for i, u in enumerate(urls, 1):
        t_before = time.perf_counter()

        status, ms = post_image(api, u)
        lat_ms.append(ms)
        if 200 <= status < 300:
            ok += 1

        rows.append([now_utc_iso(), mode_label, tag, u, status, f"{ms:.3f}"])

       
        if i % 50 == 0 or i == len(urls):
            median = pct(lat_ms, 0.50)
            print(f"[{mode_label}] progress: {i}/{len(urls)} sent, ok={ok}, med~{median:.2f} ms")

    
        elapsed = time.perf_counter() - t_before
        remain = period - elapsed
        if remain > 0:
            time.sleep(remain)

    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["ts_utc", "mode", "tag", "url", "status", "latency_ms"])
        w.writerows(rows)

    s = stats_ms(lat_ms)
    total_s = sum(lat_ms) / 1000.0
    thr = len(lat_ms) / total_s if total_s > 0 else float('nan')
    print("=" * 60)
    print(f"SUMMARY: n={len(lat_ms)} ok={ok} succ={ok*100.0/len(lat_ms):.1f}% "
          f"avg={s['avg']:.2f} ms p90={s['p90']:.2f} ms p95={s['p95']:.2f} ms "
          f"p99={s['p99']:.2f} ms max={s['max']:.2f} ms thr={thr:.2f} img/s")
    print(f"[saved] {csv_path}")


def run_burst(api: str, urls: List[str], burst_size: int, pause_s: float, tag: str, csv_path: str):
   
    burst_size = max(1, int(burst_size))
    pause_s = max(0.0, float(pause_s))

    lat_ms = []
    ok = 0
    rows = []

    announce_start("burst", api, len(urls))

    sent = 0
    while sent < len(urls):
        # This burst
        end = min(sent + burst_size, len(urls))
        this_burst = urls[sent:end]
        for u in this_burst:
            status, ms = post_image(api, u)
            lat_ms.append(ms)
            if 200 <= status < 300:
                ok += 1
            rows.append([now_utc_iso(), "burst", tag, u, status, f"{ms:.3f}"])

        sent = end
        print(f"[burst] progress: {sent}/{len(urls)} sent, ok={ok}")

        if sent < len(urls) and pause_s > 0:
            time.sleep(pause_s)

    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["ts_utc", "mode", "tag", "url", "status", "latency_ms"])
        w.writerows(rows)

    s = stats_ms(lat_ms)
    total_s = sum(lat_ms) / 1000.0
    thr = len(lat_ms) / total_s if total_s > 0 else float('nan')
    print("=" * 60)
    print(f"SUMMARY: n={len(lat_ms)} ok={ok} succ={ok*100.0/len(lat_ms):.1f}% "
          f"avg={s['avg']:.2f} ms p90={s['p90']:.2f} ms p95={s['p95']:.2f} ms "
          f"p99={s['p99']:.2f} ms max={s['max']:.2f} ms thr={thr:.2f} img/s")
    print(f"[saved] {csv_path}")


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--api", required=True, help="Prediction endpoint, e.g. http://44.201.97.75:5000/predict")
    p.add_argument("--manifest", required=True, help="Path to manifest JSON (strings or dicts)")
    p.add_argument("--mode", choices=["quiet", "sustained", "burst"], required=True)
    p.add_argument("--limit", type=int, default=300, help="Total images to send in this run")
    p.add_argument("--rps", type=float, default=10.0, help="Requests per second (quiet/sustained)")
    p.add_argument("--burst-size", type=int, default=50, help="Burst size (burst mode)")
    p.add_argument("--pause", type=float, default=3.0, help="Pause seconds between bursts (burst mode)")
    p.add_argument("--csv", default="out.csv", help="CSV output file")
    p.add_argument("--tag", default="", help="Custom tag carried into CSV")
    return p.parse_args()


def main():
    args = parse_args()

    urls = load_manifest(args.manifest, args.limit)
    if not urls:
        print("No URLs to send. Check manifest.", file=sys.stderr)
        sys.exit(2)

    random.shuffle(urls)

    if args.mode in ("quiet", "sustained"):
        run_quiet(api=args.api, urls=urls, rps=args.rps, tag=args.tag,
                  csv_path=args.csv, mode_label=args.mode)
    elif args.mode == "burst":
        run_burst(api=args.api, urls=urls, burst_size=args.burst_size,
                  pause_s=args.pause, tag=args.tag, csv_path=args.csv)
    else:
        print(f"unknown mode: {args.mode}", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
