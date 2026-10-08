"""pytest 公共装置。

设计取舍
--------
* **每个用例一个全新的 SQLite 临时库**：用例之间零耦合，也不需要清理逻辑。
* 建表走 ``Base.metadata.create_all``（快），**迁移本身**由
  ``test_migrations.py`` 单独用真实 Alembic 验证：
  它会断言迁移建出的 schema 与模型声明完全一致，因此"模型对了但迁移错了"
  这种情况不会漏网。
* **不使用真实公网**：全部通过 ``TestClient`` 直接调用 ASGI 应用。
* 时间相关的时间均由用例显式传入（``tz_offset_minutes`` / ``now``），
  不依赖机器时区与真实时钟。
"""

from __future__ import annotations

import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

# 必须在导入 app.* 之前设置：配置在首次读取时就要求 JWT 密钥存在
os.environ.setdefault("PETLIFE_JWT_SECRET", "pytest-secret-0123456789abcdefghijkl")
os.environ.setdefault("PETLIFE_ENVIRONMENT", "test")
# Phase 3：集成服务令牌。生产环境必须显式配置，测试里给一个固定值。
os.environ.setdefault("PETLIFE_INTEGRATION_TOKEN", "pytest-integration-token-0123456789")
INTEGRATION_TOKEN = os.environ["PETLIFE_INTEGRATION_TOKEN"]

# Web Session（GameLog「生活足迹」）：TestClient 走的是 **http**，而 httpx 只会在
# https 下回传 Secure Cookie —— 不关掉这个标志，所有基于 Cookie 的网页会话用例
# 都会"登录成功但下一个请求看起来没登录"。生产默认 True，
# 「生产必须带 Secure」由 tests/test_web_session.py 的单元用例单独断言。
os.environ.setdefault("PETLIFE_WEB_SESSION_COOKIE_SECURE", "false")
# Cookie 的 Path 必须与「浏览器看到的前缀」一致。测试直接打后端 ``/api/v1/...``
# （没有 Nginx 剥前缀），因此用根路径；生产默认 ``/petlife-api/`` 由
# tests/test_web_session.py 的单元用例单独断言。
os.environ.setdefault("PETLIFE_WEB_SESSION_COOKIE_PATH", "/")

SERVER_ROOT = Path(__file__).resolve().parent.parent
if str(SERVER_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_ROOT))

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.core.config import get_settings, reset_settings_cache  # noqa: E402
from app.database.base import Base  # noqa: E402
from app.database.session import (  # noqa: E402
    build_engine,
    dispose_engine,
    get_session_factory,
)
import app.models  # noqa: E402,F401  （注册全部表）

API = "/api/v1"
DEFAULT_PASSWORD = "Sup3r-secret-pw"


@pytest.fixture()
def db_url(tmp_path) -> str:
    return f"sqlite+pysqlite:///{tmp_path / 'petlife_test.db'}"


@pytest.fixture()
def app_module(db_url, monkeypatch):
    """构造一个使用独立临时库的应用实例。"""
    monkeypatch.setenv("PETLIFE_DATABASE_URL", db_url)
    monkeypatch.setenv("PETLIFE_ENVIRONMENT", "test")
    reset_settings_cache()

    settings = get_settings()
    engine = build_engine(settings.database_url)
    Base.metadata.create_all(engine)
    engine.dispose()

    # create_app 内部会 init_engine，从而让请求使用这个库
    from app.main import create_app

    application = create_app(settings)
    yield application

    dispose_engine()
    reset_settings_cache()


@pytest.fixture()
def client(app_module) -> TestClient:
    with TestClient(app_module) as test_client:
        yield test_client


@pytest.fixture()
def session_factory(app_module):
    """直接操作数据库的会话工厂（用于断言落库结果）。"""
    return get_session_factory()


class ApiClient:
    """带状态的小客户端：记住令牌与设备，便于串联多步流程。"""

    def __init__(self, client: TestClient) -> None:
        self.http = client
        self.access_token: str | None = None
        self.refresh_token: str | None = None
        self.device_id: str | None = None
        self.device_local_id: str = str(uuid.uuid4())
        self.user: dict | None = None

    # --- 请求封装 ---

    def _headers(self, *, auth: bool = True, device: bool = True) -> dict[str, str]:
        headers: dict[str, str] = {}
        if auth and self.access_token:
            headers["Authorization"] = f"Bearer {self.access_token}"
        if device and self.device_id:
            headers["X-Device-Id"] = self.device_id
        return headers

    def post(self, path: str, *, auth=True, device=True, **kwargs):
        return self.http.post(path, headers=self._headers(auth=auth, device=device), **kwargs)

    def get(self, path: str, *, auth=True, device=True, **kwargs):
        return self.http.get(path, headers=self._headers(auth=auth, device=device), **kwargs)

    def patch(self, path: str, *, auth=True, device=True, **kwargs):
        return self.http.patch(path, headers=self._headers(auth=auth, device=device), **kwargs)

    def delete(self, path: str, *, auth=True, device=True, **kwargs):
        # 注意：TestClient.delete() 不接受 json=，必须走 request()
        return self.http.request(
            "DELETE", path, headers=self._headers(auth=auth, device=device), **kwargs
        )

    # --- 业务便捷方法 ---

    def device_payload(self, name: str = "测试设备", **extra) -> dict:
        return {
            "device_local_id": self.device_local_id,
            "device_name": name,
            "platform": "windows",
            "architecture": "x64",
            **extra,
        }

    def register(self, *, email: str | None = None, display_name: str = "测试用户"):
        email = email or f"user-{uuid.uuid4().hex[:10]}@example.com"
        response = self.http.post(
            f"{API}/auth/register",
            json={
                "email": email,
                "password": DEFAULT_PASSWORD,
                "display_name": display_name,
                # 客户端总是知道自己的设备标识，登录/注册时一并上报，
                # 令牌就会绑定到该设备（撤销设备时能立刻失效）。
                "device": self.device_payload(),
            },
        )
        assert response.status_code == 201, response.text
        self._absorb(response.json())
        return response

    def login(self, *, email: str, password: str = DEFAULT_PASSWORD):
        response = self.http.post(
            f"{API}/auth/login",
            json={
                "email": email,
                "password": password,
                "device": self.device_payload(),
            },
        )
        if response.status_code == 200:
            self._absorb(response.json())
        return response

    def _absorb(self, body: dict) -> None:
        self.access_token = body.get("access_token")
        self.refresh_token = body.get("refresh_token")
        self.user = body.get("user")
        if body.get("device_id"):
            self.device_id = body["device_id"]

    def bind_device(self, *, name: str = "测试设备", **extra):
        response = self.post(
            f"{API}/devices/register", json=self.device_payload(name, **extra)
        )
        assert response.status_code == 201, response.text
        self.device_id = response.json()["id"]
        return response


@pytest.fixture()
def api(client) -> ApiClient:
    return ApiClient(client)


# --- 时间助手 ---


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso(value: datetime) -> str:
    return value.isoformat().replace("+00:00", "Z")


def make_segment(
    *,
    device_id: str,
    app_key: str = "code",
    category: str = "development",
    started_at: datetime,
    ended_at: datetime | None = None,
    active_seconds: int = 600,
    end_reason: str = "foreground_changed",
    record_id: str | None = None,
    updated_at: datetime | None = None,
    created_at: datetime | None = None,
) -> dict:
    """构造一条活动段上传体（默认字段齐全，便于用例只覆盖关心的字段）。"""
    return {
        "id": record_id or str(uuid.uuid4()),
        "device_id": device_id,
        "app_key": app_key,
        "category": category,
        "started_at": iso(started_at),
        "ended_at": iso(ended_at) if ended_at else None,
        "active_seconds": active_seconds,
        "end_reason": end_reason,
        "created_at": iso(created_at or started_at),
        "updated_at": iso(updated_at or ended_at or started_at),
    }


def make_daily(
    *,
    device_id: str,
    local_day: str,
    active_seconds: int = 3600,
    idle_seconds: int = 600,
    session_seconds: int | None = None,
    timezone_offset_minutes: int = 0,
    updated_at: datetime | None = None,
) -> dict:
    return {
        "device_id": device_id,
        "local_day": local_day,
        "timezone_offset_minutes": timezone_offset_minutes,
        "session_seconds": session_seconds
        if session_seconds is not None
        else active_seconds + idle_seconds,
        "active_seconds": active_seconds,
        "idle_seconds": idle_seconds,
        "updated_at": iso(updated_at or utc_now()),
    }


def make_app_record(
    *,
    app_key: str,
    display_name: str | None = None,
    category: str = "development",
    user_overridden: bool = False,
    updated_at: datetime | None = None,
) -> dict:
    return {
        "app_key": app_key,
        "display_name": display_name or app_key,
        "category": category,
        "user_overridden": user_overridden,
        "updated_at": iso(updated_at or utc_now()),
    }
