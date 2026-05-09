"""
pytest configuration — adds the app/ directory to sys.path so that
`from main import app` resolves correctly when tests are run from the
repo root with `pytest app/tests/`.
"""
import sys
import os

# Insert app/ at the front of sys.path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))