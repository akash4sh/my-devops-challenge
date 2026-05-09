"""
Unit tests for the Skybyte greeting service.

Tests cover:
- Business endpoints (/, /healthz, /readyz)
- Metrics endpoint (/metrics) — verifies prometheus counters are emitted
- Metric label correctness (method, path, status)

Run with:
    pytest app/tests/ -v
"""

import pytest
from main import app


@pytest.fixture
def client():
    """Return a Flask test client with testing mode enabled."""
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


# ---------------------------------------------------------------------------
# Business endpoints
# ---------------------------------------------------------------------------

class TestHello:
    def test_status_200(self, client):
        resp = client.get("/")
        assert resp.status_code == 200

    def test_response_body(self, client):
        resp = client.get("/")
        data = resp.get_json()
        assert data["message"] == "Hello, Candidate"
        assert data["version"] == "1.0.0"

    def test_content_type_json(self, client):
        resp = client.get("/")
        assert "application/json" in resp.content_type


class TestHealthz:
    def test_status_200(self, client):
        resp = client.get("/healthz")
        assert resp.status_code == 200

    def test_response_body(self, client):
        resp = client.get("/healthz")
        assert resp.data == b"ok"


class TestReadyz:
    def test_status_200(self, client):
        resp = client.get("/readyz")
        assert resp.status_code == 200

    def test_response_body(self, client):
        resp = client.get("/readyz")
        assert resp.data == b"ready"


# ---------------------------------------------------------------------------
# Metrics endpoint
# ---------------------------------------------------------------------------

class TestMetrics:
    def test_metrics_endpoint_reachable(self, client):
        """Prometheus scraper must be able to reach /metrics."""
        resp = client.get("/metrics")
        assert resp.status_code == 200

    def test_metrics_content_type(self, client):
        """
        Prometheus expects text/plain; version=0.0.4 content type.
        A wrong content type causes the scraper to reject the payload.
        """
        resp = client.get("/metrics")
        assert "text/plain" in resp.content_type

    def test_http_requests_total_present(self, client):
        """
        After hitting /, the http_requests_total counter must appear
        in /metrics output with the correct metric name.
        """
        client.get("/")
        resp = client.get("/metrics")
        assert b"http_requests_total" in resp.data

    def test_http_request_duration_present(self, client):
        """
        After hitting /, the duration histogram must appear in /metrics.
        """
        client.get("/")
        resp = client.get("/metrics")
        assert b"http_request_duration_seconds" in resp.data

    def test_metric_labels_method_path_status(self, client):
        """
        Verify the three required labels (method, path, status) are present
        in the http_requests_total output.

        The rendered metric line looks like:
          http_requests_total{method="GET",path="/",status="200"} 1.0
        """
        client.get("/")
        resp = client.get("/metrics")
        payload = resp.data.decode("utf-8")

        # Find the line for the root endpoint counter
        counter_lines = [
            line for line in payload.splitlines()
            if "http_requests_total" in line
            and not line.startswith("#")
            and 'path="/"' in line
        ]
        assert len(counter_lines) >= 1, (
            "Expected at least one http_requests_total line for path='/'"
        )
        line = counter_lines[0]
        assert 'method="GET"' in line
        assert 'path="/"' in line
        assert 'status="200"' in line

    def test_metrics_path_excluded_from_counter(self, client):
        """
        /metrics requests must NOT be counted in http_requests_total.
        Self-referential scrape counts pollute SLO calculations.
        """
        # Hit /metrics several times
        for _ in range(3):
            client.get("/metrics")

        resp = client.get("/metrics")
        payload = resp.data.decode("utf-8")

        # There should be no counter line with path="/metrics"
        counter_lines = [
            line for line in payload.splitlines()
            if "http_requests_total" in line
            and not line.startswith("#")
            and 'path="/metrics"' in line
        ]
        assert len(counter_lines) == 0, (
            "/metrics path must be excluded from http_requests_total counter"
        )