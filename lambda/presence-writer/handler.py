"""
Presence writer — turns IoT Core connection lifecycle events into a per-device
connection-state record in DynamoDB.

AWS IoT Core publishes lifecycle events to reserved topics when a device's MQTT
connection changes. An IoT Topic Rule forwards them here, and this function
upserts the current state onto the device's item in the `devices` table
(PK = device_id). Readers get one item per device showing ONLINE/OFFLINE and
when it last changed.

This stores CURRENT state (overwritten in place), not history — a single-digit-ms
point lookup of "what is this device right now", which is what DynamoDB is for.

Event shape (raw IoT presence MQTT payload, top-level fields):
  eventType        "connected" | "disconnected"
  clientId         the MQTT client id (equal to device_id; the publisher sets
                   client_id = device_id)
  timestamp        epoch ms of the lifecycle event
  disconnectReason present on disconnect, e.g. MQTT_KEEP_ALIVE_TIMEOUT,
                   CLIENT_INITIATED_DISCONNECT, CONNECTION_LOST
"""
from __future__ import annotations

import os
from datetime import datetime, timezone

import boto3

TABLE = os.environ["DEVICES_TABLE"]

_table = boto3.resource("dynamodb").Table(TABLE)

_STATE = {"connected": "ONLINE", "disconnected": "OFFLINE"}


def handler(event, _context):
    detail = event or {}
    event_type = detail.get("eventType")
    device_id = detail.get("clientId")

    # Ignore anything we cannot map to a device and a known state, rather than
    # writing a garbage item — a malformed event must not corrupt state.
    if not device_id or event_type not in _STATE:
        print(f"[presence] ignoring event_type={event_type!r} device_id={device_id!r}")
        return {"ignored": True, "event_type": event_type, "device_id": device_id}

    state = _STATE[event_type]

    # Prefer the broker's own event time (epoch ms); fall back to now.
    ts_ms = detail.get("timestamp")
    if isinstance(ts_ms, (int, float)):
        changed_at = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).isoformat()
    else:
        changed_at = datetime.now(timezone.utc).isoformat()

    expr_values = {":s": state, ":t": changed_at}

    if state == "OFFLINE":
        # Record the reason so a clean disconnect (CLIENT_INITIATED) can be told
        # apart from an ungraceful drop (keep-alive timeout, connection lost).
        reason = detail.get("disconnectReason")
        if reason:
            update = "SET conn_state = :s, conn_changed_at = :t, disconnect_reason = :r"
            expr_values[":r"] = reason
        else:
            update = "SET conn_state = :s, conn_changed_at = :t REMOVE disconnect_reason"
    else:
        # On reconnect clear the stale reason so it never lingers on an ONLINE item.
        update = "SET conn_state = :s, conn_changed_at = :t REMOVE disconnect_reason"

    _table.update_item(
        Key={"device_id": device_id},
        UpdateExpression=update,
        ExpressionAttributeValues=expr_values,
    )

    print(f"[presence] {device_id} -> {state} at {changed_at}")
    return {"device_id": device_id, "conn_state": state, "conn_changed_at": changed_at}
