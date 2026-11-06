# Phone publisher — truck #0

Turns your phone (or any machine) into the one real cold-chain device. It reads
GPS + battery temperature on Android via the **Termux API**, and falls back to
simulated values anywhere else, publishing to AWS IoT Core on the same topic and
schema a simulated truck uses.

## Certificates

`terraform apply` writes this device's certificate and private key into
`cert/` (gitignored):

```
cert/truck-0.cert.pem
cert/truck-0.private.key
```

You also need Amazon's root CA (not secret, not committed):

```bash
curl -o cert/AmazonRootCA1.pem https://www.amazontrust.com/repository/AmazonRootCA1.pem
```

## Endpoint

```bash
aws iot describe-endpoint --endpoint-type iot:Data-ATS --profile training
# -> xxxxxxxx-ats.iot.eu-central-1.amazonaws.com
```

## Run

On a laptop (simulated sensors):

```bash
pip install -r requirements.txt
python publisher.py \
  --endpoint <your>-ats.iot.eu-central-1.amazonaws.com \
  --cert cert/truck-0.cert.pem \
  --key  cert/truck-0.private.key \
  --root-ca cert/AmazonRootCA1.pem
```

On Android (real GPS + battery temp):

```bash
pkg install termux-api python
pip install paho-mqtt
# ...then the same command as above
```

Walk around → the point moves. Put the phone somewhere warm → `temperature_c`
climbs past the threshold, and once it stays there for the whole detection
window the excursion alert fires.

## Message schema

```json
{
  "device_id": "truck-0",
  "ts": "2026-10-16T18:00:00+00:00",
  "cargo_type": "vaccine",
  "temperature_c": 6.2,
  "lat": 46.948, "lon": 7.447,
  "door_open": false,
  "battery_pct": 87
}
```
