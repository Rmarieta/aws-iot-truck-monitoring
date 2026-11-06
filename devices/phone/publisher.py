#!/usr/bin/env python3
"""
Cold-chain phone publisher — turns your phone into "truck #0".

Reads real sensors where available (GPS + battery temperature via the Termux
API on Android) and publishes a telemetry message to AWS IoT Core over mutual
TLS, on the same topic/schema a simulated truck uses. Falls back to simulated
values on any platform without Termux so it still runs on a laptop.

Run (Android/Termux):
    pkg install termux-api python
    pip install paho-mqtt
    python publisher.py \
        --endpoint <xxxx>-ats.iot.eu-central-1.amazonaws.com \
        --device-id truck-0 \
        --cert   cert/truck-0.cert.pem \
        --key    cert/truck-0.private.key \
        --root-ca cert/AmazonRootCA1.pem

The IoT endpoint:   aws iot describe-endpoint --endpoint-type iot:Data-ATS
The Amazon root CA: https://www.amazontrust.com/repository/AmazonRootCA1.pem
"""
from __future__ import annotations

import argparse
import json
import random
import shutil
import subprocess
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt


def _termux(cmd: list[str]) -> dict | None:
    """Call a termux-api command, return parsed JSON or None if unavailable."""
    if not shutil.which(cmd[0]):
        return None
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return json.loads(out.stdout) if out.stdout.strip() else None
    except (subprocess.SubprocessError, json.JSONDecodeError):
        return None


def read_location() -> tuple[float, float]:
    """Real GPS via termux-location, else a jittered point near Bern."""
    data = _termux(["termux-location", "-p", "gps", "-r", "once"])
    if data and "latitude" in data:
        return float(data["latitude"]), float(data["longitude"])
    return 46.948 + random.uniform(-0.02, 0.02), 7.447 + random.uniform(-0.02, 0.02)


# Test-mode "driving" state: a position that advances steadily each tick so a
# 10-minute window clears the ~500 m movement epsilon deterministically,
# without real GPS or physically travelling. ~0.0006 deg/tick (~65 m) at the
# default 5 s interval covers well over 500 m within a 10-minute window.
_DRIVE_STATE = {"lat": 46.948, "lon": 7.447}
_DRIVE_STEP = 0.0006


def drive_location() -> tuple[float, float]:
    """Simulate a truck driving: advance NE a fixed step each call."""
    _DRIVE_STATE["lat"] += _DRIVE_STEP
    _DRIVE_STATE["lon"] += _DRIVE_STEP
    return _DRIVE_STATE["lat"], _DRIVE_STATE["lon"]


def read_temperature() -> float:
    """Battery temperature (°C) via termux-battery-status, else simulated cargo temp."""
    data = _termux(["termux-battery-status"])
    if data and "temperature" in data:
        return round(float(data["temperature"]), 2)
    # simulated reefer: mostly in-range, occasional warm excursion
    return round(random.choice([random.uniform(2, 7)] * 9 + [random.uniform(9, 14)]), 2)


def read_battery(override: int | None) -> int:
    """Battery % — forced value if --battery given, else real (Termux) or simulated."""
    if override is not None:
        return override
    data = _termux(["termux-battery-status"])
    if data and "percentage" in data:
        return int(data["percentage"])
    return random.randint(40, 100)


def build_message(device_id: str, cargo: str, *, drive: bool, battery: int | None) -> dict:
    lat, lon = drive_location() if drive else read_location()
    return {
        "device_id": device_id,
        "ts": datetime.now(timezone.utc).isoformat(),
        "cargo_type": cargo,
        "temperature_c": read_temperature(),
        "lat": round(lat, 6),
        "lon": round(lon, 6),
        "door_open": random.random() < 0.05,
        "battery_pct": read_battery(battery),
    }


# --- Store-and-forward buffer ---------------------------------------------
# When the MQTT link is down, readings are appended (one JSON object per line)
# to a local file instead of being dropped. On reconnect they are replayed in
# the ORDER they were recorded, each keeping its original reading-time `ts`, so
# the time-series backfills with no hole. On-disk (not in-memory) so the buffer
# survives a process restart or power loss — the very outage it exists for.


def buffer_append(path: str, msg: dict) -> None:
    """Append one reading to the local buffer (create the file if needed)."""
    with open(path, "a") as f:
        f.write(json.dumps(msg) + "\n")


def buffer_count(path: str) -> int:
    try:
        with open(path) as f:
            return sum(1 for _ in f)
    except FileNotFoundError:
        return 0


def buffer_drain(path: str, publish) -> int:
    """Replay buffered readings in order via `publish(msg) -> bool`.

    Stops at the first failure and keeps the UNSENT remainder in the file, so a
    mid-replay disconnect never loses or reorders readings. Returns how many
    were sent. Rewrites the file with whatever is left.
    """
    try:
        with open(path) as f:
            lines = f.readlines()
    except FileNotFoundError:
        return 0

    sent = 0
    for i, line in enumerate(lines):
        line = line.strip()
        if not line:
            sent += 1
            continue
        if publish(json.loads(line)):
            sent += 1
        else:
            # Keep this line and everything after it for the next attempt.
            with open(path, "w") as f:
                f.writelines(lines[i:])
            return sent

    # All replayed — clear the buffer.
    with open(path, "w") as f:
        f.truncate(0)
    return sent


def main() -> None:
    p = argparse.ArgumentParser(description="Cold-chain phone publisher (truck #0)")
    p.add_argument("--endpoint", required=True, help="IoT Core ATS data endpoint")
    p.add_argument("--device-id", default="truck-0")
    p.add_argument("--cert", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--root-ca", required=True)
    p.add_argument("--cargo", default="vaccine")
    p.add_argument("--interval", type=float, default=5.0, help="seconds between messages")
    p.add_argument(
        "--drive",
        action="store_true",
        help="simulate a moving truck (position advances each tick) to test the "
        "battery-low-while-moving detector deterministically",
    )
    p.add_argument(
        "--battery",
        type=int,
        default=None,
        metavar="PCT",
        help="force a fixed battery percentage (e.g. --battery 15 to trigger "
        "the low-battery condition); omit to use real/simulated battery",
    )
    p.add_argument(
        "--buffer-file",
        default="telemetry-buffer.jsonl",
        help="local store-and-forward buffer: readings taken while offline are "
        "appended here and replayed in order on reconnect",
    )
    args = p.parse_args()

    topic = f"coldchain/telemetry/{args.device_id}"

    client = mqtt.Client(client_id=args.device_id, protocol=mqtt.MQTTv311)
    client.tls_set(ca_certs=args.root_ca, certfile=args.cert, keyfile=args.key)

    # Surface connection outcome: paho's connect() can return without error while
    # the TLS/MQTT handshake fails ASYNCHRONOUSLY — without these callbacks the
    # script would happily "publish" to a dead connection and print as if it
    # worked. rc=0 means CONNACK accepted; anything else is a real failure.
    connected = {"ok": False}

    def on_connect(_c, _u, _flags, rc):
        if rc == 0:
            connected["ok"] = True
            print(f"[mqtt] CONNECTED to {args.endpoint} (rc=0)")
        else:
            print(f"[mqtt] CONNECT FAILED rc={rc} ({mqtt.connack_string(rc)})")

    def on_disconnect(_c, _u, rc):
        connected["ok"] = False
        if rc == 0:
            print("[mqtt] DISCONNECTED rc=0 (clean)")
        elif rc == 7:
            # rc=7 = the broker closed the connection. In normal operation this
            # is a transient network drop (cell/wifi blip) — store-and-forward
            # buffers through it and replays on reconnect, so it is not fatal.
            # If it happens on the FIRST connect and never recovers, the usual
            # cause is a policy gap: AWS validates the Last-Will topic's publish
            # permission at CONNECT time, so an unauthorized will topic is
            # rejected here with no CONNACK. A duplicate client-id does it too.
            print("[mqtt] DISCONNECTED rc=7 — connection lost "
                  "(network drop, or will-topic/policy if it never connects). "
                  "Buffering and retrying.")
        else:
            print(f"[mqtt] DISCONNECTED rc={rc} (unexpected — check "
                  "cert/policy/network/clock)")

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect

    # Last Will: an UNGRACEFUL drop (crash/dead battery) is distinguishable from
    # a clean disconnect — IoT Core publishes this when the connection dies.
    # Published to a SEPARATE status topic (NOT coldchain/telemetry/...), because
    # this message has no `ts` and the telemetry rule forwards to Kinesis/Flink,
    # where a ts-less record parses to a null rowtime and crash-loops the job.
    # Status events are a different concern and belong on a different topic.
    client.will_set(
        f"coldchain/status/{args.device_id}",
        json.dumps({"device_id": args.device_id, "event": "offline_ungraceful"}),
        qos=1,
        retain=False,
    )

    print(f"[mqtt] connecting to {args.endpoint}:8883 as client-id "
          f"'{args.device_id}' …")
    client.connect(args.endpoint, 8883, keepalive=30)
    client.loop_start()

    # Wait briefly for the first CONNACK. Unlike before we do NOT abort if it
    # fails — store-and-forward means readings taken while offline are buffered
    # locally and replayed on reconnect, so the loop runs regardless.
    for _ in range(50):  # up to ~5s
        if connected["ok"]:
            break
        time.sleep(0.1)
    if not connected["ok"]:
        print("[mqtt] not connected yet — buffering readings locally until the "
              "link comes up.")

    pending = buffer_count(args.buffer_file)
    if pending:
        print(f"[buffer] {pending} reading(s) already buffered from a prior run.")

    print(f"publishing to {topic} every {args.interval}s "
          f"(buffer: {args.buffer_file})")

    def publish_one(m: dict) -> bool:
        """Publish one message; return True only on a confirmed QoS1 delivery."""
        if not connected["ok"]:
            return False
        info = client.publish(topic, json.dumps(m), qos=1)
        try:
            info.wait_for_publish(timeout=5)
        except (ValueError, RuntimeError):
            return False
        return info.is_published()

    def fmt(m: dict, extra: str = "") -> str:
        flags = ""
        if m["temperature_c"] > 8:
            flags += " EXCURSION?"
        if m["battery_pct"] < 20:
            flags += " LOW-BATT"
        return (f"{m['ts']}  {m['temperature_c']}°C  batt {m['battery_pct']}%  "
                f"({m['lat']},{m['lon']}){flags}{extra}")

    try:
        while True:
            # On (re)connection, drain the buffer FIRST so backfilled readings
            # arrive in order ahead of the current live one.
            if connected["ok"] and buffer_count(args.buffer_file):
                n = buffer_drain(args.buffer_file, publish_one)
                if n:
                    left = buffer_count(args.buffer_file)
                    print(f"[buffer] replayed {n} reading(s); {left} remaining")

            msg = build_message(
                args.device_id, args.cargo, drive=args.drive, battery=args.battery
            )

            if publish_one(msg):
                print(f"-> ✓ {fmt(msg)}")
            else:
                # Offline or delivery not confirmed — buffer it for replay.
                buffer_append(args.buffer_file, msg)
                print(f"-> ⧖ BUFFERED {fmt(msg)}  (offline, {buffer_count(args.buffer_file)} queued)")

            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
