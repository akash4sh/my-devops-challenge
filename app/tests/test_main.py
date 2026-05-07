"""Minimal tests for the greeting service."""
from app.main import app


def test_hello():
    client = app.test_client()
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.json["message"] == "Hello, Candidate"


def test_healthz():
    client = app.test_client()
    resp = client.get("/healthz")
    assert resp.status_code == 200
