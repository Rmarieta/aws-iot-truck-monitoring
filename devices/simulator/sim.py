"""
Cold-chain fleet simulator — one ECS Fargate task == one virtual truck.

On start the task derives a stable short id from its own ECS task ARN, registers
itself as a Thing (`truck-<hash>`) in the fleet thing group, attaches the
shared `sim-fleet` certificate, and publishes telemetry on the SAME topic and
schema as the real phone device (truck-0), so it flows through the identical
ingest path. On SIGTERM (ECS scale-down / stop) it deregisters gracefully:
detaches the cert, removes itself from the group, deletes the thing.

Everything comes from the environment (injected by the task definition):
    IOT_ENDPOINT        ATS data endpoint
    FLEET_GROUP         thing group to join
    SIM_CERT_ARN        shared certificate ARN (to attach to this thing)
    SIM_CERT_PEM        shared certificate PEM        (SSM SecureString)
    SIM_PRIVATE_KEY     shared private key            (SSM SecureString)
    TELEMETRY_INTERVAL  seconds between messages (default 5)
    OFFLINE_PCT         chance per tick to simulate an offline blip (default 0)

The client-id is set to the thing name so the ThingName-scoped IoT policy
(${iot:Connection.Thing.ThingName}) resolves and confines this truck to its own
topics.
"""
from __future__ import annotations

import hashlib
import json
import os
import random
import signal
import sys
import tempfile
import time
import urllib.request
from datetime import datetime, timezone

import boto3
import paho.mqtt.client as mqtt

REGION = os.environ.get("AWS_REGION", "eu-central-1")
ENDPOINT = os.environ["IOT_ENDPOINT"]
FLEET_GROUP = os.environ["FLEET_GROUP"]
CERT_ARN = os.environ["SIM_CERT_ARN"]
INTERVAL = float(os.environ.get("TELEMETRY_INTERVAL", "5"))
OFFLINE_PCT = float(os.environ.get("OFFLINE_PCT", "0"))

iot = boto3.client("iot", region_name=REGION)

# Amazon Root CA 1 — baked into the image at build time (see Dockerfile).
ROOT_CA = "/app/AmazonRootCA1.pem"

# Swiss city centres so the fleet spreads across Switzerland instead of
# stacking on one point.
CITIES = [
    (47.376, 8.541),  # Zürich
    (46.948, 7.447),  # Bern
    (47.559, 7.588),  # Basel
    (46.204, 6.143),  # Genève
    (46.519, 6.633),  # Lausanne
    (47.050, 8.309),  # Luzern
    (47.424, 9.376),  # St. Gallen
    (46.004, 8.951),  # Lugano
    (46.850, 9.532),  # Chur
    (46.233, 7.360),  # Sion
    (47.500, 8.724),  # Winterthur
    (46.806, 7.161),  # Fribourg
]


def task_id() -> str:
    """Stable short id derived from this task's ARN (ECS metadata v4)."""
    uri = os.environ.get("ECS_CONTAINER_METADATA_URI_V4")
    arn = None
    if uri:
        try:
            with urllib.request.urlopen(f"{uri}/task", timeout=5) as r:
                arn = json.load(r).get("TaskARN")
        except Exception:
            arn = None
    # Fallback for local runs: a random seed so two local copies differ.
    seed = arn or f"local-{os.getpid()}-{random.random()}"
    return hashlib.sha1(seed.encode()).hexdigest()[:6]


def write_creds() -> tuple[str, str]:
    """Materialise the SSM-injected cert/key to files paho can read."""
    d = tempfile.mkdtemp()
    cert = os.path.join(d, "cert.pem")
    key = os.path.join(d, "key.pem")
    with open(cert, "w") as f:
        f.write(os.environ["SIM_CERT_PEM"])
    with open(key, "w") as f:
        f.write(os.environ["SIM_PRIVATE_KEY"])
    return cert, key


def build_message(device_id: str, lat: float, lon: float) -> dict:
    """Same schema as the phone publisher so the ingest path is identical."""
    return {
        "device_id": device_id,
        "ts": datetime.now(timezone.utc).isoformat(),
        "cargo_type": "frozen",
        "temperature_c": round(
            random.choice([random.uniform(2, 7)] * 9 + [random.uniform(9, 14)]), 2
        ),
        "lat": round(lat, 6),
        "lon": round(lon, 6),
        "door_open": random.random() < 0.05,
        "battery_pct": random.randint(40, 100),
    }


class Truck:
    def __init__(self) -> None:
        self.name = f"truck-{task_id()}"
        self.topic = f"coldchain/telemetry/{self.name}"
        base_lat, base_lon = random.choice(CITIES)
        self.lat = base_lat + random.uniform(-0.05, 0.05)
        self.lon = base_lon + random.uniform(-0.05, 0.05)
        self._stop = False
        self._registered = False

    # --- registry lifecycle (control plane, via IAM task role) -------------
    def register(self) -> None:
        iot.create_thing(thingName=self.name)
        iot.add_thing_to_thing_group(
            thingGroupName=FLEET_GROUP, thingName=self.name
        )
        iot.attach_thing_principal(thingName=self.name, principal=CERT_ARN)
        self._registered = True
        print(f"[{self.name}] registered + joined {FLEET_GROUP}", flush=True)

    def deregister(self) -> None:
        if not self._registered:
            return
        try:
            iot.detach_thing_principal(thingName=self.name, principal=CERT_ARN)
            iot.remove_thing_from_thing_group(
                thingGroupName=FLEET_GROUP, thingName=self.name
            )
            iot.delete_thing(thingName=self.name)
            print(f"[{self.name}] deregistered", flush=True)
        except Exception as e:  # best-effort; a hard kill may skip this
            print(f"[{self.name}] deregister error: {e}", flush=True)

    # --- data plane (MQTT over mutual TLS) ---------------------------------
    def run(self) -> None:
        cert, key = write_creds()
        c = mqtt.Client(client_id=self.name, protocol=mqtt.MQTTv311)
        c.tls_set(ca_certs=ROOT_CA, certfile=cert, keyfile=key)
        c.connect(ENDPOINT, 8883, keepalive=30)
        c.loop_start()
        print(f"[{self.name}] publishing to {self.topic} every {INTERVAL}s", flush=True)

        while not self._stop:
            # Drift slightly each tick so the dot moves.
            self.lat += random.uniform(-0.002, 0.002)
            self.lon += random.uniform(-0.002, 0.002)
            msg = build_message(self.name, self.lat, self.lon)

            # Simulated offline blip: skip publishing this tick.
            if OFFLINE_PCT and random.uniform(0, 100) < OFFLINE_PCT:
                print(f"[{self.name}] offline blip — skipping tick", flush=True)
            else:
                c.publish(self.topic, json.dumps(msg), qos=1)

            time.sleep(INTERVAL)

        c.loop_stop()
        c.disconnect()

    def stop(self) -> None:
        self._stop = True


def main() -> None:
    truck = Truck()

    def on_term(_signo, _frame):
        print(f"[{truck.name}] SIGTERM — stopping + deregistering", flush=True)
        truck.stop()

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    truck.register()
    try:
        truck.run()
    finally:
        truck.deregister()


if __name__ == "__main__":
    main()
