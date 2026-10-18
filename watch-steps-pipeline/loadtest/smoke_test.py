#!/usr/bin/env python3
"""End-to-end check of the deployed API (standard library only).

1. POST /steps with a valid event          -> 200 {"accepted": 1}
2. POST /steps with an invalid body        -> 400
3. GET /steps/summary (cache bypassed) until the event shows up in Redshift,
   which proves API Gateway -> Lambda -> Kinesis -> Lambda -> Redshift works
4. GET /steps/summary bypassing vs using the cache -> cached call is faster

A unique device_id is used on every run so old data and cache entries don't interfere.

Example:
    python3 smoke_test.py --api-url "$(terraform -chdir=../terraform output -raw api_base_url)"
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


def request(method, url, body=None, headers=None, timeout=30):
    data = json.dumps(body).encode("utf-8") if body is not None and not isinstance(body, bytes) else body
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status, raw, resp_headers = resp.status, resp.read(), resp.headers
    except urllib.error.HTTPError as exc:
        status, raw, resp_headers = exc.code, exc.read(), exc.headers
    ms = (time.perf_counter() - start) * 1000
    try:
        payload = json.loads(raw)
    except ValueError:
        payload = raw.decode("utf-8", "replace")
    return status, payload, resp_headers, ms


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--api-url", required=True, help="terraform output api_base_url")
    parser.add_argument("--wait", type=float, default=120, help="seconds to wait for the row in Redshift")
    args = parser.parse_args()

    api = args.api_url.rstrip("/")
    device_id = f"smoke-test-{int(time.time())}"
    steps = 42
    summary_url = f"{api}/steps/summary?{urllib.parse.urlencode({'device_id': device_id})}"
    results = []

    def check(name, ok, detail):
        results.append(ok)
        print(f"[{'PASS' if ok else 'FAIL'}] {name}: {detail}", flush=True)

    # 1. Valid event
    event = {"device_id": device_id, "device_type": "apple_watch", "metric": "steps",
             "value": steps, "unit": "count", "timestamp": int(time.time() * 1000)}
    status, body, _, ms = request("POST", f"{api}/steps", event, {"Content-Type": "application/json"})
    check("POST /steps (valid)", status == 200 and isinstance(body, dict) and body.get("accepted") == 1,
          f"HTTP {status} {body} in {ms:.0f} ms")

    # 2. Invalid body
    status, body, _, ms = request("POST", f"{api}/steps", b"not json", {"Content-Type": "application/json"})
    check("POST /steps (invalid)", status == 400, f"HTTP {status} {body}")

    def uncached():
        # A new nocache value is a cache key that was never loaded -> goes to Redshift.
        return f"{summary_url}&nocache={uuid.uuid4().hex}"

    # 3. Event reaches Redshift (bypass the cache on every poll)
    print(f"... waiting up to {args.wait:.0f}s for {device_id} to appear in Redshift", flush=True)
    deadline = time.monotonic() + args.wait
    found = None
    while time.monotonic() < deadline:
        status, body, _, _ = request("GET", uncached())
        devices = body.get("devices", []) if status == 200 and isinstance(body, dict) else []
        if devices and devices[0].get("steps_today") == steps:
            found = devices[0]
            break
        time.sleep(5)
    waited = args.wait - max(0.0, deadline - time.monotonic())
    check("End-to-end to Redshift", found is not None,
          f"{found} after ~{waited:.0f}s" if found else f"not found (last HTTP {status}: {body})")

    # 4. Cache: an uncached call goes to Redshift; the same URL again is a hit
    url = uncached()
    status1, _, _, ms1 = request("GET", url)
    # The new entry takes a moment to become readable; keep the fastest of 3 calls.
    time.sleep(2)
    status2, _, headers2, ms2 = min((request("GET", url) for _ in range(3)), key=lambda r: r[3])
    status2 = status2 if status2 == 200 else None
    check("GET /steps/summary cached", status1 == status2 == 200 and ms2 < ms1 / 2,
          f"without cache {ms1:.0f} ms, with cache {ms2:.0f} ms (X-Backend-Ms={headers2.get('X-Backend-Ms')})")

    passed = sum(results)
    print(f"\n{passed}/{len(results)} checks passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
