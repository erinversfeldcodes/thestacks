from fastapi.testclient import TestClient

from app.main import app


def test_health_returns_200() -> None:
    with TestClient(app) as client:
        response = client.get("/health")
    assert response.status_code == 200


def test_health_no_auth_required() -> None:
    """Health endpoint must be reachable without any authentication header."""
    with TestClient(app) as client:
        response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert data["service"] == "vision"
