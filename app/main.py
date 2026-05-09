"""Skybyte greeting service.

Changes from starter:
- Port changed from 80 → 8080 (unprivileged, compatible with non-root user).
- /metrics endpoint added (prometheus_client) exposing http_requests_total
  and http_request_duration_seconds.
- API_TOKEN sourced from environment only (never from code/config).
"""

import os
import time

from flask import Flask, jsonify, request, Response
from prometheus_client import (
    Counter,
    Histogram,
    generate_latest,
    CONTENT_TYPE_LATEST,
)

app = Flask(__name__)

VERSION = "1.0.0"

API_TOKEN = os.environ.get("API_TOKEN", "")

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP request count",
    ["method", "path", "status"],
)

REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["method", "path"],
)


@app.before_request
def _start_timer():
    """Record request start time on Flask's per-request context."""
    request._start_time = time.perf_counter()


@app.after_request
def _record_metrics(response):
    """Increment counters and observe duration after every request.

    We exclude /metrics itself to avoid self-referential noise in the data.
    """
    if request.path == "/metrics":
        return response

    duration = time.perf_counter() - request._start_time
    REQUEST_COUNT.labels(
        method=request.method,
        path=request.path,
        status=str(response.status_code),
    ).inc()
    REQUEST_DURATION.labels(
        method=request.method,
        path=request.path,
    ).observe(duration)
    return response


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.route("/")
def hello():
    return jsonify({"message": "Hello, Candidate", "version": VERSION})


@app.route("/healthz")
def healthz():
    return "ok", 200


@app.route("/readyz")
def readyz():
    return "ready", 200


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)