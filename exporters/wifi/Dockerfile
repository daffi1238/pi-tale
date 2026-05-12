# pi-tale — WiFi exporter container (skeleton).
#
# Final image will include the `iw` userspace tool and the Python
# exporter listening on :9116. For now this Dockerfile is a placeholder
# so the path exists and `compose/probes.yml` can reference it once it
# lands.

FROM python:3.12-slim-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends iw iproute2 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY wifi_exporter.py ./

EXPOSE 9116
USER nobody
ENTRYPOINT ["python", "-u", "wifi_exporter.py"]
