#!/usr/bin/env python3
"""Measure GET /steps/summary with the API Gateway cache not loaded vs loaded.

Phase 1 - cache NOT loaded: every request adds a unique ?nocache= value, which
          is part of the cache key, so nothing is cached for it yet and
          API Gateway calls Lambda -> Redshift.
Warm-up - one normal request per device_id loads the cache.
Phase 2 - cache LOADED: the same requests without the header are answered
          straight from the stage cache.

Both phases send the same number of requests with the same concurrency, so
the numbers are directly comparable. Only the standard library is used.

Example:
    python cache_benchmark.py --url "$(terraform -chdir=../terraform output -raw summary_url)" \
        --requests 200 --concurrency 20
"""

import argparse
import json
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", required=True, help="summary endpoint (terraform output summary_url)")
    parser.add_argument("--requests", type=int, default=200, help="requests per phase")
    parser.add_argument("--concurrency", type=int, default=20, help="parallel requests")
    parser.add_argument(
        "--devices",
        default="apple-watch-01,apple-watch-02,apple-watch-03",
        help="comma-separated device_id values to rotate through (one cache entry each)",
    )
    parser.add_argument("--timeout", type=float, default=30.0, help="per-request timeout in seconds")
    parser.add_argument("--json-out", help="also write the results to this JSON file")
    args = parser.parse_args()
    if args.requests < 1 or args.concurrency < 1:
        parser.error("--requests and --concurrency must be >= 1")
    return args


def build_urls(base, devices, n):
    return [f"{base}?{urllib.parse.urlencode({'device_id': devices[i % len(devices)]})}" for i in range(n)]


def fetch(url, bypass_cache, timeout):
    if bypass_cache:
        url += f"&nocache={uuid.uuid4().hex}"
    req = urllib.request.Request(url)
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp.read()
            status = resp.status
    except urllib.error.HTTPError as exc:
        status = exc.code
    except Exception:  # timeout, connection reset, ...
        status = None
    return (time.perf_counter() - start) * 1000, status


def run_phase(name, urls, bypass_cache, concurrency, timeout):
    print(f"\n>> {name}: {len(urls)} requests, concurrency {concurrency} ...", flush=True)
    start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        results = list(pool.map(lambda u: fetch(u, bypass_cache, timeout), urls))
    wall = time.perf_counter() - start

    ok = sorted(ms for ms, status in results if status == 200)
    errors = len(results) - len(ok)
    if not ok:
        return {"phase": name, "requests": len(results), "errors": errors, "wall_s": round(wall, 2)}

    def pct(p):
        return ok[min(len(ok) - 1, int(round(p / 100 * (len(ok) - 1))))]

    return {
        "phase": name,
        "requests": len(results),
        "errors": errors,
        "wall_s": round(wall, 2),
        "throughput_rps": round(len(results) / wall, 1),
        "avg_ms": round(statistics.mean(ok), 1),
        "min_ms": round(ok[0], 1),
        "p50_ms": round(pct(50), 1),
        "p90_ms": round(pct(90), 1),
        "p95_ms": round(pct(95), 1),
        "p99_ms": round(pct(99), 1),
        "max_ms": round(ok[-1], 1),
    }


def print_table(rows):
    keys = ["requests", "errors", "wall_s", "throughput_rps", "avg_ms", "min_ms",
            "p50_ms", "p90_ms", "p95_ms", "p99_ms", "max_ms"]
    width = max(len(r["phase"]) for r in rows) + 2
    print("\n" + "metric".ljust(16) + "".join(r["phase"].rjust(width) for r in rows))
    print("-" * (16 + width * len(rows)))
    for k in keys:
        print(k.ljust(16) + "".join(str(r.get(k, "-")).rjust(width) for r in rows))


def main():
    args = parse_args()
    devices = [d.strip() for d in args.devices.split(",") if d.strip()]
    urls = build_urls(args.url, devices, args.requests)

    no_cache = run_phase("SIN CACHE", urls, True, args.concurrency, args.timeout)

    print("\n>> Warm-up: loading one cache entry per device_id ...", flush=True)
    for url in build_urls(args.url, devices, len(devices)):
        ms, status = fetch(url, False, args.timeout)
        print(f"   {url}  {status}  {ms:.0f} ms")
    time.sleep(3)  # new cache entries take a moment to become readable

    cached = run_phase("CON CACHE", urls, False, args.concurrency, args.timeout)

    print_table([no_cache, cached])
    if "avg_ms" in no_cache and "avg_ms" in cached:
        print(
            f"\nMejora con cache: avg {no_cache['avg_ms'] / cached['avg_ms']:.1f}x mas rapido, "
            f"p95 {no_cache['p95_ms'] / cached['p95_ms']:.1f}x, "
            f"throughput {cached['throughput_rps'] / no_cache['throughput_rps']:.1f}x"
        )

    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump({"url": args.url, "concurrency": args.concurrency, "results": [no_cache, cached]}, f, indent=2)
        print(f"Resultados guardados en {args.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
