from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)


def test_root():
    response = client.get("/")

    assert response.status_code == 200
    assert response.json() == {
        "message": "DevSecOps Pipeline Running",
        "version": "1.0.0"
    }


def test_health():
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "healthy"
    }


def test_invalid_endpoint():
    response = client.get("/does-not-exist")

    assert response.status_code == 404
