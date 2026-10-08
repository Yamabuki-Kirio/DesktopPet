"""设备绑定、修改与撤销。"""

from __future__ import annotations

import uuid

from .conftest import API, DEFAULT_PASSWORD


def test_register_device_binds_and_returns_id(api):
    api.register(email="dev1@example.com")
    response = api.bind_device(name="我的台式机", os_version="Windows 11", app_version="0.2.0")
    body = response.json()
    assert body["device_local_id"] == api.device_local_id
    assert body["device_name"] == "我的台式机"
    assert body["platform"] == "windows"
    assert body["architecture"] == "x64"
    assert body["revoked_at"] is None
    assert body["is_current"] is True
    assert uuid.UUID(body["id"])


def test_register_device_is_idempotent_for_same_local_id(api):
    api.register(email="dev2@example.com")
    first = api.bind_device(name="设备A").json()
    second = api.bind_device(name="设备A（改名）").json()
    assert first["id"] == second["id"], "同一 device_local_id 不应产生两条设备记录"

    devices = api.get(f"{API}/devices").json()
    assert len(devices) == 1
    assert devices[0]["device_name"] == "设备A（改名）"


def test_model_name_is_not_overwritten_by_client_reports(api):
    """model_name 是用户备注，客户端上报只能填空，不能覆盖用户已填的值。"""
    api.register(email="dev3@example.com")
    device = api.bind_device(name="设备B", model_name="用户填的型号").json()
    api.bind_device(name="设备B", model_name="客户端乱报的型号")
    devices = api.get(f"{API}/devices").json()
    assert devices[0]["model_name"] == "用户填的型号"
    assert device["model_name"] == "用户填的型号"


def test_list_devices_marks_current(api):
    api.register(email="dev4@example.com")
    api.bind_device(name="当前设备")
    devices = api.get(f"{API}/devices").json()
    assert len(devices) == 1
    assert devices[0]["is_current"] is True


def test_update_device_name_and_model(api):
    api.register(email="dev5@example.com")
    device_id = api.bind_device(name="旧名字").json()["id"]

    response = api.patch(
        f"{API}/devices/{device_id}", json={"device_name": "新名字", "model_name": "笔记本"}
    )
    assert response.status_code == 200
    body = response.json()
    assert body["device_name"] == "新名字"
    assert body["model_name"] == "笔记本"


def test_revoke_device_invalidates_its_tokens_and_blocks_sync(api):
    api.register(email="dev6@example.com")
    device = api.bind_device(name="待撤销").json()

    revoked = api.delete(f"{API}/devices/{device['id']}")
    assert revoked.status_code == 200
    body = revoked.json()
    assert body["revoked_at"] is not None
    assert body["revoked_sessions"] >= 1

    # 撤销后同步必须被明确拒绝（而不是静默成功）
    push = api.post(
        f"{API}/sync/push", json={"activity_segments": [], "daily_usage": [], "applications": []}
    )
    assert push.status_code == 403
    assert push.json()["error"]["code"] == "device_revoked"

    # 撤销前的 refresh token 也失效了
    refresh = api.http.post(
        f"{API}/auth/refresh", json={"refresh_token": api.refresh_token}
    )
    assert refresh.status_code == 401


def test_revoke_device_is_idempotent(api):
    api.register(email="dev7@example.com")
    device_id = api.bind_device(name="重复撤销").json()["id"]
    first = api.delete(f"{API}/devices/{device_id}")
    second = api.delete(f"{API}/devices/{device_id}")
    assert first.status_code == 200
    assert second.status_code == 200
    assert second.json()["revoked_sessions"] == 0


def test_revoked_device_local_id_is_released_for_rebinding(api):
    """撤销会释放 device_local_id，用户重新登录后可在同一台机器上重新绑定。"""
    api.register(email="dev8@example.com")
    first = api.bind_device(name="第一次绑定").json()
    api.delete(f"{API}/devices/{first['id']}")

    # 用同一个 device_local_id 再绑定，应当拿到一条**新的**设备记录
    second = api.bind_device(name="重新绑定").json()
    assert second["id"] != first["id"]
    assert second["revoked_at"] is None
    assert second["device_local_id"] == api.device_local_id


def test_sync_requires_device_header(api):
    api.register(email="dev9@example.com")
    response = api.post(
        f"{API}/sync/push",
        device=False,
        json={"activity_segments": [], "daily_usage": [], "applications": []},
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "device_not_found"


def test_sync_rejects_malformed_device_header(api):
    api.register(email="dev10@example.com")
    response = api.http.post(
        f"{API}/sync/push",
        headers={"Authorization": f"Bearer {api.access_token}", "X-Device-Id": "not-a-uuid"},
        json={"activity_segments": [], "daily_usage": [], "applications": []},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_uuid"


def test_invalid_platform_is_rejected(api):
    api.register(email="dev11@example.com")
    response = api.post(
        f"{API}/devices/register",
        json={
            "device_local_id": str(uuid.uuid4()),
            "device_name": "怪平台",
            "platform": "dreamcast",
            "architecture": "x64",
        },
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_register_android_device_alongside_windows(api):
    """Phase 4A：同一账户下的 Android 设备与 Windows 设备**并存**。

    两个关键点：
    * `platform=android` 必须被接受（不能只认 windows）；
    * `architecture` 上报的是 Android ABI 名（`arm64-v8a`），也必须被接受，
      否则 Android 客户端注册设备会直接 422。
    """
    api.register(email="android@example.com")
    windows = api.bind_device(name="我的台式机").json()
    assert windows["platform"] == "windows"

    android_local_id = str(uuid.uuid4())
    response = api.post(
        f"{API}/devices/register",
        json={
            "device_local_id": android_local_id,
            "device_name": "Pixel 7",
            "platform": "android",
            "architecture": "arm64-v8a",
            "os_version": "Android 14 (API 34)",
            "app_version": "0.1.0",
        },
    )
    assert response.status_code == 201, response.text
    android = response.json()
    assert android["platform"] == "android"
    assert android["architecture"] == "arm64-v8a"
    assert android["id"] != windows["id"], "Android 必须是另一台设备"
    assert android["device_local_id"] == android_local_id

    devices = api.get(f"{API}/devices").json()
    assert {d["platform"] for d in devices} == {"windows", "android"}
    assert len(devices) == 2


def test_invalid_architecture_is_rejected(api):
    """架构白名单同样要生效（Android ABI 之外的值一律拒绝）。"""
    api.register(email="dev13@example.com")
    response = api.post(
        f"{API}/devices/register",
        json={
            "device_local_id": str(uuid.uuid4()),
            "device_name": "怪架构",
            "platform": "android",
            "architecture": "mips",
        },
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_device_last_seen_is_updated_by_authenticated_calls(api, session_factory):
    api.register(email="dev12@example.com")
    device_id = api.bind_device(name="活跃度").json()["id"]

    from sqlalchemy import select

    from app.models import Device

    with session_factory() as session:
        row = session.scalar(select(Device).where(Device.id == uuid.UUID(device_id)))
        before = row.last_seen_at

    api.get(f"{API}/devices")
    api.get(f"{API}/sync/pull", params={"cursor": 0})

    with session_factory() as session:
        row = session.scalar(select(Device).where(Device.id == uuid.UUID(device_id)))
        after = row.last_seen_at

    assert after >= before


def test_login_flow_with_explicit_device_registration(api):
    """完整客户端流程：注册 → 登录 → 绑定设备 → 带设备头调用。"""
    api.register(email="flow@example.com", display_name="流程用户")

    fresh = type(api)(api.http)
    # 同一台机器：device_local_id 必须保持一致，否则会被当成第二台设备
    fresh.device_local_id = api.device_local_id
    assert fresh.login(email="flow@example.com").status_code == 200
    fresh.bind_device(name="流程设备")

    me = fresh.get(f"{API}/me")
    assert me.status_code == 200
    assert me.json()["display_name"] == "流程用户"

    devices = fresh.get(f"{API}/devices").json()
    assert len(devices) == 1, "同一 device_local_id 重复登录不应产生第二台设备"
    assert devices[0]["device_name"] == "流程设备"
    assert devices[0]["is_current"] is True
    assert DEFAULT_PASSWORD  # 保持常量被引用
