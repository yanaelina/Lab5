"""Kinesis -> Redshift stream processor for Apple Watch step counts.

Decodes and validates a Kinesis batch, then writes the valid records with ONE
parameterized multi-row INSERT through the Redshift Data API (no VPC, no JDBC).

Failure semantics (Kinesis + ReportBatchItemFailures):
  Lambda checkpoints at the LOWEST sequence number reported as failed and
  retries from there. So we only insert the valid records that come BEFORE the
  first invalid one and report that record as the failure. Records after it are
  retried later instead of being inserted twice. With bisect-on-error the bad
  record is isolated and dropped after the configured retries, so one bad
  record never blocks the shard indefinitely.
"""

import base64
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

POLL_INTERVAL_SECONDS = 0.5
TERMINAL_STATES = {"FINISHED", "FAILED", "ABORTED"}

redshift_data = boto3.client("redshift-data")


class ValidationError(ValueError):
    pass


def parse_record(record):
    """Decode one Kinesis record and return (device_id, event_ts_iso, steps)."""
    try:
        payload = json.loads(base64.b64decode(record["kinesis"]["data"]))
    except (ValueError, KeyError, TypeError) as exc:
        raise ValidationError(f"undecodable payload: {exc}") from exc

    if not isinstance(payload, dict):
        raise ValidationError("payload is not a JSON object")

    if payload.get("metric") != "steps":
        raise ValidationError(f"unsupported metric: {payload.get('metric')!r}")

    device_id = payload.get("device_id")
    if not isinstance(device_id, str) or not device_id or len(device_id) > 64:
        raise ValidationError(f"invalid device_id: {device_id!r}")

    value = payload.get("value")
    # bool is a subclass of int, so reject it explicitly.
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValidationError(f"value must be a non-negative integer, got {value!r}")

    ts_ms = payload.get("timestamp")
    if isinstance(ts_ms, bool) or not isinstance(ts_ms, (int, float)) or ts_ms <= 0:
        raise ValidationError(f"invalid timestamp: {ts_ms!r}")
    try:
        event_ts = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc)
    except (OverflowError, OSError, ValueError) as exc:
        raise ValidationError(f"timestamp out of range: {ts_ms!r}") from exc

    # Redshift TIMESTAMP has no time zone; store UTC.
    return device_id, event_ts.strftime("%Y-%m-%d %H:%M:%S.%f"), value


def build_insert(rows):
    """Build one multi-row INSERT with named parameters (:d0, :t0, :s0, ...)."""
    values_sql = []
    parameters = []
    for i, (device_id, event_ts, steps) in enumerate(rows):
        values_sql.append(f"(:d{i}, CAST(:t{i} AS TIMESTAMP), CAST(:s{i} AS INTEGER))")
        parameters += [
            {"name": f"d{i}", "value": device_id},
            {"name": f"t{i}", "value": event_ts},
            {"name": f"s{i}", "value": str(steps)},
        ]
    sql = (
        f"INSERT INTO {TARGET_TABLE} (device_id, event_ts, steps) VALUES "
        + ", ".join(values_sql)
    )
    return sql, parameters


def execute_and_wait(sql, parameters):
    response = redshift_data.execute_statement(
        **REDSHIFT_TARGET,
        Database=DATABASE,
        Sql=sql,
        Parameters=parameters,
        StatementName="watch-steps-insert",
    )
    statement_id = response["Id"]

    while True:
        desc = redshift_data.describe_statement(Id=statement_id)
        status = desc["Status"]
        if status in TERMINAL_STATES:
            break
        time.sleep(POLL_INTERVAL_SECONDS)

    if status != "FINISHED":
        # Raise so Lambda retries the whole (still un-inserted) batch.
        raise RuntimeError(
            f"Redshift statement {statement_id} {status}: {desc.get('Error')}"
        )
    return statement_id, desc.get("ResultRows")


def lambda_handler(event, context):
    records = event.get("Records", [])
    valid_rows = []
    first_failure = None

    for record in records:
        try:
            valid_rows.append(parse_record(record))
        except ValidationError as exc:
            first_failure = record["kinesis"]["sequenceNumber"]
            logger.warning(
                "Invalid record seq=%s partitionKey=%s: %s",
                first_failure,
                record["kinesis"].get("partitionKey"),
                exc,
            )
            # Stop here: everything from this record onward is retried by Lambda.
            break

    if valid_rows:
        sql, parameters = build_insert(valid_rows)
        statement_id, inserted = execute_and_wait(sql, parameters)
        logger.info(
            "Inserted %s rows (statement %s) from %s records",
            inserted,
            statement_id,
            len(records),
        )

    if first_failure is None:
        return {"batchItemFailures": []}
    return {"batchItemFailures": [{"itemIdentifier": first_failure}]}
