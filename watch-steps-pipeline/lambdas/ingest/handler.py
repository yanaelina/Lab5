"""API Gateway POST /steps -> Kinesis.

Accepts one event object, a JSON array of events, or {"records": [...]}, and
writes them to Kinesis with put_records using device_id as the partition key.
Full validation happens in the processor; here we only check what Kinesis
needs (a JSON object with a device_id) so the request path stays fast.
"""

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

STREAM_NAME = os.environ["STREAM_NAME"]
MAX_RECORDS = 500  # put_records limit per call

kinesis = boto3.client("kinesis")


def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    try:
        payload = json.loads(event.get("body") or "")
    except (TypeError, ValueError):
        return response(400, {"error": "body must be valid JSON"})

    if isinstance(payload, dict) and "records" in payload:
        payload = payload["records"]
    events = payload if isinstance(payload, list) else [payload]

    if not events or len(events) > MAX_RECORDS:
        return response(400, {"error": f"send between 1 and {MAX_RECORDS} events"})

    records = []
    for e in events:
        if not isinstance(e, dict) or not isinstance(e.get("device_id"), str) or not e["device_id"]:
            return response(400, {"error": "every event must be an object with a device_id"})
        records.append({"Data": json.dumps(e).encode("utf-8"), "PartitionKey": e["device_id"]})

    result = kinesis.put_records(StreamName=STREAM_NAME, Records=records)
    failed = result.get("FailedRecordCount", 0)
    if failed:
        logger.warning("put_records: %s of %s records failed", failed, len(records))

    return response(200 if not failed else 207, {"accepted": len(records) - failed, "failed": failed})
