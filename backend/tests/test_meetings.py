"""
Tests for meeting API endpoints.
Run with: pytest tests/ -v
"""

import pytest
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_create_and_list_meetings():
    # Create
    resp = client.post("/meetings", json={"title": "Test Meeting"})
    assert resp.status_code == 201
    meeting_id = resp.json()["id"]
    assert resp.json()["status"] == "recording"

    # List
    resp = client.get("/meetings")
    assert resp.status_code == 200
    ids = [m["id"] for m in resp.json()]
    assert meeting_id in ids


def test_get_meeting():
    resp = client.post("/meetings", json={"title": "Get Test"})
    meeting_id = resp.json()["id"]

    resp = client.get(f"/meetings/{meeting_id}")
    assert resp.status_code == 200
    assert resp.json()["id"] == meeting_id


def test_delete_meeting():
    resp = client.post("/meetings", json={"title": "Delete Me"})
    meeting_id = resp.json()["id"]

    resp = client.delete(f"/meetings/{meeting_id}")
    assert resp.status_code == 204

    resp = client.get(f"/meetings/{meeting_id}")
    assert resp.status_code == 404


def test_create_and_list_people():
    resp = client.post("/people", json={"display_name": "Test Person"})
    assert resp.status_code == 201
    person_id = resp.json()["id"]

    resp = client.get("/people")
    ids = [p["id"] for p in resp.json()]
    assert person_id in ids


def test_settings_endpoint():
    resp = client.get("/settings")
    assert resp.status_code == 200
    data = resp.json()
    assert "default_llm_provider" in data
    assert "base_storage_dir" in data
