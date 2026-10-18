#!/usr/bin/env python3
"""Simulate Apple Watches sending incremental step counts (via API Gateway or straight to Kinesis).

Each device has an activity state (rest / walking / running) that changes at
random. Every interval it sends the steps taken since its last event, using
device_id as the partition key so each device's events stay ordered.

With --api-url the events are POSTed to API Gateway (POST /steps), which
forwards them to Kinesis. Without it they are written to Kinesis directly.

Example:
    python simulate_watch_steps.py --api-url "$(terraform -chdir=../terraform output -raw api_base_url)"
    python simulate_watch_steps.py --duration 300 --interval 5 --devices 3
"""

import argparse
import json
import random
import signal
import sys
import time
import urllib.request

# Steps per second for each activity (randomized per event).
ACTIVITIES = {
    "rest": (0, 0),
    "walking": (1.0, 3.0),   # ~5-15 steps per 5 s
    "running": (4.0, 6.0),   # ~20-30 steps per 5 s
}
# Probability of switching activity on each tick, and the weights used to pick the next one.
SWITCH_PROBABILITY = 0.15
NEXT_ACTIVITY_WEIGHTS = {"rest": 0.4, "walking": 0.45, "running": 0.15}


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--api-url", help="API Gateway base URL; events go to POST <api-url>/steps")
    parser.add_argument("--stream", default="watch-steps-stream", help="Kinesis stream name")
    parser.add_argument("--profile", default="academy", help="AWS CLI profile")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    parser.add_argument("--devices", type=int, default=3, help="number of simulated watches")
    parser.add_argument("--interval", type=float, default=5.0, help="seconds between events")
    parser.add_argument(
        "--duration", type=float, default=300.0, help="total seconds to run (0 = until Ctrl+C)"
    )
    parser.add_argument("--seed", type=int, default=None, help="random seed for reproducibility")
    args = parser.parse_args()
    if args.devices < 1 or args.interval <= 0 or args.duration < 0:
        parser.error("--devices must be >= 1, --interval > 0 and --duration >= 0")
    return args


class Watch:
    def __init__(self, device_id):
        self.device_id = device_id
        self.activity = random.choice(list(ACTIVITIES))

    def next_steps(self, interval):
        if random.random() < SWITCH_PROBABILITY:
            self.activity = random.choices(
                list(NEXT_ACTIVITY_WEIGHTS), weights=NEXT_ACTIVITY_WEIGHTS.values()
            )[0]
        low, high = ACTIVITIES[self.activity]
        return int(round(random.uniform(low, high) * interval))


def build_event(watch, steps):
    return {
        "device_id": watch.device_id,
        "device_type": "apple_watch",
        "metric": "steps",
        "value": steps,
        "unit": "count",
        "timestamp": int(time.time() * 1000),
    }


def post_to_api(api_url, events):
    """POST a batch to API Gateway; returns the number of failed records."""
    req = urllib.request.Request(
        f"{api_url.rstrip('/')}/steps",
        data=json.dumps(events).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read()).get("failed", 0)


def main():
    args = parse_args()
    if args.seed is not None:
        random.seed(args.seed)

    if args.api_url:
        target = f"{args.api_url.rstrip('/')}/steps"
    else:
        import boto3  # only needed for direct Kinesis mode; --api-url uses the stdlib only

        session = boto3.Session(profile_name=args.profile, region_name=args.region)
        kinesis = session.client("kinesis")
        target = f"'{args.stream}' ({args.region})"

    watches = [Watch(f"apple-watch-{i:02d}") for i in range(1, args.devices + 1)]
    deadline = time.monotonic() + args.duration if args.duration else None

    stop = False

    def handle_sigint(signum, frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handle_sigint)

    print(
        f"Sending to {target} every {args.interval}s "
        f"from {len(watches)} watches. Ctrl+C to stop."
    )
    sent_total = 0
    while not stop and (deadline is None or time.monotonic() < deadline):
        tick_start = time.monotonic()
        events = [build_event(w, w.next_steps(args.interval)) for w in watches]
        records = [
            {"Data": json.dumps(e).encode("utf-8"), "PartitionKey": e["device_id"]}
            for e in events
        ]

        try:
            if args.api_url:
                failed = post_to_api(args.api_url, events)
            else:
                response = kinesis.put_records(StreamName=args.stream, Records=records)
                failed = response.get("FailedRecordCount", 0)
        except Exception as exc:  # e.g. expired Academy credentials, HTTP error
            print(f"send failed: {exc}", file=sys.stderr)
            return 1

        sent_total += len(records) - failed
        summary = ", ".join(
            f"{w.device_id}={e['value']:>2} ({w.activity})" for w, e in zip(watches, events)
        )
        print(f"[{time.strftime('%H:%M:%S')}] {summary}" + (f"  FAILED={failed}" if failed else ""))

        time.sleep(max(0.0, args.interval - (time.monotonic() - tick_start)))

    print(f"Done. {sent_total} records sent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
