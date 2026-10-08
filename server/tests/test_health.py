"""健康检查与统一错误体。"""

from __future__ import annotations


def test_health_reports_database_ok(client):
    response = client.get("/health")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "ok"
    assert body["database"] is True
    assert body["version"]


def test_root_exposes_service_metadata(client):
    response = client.get("/")
    assert response.status_code == 200
    assert "service" in response.json()


def test_unknown_route_uses_unified_error_body(client):
    response = client.get("/api/v1/does-not-exist")
    assert response.status_code == 404
    body = response.json()
    # 统一错误体：error.code / error.message / error.request_id
    assert set(body.keys()) == {"error"}
    assert body["error"]["code"]
    assert body["error"]["message"]
    assert body["error"]["request_id"]
    # 同时通过响应头回传，便于与服务端日志对齐
    assert response.headers["X-Request-Id"] == body["error"]["request_id"]


def test_request_id_is_echoed_back(client):
    response = client.get("/health", headers={"X-Request-Id": "trace-me-123"})
    assert response.headers["X-Request-Id"] == "trace-me-123"


def test_validation_error_does_not_echo_input_values(client):
    """校验错误只回字段路径与原因，不能把提交的原文（可能含密码）回显出来。"""
    secret_value = "SuperSecret-do-not-echo-123"
    response = client.post(
        "/api/v1/auth/register",
        json={"email": "not-an-email", "password": secret_value, "display_name": "x"},
    )
    assert response.status_code == 422
    assert secret_value not in response.text
    body = response.json()
    assert body["error"]["code"] == "validation_error"
    assert isinstance(body["error"]["detail"], list)
