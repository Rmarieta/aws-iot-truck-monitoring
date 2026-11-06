"""
Excursion forwarder — Kinesis -> EventBridge.

Flink writes detected conditions to the output Kinesis stream; this Lambda
reads them and publishes one event per record onto EventBridge, where the
matching rule routes it. Kept deliberately thin: no business logic, just a
typed bridge between the two services. The record's `type` discriminator
selects the EventBridge DetailType so the bus can route each kind separately:

    type = 'excursion'           -> DetailType 'excursion.detected'
    type = 'battery_low_moving'  -> DetailType 'battery.low_moving'
"""
from __future__ import annotations

import base64
import json
import os

import boto3

BUS = os.environ["EVENT_BUS_NAME"]
SOURCE = "coldchain.excursion-detector"

# Map the Flink `type` discriminator to an EventBridge DetailType.
_DETAIL_TYPE = {
    "excursion": "excursion.detected",
    "battery_low_moving": "battery.low_moving",
}

_events = boto3.client("events")


def handler(event, _context):
    entries = []
    for record in event.get("Records", []):
        payload = base64.b64decode(record["kinesis"]["data"]).decode("utf-8")
        try:
            detail = json.loads(payload)
        except json.JSONDecodeError:
            continue
        # Default to excursion for backward compatibility if `type` is absent.
        record_type = detail.get("type", "excursion")
        detail_type = _DETAIL_TYPE.get(record_type, "excursion.detected")
        # Idempotency key the workflow can dedupe on (type-scoped).
        detail["excursion_id"] = (
            f'{record_type}#{detail.get("device_id")}#{detail.get("window_start")}'
        )
        entries.append(
            {
                "Source": SOURCE,
                "DetailType": detail_type,
                "Detail": json.dumps(detail),
                "EventBusName": BUS,
            }
        )

    # EventBridge PutEvents accepts max 10 entries per call.
    for i in range(0, len(entries), 10):
        _events.put_events(Entries=entries[i : i + 10])

    return {"forwarded": len(entries)}
