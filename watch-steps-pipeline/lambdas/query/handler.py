"""API Gateway GET /steps/summary -> Redshift.

Returns today's totals (UTC) and the last hour's totals per device, optionally
filtered with ?device_id=. Every call runs a query through the Redshift Data
API (execute -> poll -> fetch), which takes on the order of a second; API
Gateway caches the response per device_id so repeated calls skip all of it.
"""

import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Serverless: REDSHIFT_WORKGROUP. Provisioned: REDSHIFT_CLUSTER_ID + REDSHIFT_DB_USER.
if os.environ.get("REDSHIFT_WORKGROUP"):
    REDSHIFT_TARGET = {"WorkgroupName": os.environ["REDSHIFT_WORKGROUP"]}
else:
    REDSHIFT_TARGET = {
        "ClusterIdentifier": os.environ["REDSHIFT_CLUSTER_ID"],
        "DbUser": os.environ["REDSHIFT_DB_USER"],
    }
DATABASE = os.environ["REDSHIFT_DATABASE"]
TARGET_TABLE = os.environ.get("TARGET_TABLE", "public.watch_steps")

POLL_INTERVAL_SECONDS = 0.1
TERMINAL_STATES = {"FINISHED", "FAILED", "ABORTED"}

redshift_data = boto3.client("redshift-data")


def response(status, body, backend_ms):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            # Cached together with the body, so a cache hit returns the time the
            # original backend call took, not the (much shorter) hit itself.
            "X-Backend-Ms": str(backend_ms),
        },
        "body": json.dumps(body),
    }


def cell_value(cell):
    """Data API cells look like {"longValue": 5}, {"stringValue": "x"} or {"isNull": true}."""
    if cell.get("isNull"):
        return None
    return next(iter(cell.values()))


def run_query(sql, parameters):
    kwargs = {**REDSHIFT_TARGET, "Database": DATABASE, "Sql": sql}
    if parameters:
        kwargs["Parameters"] = parameters
    statement_id = redshift_data.execute_statement(**kwargs)["Id"]

    while True:
        desc = redshift_data.describe_statement(Id=statement_id)
        if desc["Status"] in TERMINAL_STATES:
            break
        time.sleep(POLL_INTERVAL_SECONDS)

    if desc["Status"] != "FINISHED":
        raise RuntimeError(f"Redshift statement {statement_id} {desc['Status']}: {desc.get('Error')}")
    if not desc.get("HasResultSet"):
        return []

    result = redshift_data.get_statement_result(Id=statement_id)
    columns = [c["name"] for c in result["ColumnMetadata"]]
    return [dict(zip(columns, map(cell_value, row))) for row in result["Records"]]


def lambda_handler(event, context):
    started = time.monotonic()
    device_id = (event.get("queryStringParameters") or {}).get("device_id")

    where = "WHERE event_ts >= TRUNC(GETDATE())"
    parameters = []
    if device_id:
        where += " AND device_id = :device_id"
        parameters.append({"name": "device_id", "value": device_id})

    sql = (
        "SELECT device_id, "
        "SUM(steps) AS steps_today, "
        "SUM(CASE WHEN event_ts >= DATEADD(hour, -1, GETDATE()) THEN steps ELSE 0 END) AS steps_last_hour, "
        "COUNT(*) AS events_today, "
        "MAX(event_ts) AS last_event_ts "
        f"FROM {TARGET_TABLE} {where} "
        "GROUP BY device_id ORDER BY device_id"
    )

    try:
        rows = run_query(sql, parameters)
    except Exception:
        logger.exception("summary query failed")
        backend_ms = int((time.monotonic() - started) * 1000)
        return response(502, {"error": "query failed"}, backend_ms)

    backend_ms = int((time.monotonic() - started) * 1000)
    logger.info("summary device_id=%s rows=%s backend_ms=%s", device_id, len(rows), backend_ms)
    return response(
        200,
        {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "device_id": device_id,
            "devices": rows,
        },
        backend_ms,
    )
