"""
Dashboard API — cold-chain telemetry read endpoints backed by Timestream.

GET /readings?device_id=truck-0&minutes=30
  -> [{device_id, time, temperature_c, lat, lon, battery_pct, ...}, ...]
     Raw rows for the window, one object per reading (measures pivoted back).

GET /stats?device_id=truck-0&minutes=30
  -> {device_id, window_minutes, sample_count,
      avg_temperature_c, min_temperature_c, max_temperature_c}
     Temperature aggregates computed IN Timestream (not in the Lambda), so we
     scan/return a single row instead of hauling raw rows to the client.

GET /devices?minutes=30
  -> [{device_id, time, temperature_c, lat, lon, battery_pct, ...}, ...]
     The LATEST reading for EVERY device seen in the window, one object per
     device — the fleet view's map plots one marker per entry.

Timestream stores each telemetry field as a separate multi-measure row keyed
by `measure_name`; /readings pivots those rows back into one object per
reading, while /stats filters to the temperature measure and aggregates it.
"""
from __future__ import annotations

import json
import os

import boto3
from botocore.exceptions import ClientError

DB = os.environ["TIMESTREAM_DB"]
TABLE = os.environ["TIMESTREAM_TABLE"]
DEVICES_TABLE = os.environ["DYNAMODB_TABLE"]

_query = boto3.client("timestream-query")

# Resource (not client): get_item returns native Python types, no {"S": ...}
# attribute-value wrappers to unwrap.
_devices = boto3.resource("dynamodb").Table(DEVICES_TABLE)

_CORS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Content-Type": "application/json",
}


def _resp(status: int, body) -> dict:
    return {"statusCode": status, "headers": _CORS, "body": json.dumps(body)}


def _window_params(event) -> tuple[str, int]:
    """Shared query params: device_id + a clamped (1..1440 min) window."""
    params = (event or {}).get("queryStringParameters") or {}
    device_id = params.get("device_id", "truck-0")
    try:
        minutes = max(1, min(int(params.get("minutes", "30")), 1440))
    except (TypeError, ValueError):
        minutes = 30
    return device_id, minutes


def _run(sql: str) -> dict:
    """Run a Timestream query and return ALL pages as one result.

    Timestream paginates results (and may return a short or empty page with a
    NextToken while more rows are pending), so a single query() call can miss
    data. The paginator follows NextToken until the result is complete. The
    return value has the same ColumnInfo / Rows shape as a query() response.
    """
    column_info: list[dict] = []
    rows: list[dict] = []
    for page in _query.get_paginator("query").paginate(QueryString=sql):
        if not column_info:
            column_info = page["ColumnInfo"]
        rows.extend(page["Rows"])
    return {"ColumnInfo": column_info, "Rows": rows}


def readings(device_id: str, minutes: int) -> dict:
    # device_id is a dimension; the measure name/value columns hold the fields.
    # ago() keeps the scan bounded to the requested window.
    sql = f"""
        SELECT device_id,
               time,
               measure_name,
               measure_value::double  AS v_double,
               measure_value::boolean AS v_bool,
               measure_value::varchar AS v_str
        FROM "{DB}"."{TABLE}"
        WHERE device_id = '{device_id}'
          AND time BETWEEN ago({minutes}m) AND now()
        ORDER BY time DESC
        LIMIT 2000
    """

    try:
        result = _run(sql)
    except _query.exceptions.ValidationException as e:
        return _resp(400, {"error": str(e)})

    cols = [c["Name"] for c in result["ColumnInfo"]]
    # Group rows back into one reading per (device_id, time).
    grouped: dict[tuple, dict] = {}
    for row in result["Rows"]:
        cells = [d.get("ScalarValue") for d in row["Data"]]
        rec = dict(zip(cols, cells))
        key = (rec["device_id"], rec["time"])
        r = grouped.setdefault(key, {"device_id": rec["device_id"], "time": rec["time"]})
        name = rec.get("measure_name")
        if rec.get("v_double") is not None:
            r[name] = float(rec["v_double"])
        elif rec.get("v_bool") is not None:
            r[name] = rec["v_bool"] == "true"
        elif rec.get("v_str") is not None:
            r[name] = rec["v_str"]

    out = sorted(grouped.values(), key=lambda r: r["time"], reverse=True)
    return _resp(200, out)


def devices(minutes: int) -> dict:
    """Latest reading for every device seen in the window — one row per device.

    Timestream has no clean 'latest full row per group' in a single query, so
    we scan the window (all devices, bounded by time + LIMIT), pivot the
    multi-measure rows back into readings, then keep the newest reading per
    device_id in the Lambda. Fine for a demo-scale fleet; at large scale this
    would move to a per-device latest-row query or a materialized 'current
    state' store.
    """
    sql = f"""
        SELECT device_id,
               time,
               measure_name,
               measure_value::double  AS v_double,
               measure_value::boolean AS v_bool,
               measure_value::varchar AS v_str
        FROM "{DB}"."{TABLE}"
        WHERE time BETWEEN ago({minutes}m) AND now()
        ORDER BY time DESC
        LIMIT 20000
    """

    try:
        result = _run(sql)
    except _query.exceptions.ValidationException as e:
        return _resp(400, {"error": str(e)})

    cols = [c["Name"] for c in result["ColumnInfo"]]
    # Group rows back into one reading per (device_id, time).
    grouped: dict[tuple, dict] = {}
    for row in result["Rows"]:
        cells = [d.get("ScalarValue") for d in row["Data"]]
        rec = dict(zip(cols, cells))
        key = (rec["device_id"], rec["time"])
        r = grouped.setdefault(key, {"device_id": rec["device_id"], "time": rec["time"]})
        name = rec.get("measure_name")
        if rec.get("v_double") is not None:
            r[name] = float(rec["v_double"])
        elif rec.get("v_bool") is not None:
            r[name] = rec["v_bool"] == "true"
        elif rec.get("v_str") is not None:
            r[name] = rec["v_str"]

    # Collapse to the newest reading per device (rows are already time DESC, so
    # the first one we see for a device is its latest).
    latest: dict[str, dict] = {}
    for reading in grouped.values():
        did = reading["device_id"]
        if did not in latest or reading["time"] > latest[did]["time"]:
            latest[did] = reading

    out = sorted(latest.values(), key=lambda r: r["device_id"])
    return _resp(200, out)


def stats(device_id: str, minutes: int) -> dict:
    # Aggregate the temperature measure IN Timestream. One row, one scan —
    # much cheaper than returning raw rows and averaging in the Lambda.
    # No ORDER BY / LIMIT: an aggregate collapses the window to a single row.
    sql = f"""
        SELECT COUNT(*)                   AS sample_count,
               AVG(measure_value::double) AS avg_temperature_c,
               MIN(measure_value::double) AS min_temperature_c,
               MAX(measure_value::double) AS max_temperature_c
        FROM "{DB}"."{TABLE}"
        WHERE device_id = '{device_id}'
          AND measure_name = 'temperature_c'
          AND time BETWEEN ago({minutes}m) AND now()
    """

    try:
        result = _run(sql)
    except _query.exceptions.ValidationException as e:
        return _resp(400, {"error": str(e)})

    # Exactly one row; each cell is a string or absent (null aggregate on an
    # empty window). Map columns -> values and coerce defensively.
    cols = [c["Name"] for c in result["ColumnInfo"]]
    row = result["Rows"][0]["Data"] if result["Rows"] else []
    cells = {name: d.get("ScalarValue") for name, d in zip(cols, row)}

    def _num(v):
        return float(v) if v is not None else None

    count = int(cells.get("sample_count") or 0)
    body = {
        "device_id": device_id,
        "window_minutes": minutes,
        "sample_count": count,
        # On an empty window AVG/MIN/MAX come back null; surface that honestly
        # rather than inventing a 0, and sample_count=0 explains why.
        "avg_temperature_c": _num(cells.get("avg_temperature_c")) if count else None,
        "min_temperature_c": _num(cells.get("min_temperature_c")) if count else None,
        "max_temperature_c": _num(cells.get("max_temperature_c")) if count else None,
    }
    return _resp(200, body)

def status(device_id: str) -> dict:
    # Current connection state lives in DynamoDB (written by the presence
    # writer), a single-item point lookup — not a time-series query.
    try:
        result = _devices.get_item(Key={"device_id": device_id})
    except ClientError as e:
        return _resp(400, {"error": e.response["Error"]["Message"]})

    item = result.get("Item")
    if not item:
        # No presence event seen yet for this device.
        body = {
            "device_id": device_id,
            "conn_state": "UNKNOWN",
            "conn_changed_at": None,
            "disconnect_reason": None,
        }
    else:
        body = {
            "device_id": device_id,
            "conn_state": item.get("conn_state", "UNKNOWN"),
            "conn_changed_at": item.get("conn_changed_at"),
            # Only meaningful while OFFLINE; absent otherwise.
            "disconnect_reason": item.get("disconnect_reason"),
        }
    return _resp(200, body)


def handler(event, _context):
    device_id, minutes = _window_params(event)
    path = (event or {}).get("rawPath", "")

    if path == "/readings":
        return readings(device_id, minutes)
    if path == "/stats":
        return stats(device_id, minutes)
    if path == "/status":
        return status(device_id)
    if path == "/devices":
        # Fleet-wide: no single device_id, just the window.
        return devices(minutes)
    return _resp(404, {"error": f"no route for {path!r}"})
