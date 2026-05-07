"""Skybyte greeting service."""
from flask import Flask, jsonify
import os

app = Flask(__name__)

VERSION = "1.0.0"
API_TOKEN = os.environ.get("API_TOKEN", "")


@app.route("/")
def hello():
    return jsonify({"message": "Hello, Candidate", "version": VERSION})


@app.route("/healthz")
def healthz():
    # TODO: actually check something useful
    return "ok", 200


if __name__ == "__main__":
    # Bind to 0.0.0.0 so the container can be reached from outside.
    app.run(host="0.0.0.0", port=80)
