"""
Unit tests for the DevSecOps Flask application.
Run with: pytest app/test_app.py -v
"""
import pytest
from app import app as flask_app


@pytest.fixture
def client():
    flask_app.config["TESTING"] = True
    with flask_app.test_client() as client:
        yield client


# ── /health ───────────────────────────────────────────────────────────────────

class TestHealthEndpoint:
    def test_returns_200(self, client):
        assert client.get("/health").status_code == 200

    def test_content_type_is_json(self, client):
        response = client.get("/health")
        assert "application/json" in response.content_type

    def test_body_is_exactly_healthy(self, client):
        # ALB health checks read this response — shape must not silently change
        data = client.get("/health").get_json()
        assert data == {"status": "healthy"}


# ── / (index) ─────────────────────────────────────────────────────────────────

class TestIndexEndpoint:
    def test_returns_200(self, client):
        assert client.get("/").status_code == 200

    def test_content_type_is_json(self, client):
        assert "application/json" in client.get("/").content_type

    def test_response_shape(self, client):
        data = client.get("/").get_json()
        assert "status" in data
        assert "service" in data
        assert "primes_below_15000" in data

    def test_prime_count_is_deterministic(self, client):
        # Validates the CPU-work logic hasn't regressed — 1754 is the known
        # correct count of primes strictly below 15,000.
        data = client.get("/").get_json()
        assert data["primes_below_15000"] == 1754

    def test_status_is_ok(self, client):
        data = client.get("/").get_json()
        assert data["status"] == "ok"


# ── Unknown routes ────────────────────────────────────────────────────────────

class TestUnknownRoutes:
    def test_unknown_path_returns_404(self, client):
        assert client.get("/nonexistent").status_code == 404

    def test_post_to_health_returns_405(self, client):
        # Health endpoint is GET-only; a POST should be rejected cleanly
        assert client.post("/health").status_code == 405
