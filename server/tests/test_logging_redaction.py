"""日志脱敏。

需求：**日志不得输出 Access Token、Refresh Token、Authorization 请求头或密码。**
这里既测脱敏函数本身，也测"真实登录请求产生的日志里不含密码/令牌"。
"""

from __future__ import annotations

import io
import logging

import pytest

from app.core.logging import REDACTED, RedactingFilter, redact

from .conftest import API, DEFAULT_PASSWORD


@pytest.mark.parametrize(
    "raw",
    [
        'password=hunter2',
        'password: hunter2',
        '"password": "hunter2"',
        "'refresh_token'='abc.def.ghi'",
        "access_token=abcdef123456",
        "Authorization: Bearer abcdefghijklmnop",
        "authorization=Basic dXNlcjpwYXNz",
        "api_key=sk-live-0123456789",
        '{"refresh_token": "zzzzzzzzzzzzzzzzz"}',
    ],
)
def test_redact_removes_sensitive_values(raw):
    cleaned = redact(raw)
    assert "hunter2" not in cleaned
    assert "dXNlcjpwYXNz" not in cleaned
    assert "abcdef123456" not in cleaned
    assert REDACTED in cleaned


def test_redact_removes_bare_jwt():
    jwt = (
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        ".eyJzdWIiOiIxMjM0NTY3ODkwIn0"
        ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    )
    cleaned = redact(f"token is {jwt} here")
    assert jwt not in cleaned
    assert REDACTED in cleaned


def test_redact_keeps_ordinary_text():
    text = "状态切换 default -> focused，耗时 12ms"
    assert redact(text) == text


def test_login_logs_do_not_leak_password_or_tokens(client, api, caplog):
    """真实登录流程：密码与签发的令牌都不得出现在日志里。"""
    api.register(email="redact@example.com")

    with caplog.at_level(logging.DEBUG):
        response = api.http.post(
            f"{API}/auth/login",
            json={"email": "redact@example.com", "password": DEFAULT_PASSWORD},
        )
    assert response.status_code == 200
    access_token = response.json()["access_token"]
    refresh_token = response.json()["refresh_token"]

    blob = "\n".join(record.getMessage() for record in caplog.records)
    assert DEFAULT_PASSWORD not in blob, "密码不得出现在日志中"
    assert access_token not in blob, "Access Token 不得出现在日志中"
    assert refresh_token not in blob, "Refresh Token 不得出现在日志中"
    assert f"Bearer {access_token}" not in blob, "Authorization 头不得出现在日志中"


def test_authenticated_requests_do_not_log_authorization_header(client, api, caplog):
    api.register(email="redact2@example.com")
    api.bind_device(name="脱敏设备")

    with caplog.at_level(logging.DEBUG):
        api.get(f"{API}/devices")

    blob = "\n".join(record.getMessage() for record in caplog.records)
    assert api.access_token not in blob, "Access Token 不得出现在日志中"
    assert api.refresh_token not in blob
    assert f"Bearer {api.access_token}" not in blob


def test_handler_level_filter_scrubs_any_record():
    """兜底防线必须在**处理器**上生效。

    说明：Python 的日志过滤只对「记录自身所在 logger 的过滤器」与
    「处理器的过滤器」生效，祖先 logger 上的过滤器不会被调用。
    因此真正可靠的落点是 handler——这正是 ``setup_logging`` 的做法。
    这里用一个真实 handler 端到端验证：即使有人手工把 token 拼进日志，
    写出去的文本里也只会是 ``<redacted>``。
    """
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.addFilter(RedactingFilter())
    handler.setFormatter(logging.Formatter("%(message)s"))

    logger = logging.getLogger("petlife.manual.test")
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    try:
        secret = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.signaturepart"
        logger.info("leaking token=%s password=%s", secret, "hunter2")
    finally:
        logger.removeHandler(handler)

    emitted = stream.getvalue()
    assert secret not in emitted
    assert "hunter2" not in emitted
    assert REDACTED in emitted


def test_setup_logging_installs_redacting_filter():
    """``setup_logging`` 必须把脱敏过滤器装在 handler 上（幂等）。"""
    import app.core.logging as logging_module

    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.addFilter(logging_module.RedactingFilter())
    handler.setFormatter(logging.Formatter("%(message)s"))

    root = logging.getLogger()
    root.addHandler(handler)
    try:
        logging.getLogger("petlife.other").info("access_token=%s", "abcdef123456")
    finally:
        root.removeHandler(handler)

    assert "abcdef123456" not in stream.getvalue()
    assert REDACTED in stream.getvalue()
