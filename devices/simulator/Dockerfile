# Fleet simulator — one container == one virtual truck.
FROM python:3.12-slim

WORKDIR /app

# Amazon Root CA 1 for the mutual-TLS connection to IoT Core. Fetched at build
# time so the image is self-contained (the CA is public, not a secret).
ADD https://www.amazontrust.com/repository/AmazonRootCA1.pem /app/AmazonRootCA1.pem

RUN pip install --no-cache-dir paho-mqtt==2.1.0 boto3

COPY sim.py /app/sim.py

# A clean SIGTERM reaches the Python process (no shell wrapper swallowing it),
# so the graceful deregister handler runs on ECS scale-down.
ENTRYPOINT ["python", "-u", "/app/sim.py"]
