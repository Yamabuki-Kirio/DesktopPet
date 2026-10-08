"""用户之间的数据隔离。

这是**安全底线**：任何一条断言失败都意味着用户可以读到或改到别人的数据。
除了行为断言，本文件还检查"结构层面的隔离"——主键里带 ``user_id``，
使得重放别人的记录 ID 也无法覆盖对方的数据。
"""

from __future__ import annotations

import uuid
from datetime import timedelta

from sqlalchemy import select

from app.core.timeutil import utcnow
from app.models import ActivitySegment

from .conftest import API, ApiClient, make_app_record, make_daily, make_segment


def _push(api, *, segments=None, daily=None, apps=None):
    return api.post(
        f"{API}/sync/push",
        json={
            "activity_segments": segments or [],
            "daily_usage": daily or [],
            "applications": apps or [],
        },
    )


def _two_users(client) -> tuple[ApiClient, ApiClient]:
    alice = ApiClient(client)
    alice.register(email="alice-iso@example.com", display_name="Alice")
    alice.bind_device(name="Alice 的电脑")

    bob = ApiClient(client)
    bob.register(email="bob-iso@example.com", display_name="Bob")
    bob.bind_device(name="Bob 的电脑")
    return alice, bob


def test_pull_never_returns_other_users_records(client):
    alice, bob = _two_users(client)
    start = utcnow() - timedelta(hours=1)

    _push(
        alice,
        segments=[
            make_segment(
                device_id=alice.device_id,
                app_key="alice-secret-app",
                started_at=start,
                ended_at=start + timedelta(minutes=10),
            )
        ],
    )
    _push(
        bob,
        segments=[
            make_segment(
                device_id=bob.device_id,
                app_key="bob-app",
                started_at=start,
                ended_at=start + timedelta(minutes=10),
            )
        ],
    )

    alice_rows = alice.get(f"{API}/sync/pull", params={"cursor": 0}).json()
    bob_rows = bob.get(f"{API}/sync/pull", params={"cursor": 0}).json()

    alice_apps = {r["app_key"] for r in alice_rows["activity_segments"]}
    bob_apps = {r["app_key"] for r in bob_rows["activity_segments"]}

    assert alice_apps == {"alice-secret-app"}
    assert bob_apps == {"bob-app"}
    assert "bob-app" not in alice_apps
    assert "alice-secret-app" not in bob_apps


def test_replaying_another_users_record_id_cannot_overwrite(client, session_factory):
    """Bob 拿着 Alice 的记录 UUID 上传：只能写入自己名下，绝不改动 Alice 的数据。"""
    alice, bob = _two_users(client)
    start = utcnow() - timedelta(hours=2)
    shared_id = str(uuid.uuid4())

    _push(
        alice,
        segments=[
            make_segment(
                device_id=alice.device_id,
                app_key="alice-app",
                started_at=start,
                ended_at=start + timedelta(minutes=30),
                active_seconds=1800,
                record_id=shared_id,
            )
        ],
    )
    # Bob 用同一个记录 ID（但 device_id 是他自己的）
    response = _push(
        bob,
        segments=[
            make_segment(
                device_id=bob.device_id,
                app_key="bob-app",
                started_at=start,
                ended_at=start + timedelta(minutes=1),
                active_seconds=60,
                record_id=shared_id,
            )
        ],
    )
    assert response.status_code == 200
    assert response.json()["accepted_activity_segments"] == 1

    with session_factory() as session:
        rows = list(
            session.scalars(
                select(ActivitySegment).where(ActivitySegment.id == uuid.UUID(shared_id))
            )
        )

    assert len(rows) == 2, "同一记录 ID 在不同用户下必须是两条独立记录"
    by_app = {row.app_key: row for row in rows}
    assert by_app["alice-app"].active_seconds == 1800
    assert by_app["alice-app"].device_id == uuid.UUID(alice.device_id)
    assert by_app["bob-app"].active_seconds == 60
    assert by_app["bob-app"].device_id == uuid.UUID(bob.device_id)


def test_stats_are_per_user(client):
    alice, bob = _two_users(client)
    start = utcnow() - timedelta(hours=1)

    _push(
        alice,
        segments=[
            make_segment(
                device_id=alice.device_id,
                started_at=start,
                ended_at=start + timedelta(hours=1),
                active_seconds=3600,
            )
        ],
    )
    _push(
        bob,
        segments=[
            make_segment(
                device_id=bob.device_id,
                started_at=start,
                ended_at=start + timedelta(hours=1),
                active_seconds=120,
            )
        ],
    )

    alice_stats = alice.get(
        f"{API}/stats/apps", params={"period": "today", "tz_offset_minutes": 0}
    ).json()
    bob_stats = bob.get(
        f"{API}/stats/apps", params={"period": "today", "tz_offset_minutes": 0}
    ).json()

    assert alice_stats["total_app_active_seconds"] == 3600
    assert bob_stats["total_app_active_seconds"] == 120


def test_cannot_touch_another_users_device(client):
    alice, bob = _two_users(client)

    # Bob 用 Alice 的 device_id 作为 X-Device-Id 调同步
    bob.device_id = alice.device_id
    response = _push(bob)
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "device_not_found"

    # Bob 尝试改名 / 撤销 Alice 的设备：一律 404（不泄露该设备是否存在）
    renamed = bob.patch(
        f"{API}/devices/{alice.device_id}", json={"device_name": "被劫持"}
    )
    assert renamed.status_code == 404
    assert renamed.json()["error"]["code"] == "device_not_found"

    revoked = bob.delete(f"{API}/devices/{alice.device_id}")
    assert revoked.status_code == 404

    # Alice 的设备仍然安好
    alice_devices = alice.get(f"{API}/devices").json()
    assert len(alice_devices) == 1
    assert alice_devices[0]["device_name"] == "Alice 的电脑"
    assert alice_devices[0]["revoked_at"] is None


def test_application_records_are_per_user(client, session_factory):
    alice, bob = _two_users(client)

    _push(
        alice,
        apps=[
            make_app_record(
                app_key="chrome", display_name="Alice 的浏览器", category="productivity"
            )
        ],
    )
    _push(
        bob,
        apps=[make_app_record(app_key="chrome", display_name="Bob 的浏览器", category="browser")],
    )

    alice_rows = alice.get(f"{API}/sync/pull", params={"cursor": 0}).json()
    bob_rows = bob.get(f"{API}/sync/pull", params={"cursor": 0}).json()

    assert alice_rows["applications"][0]["display_name"] == "Alice 的浏览器"
    assert bob_rows["applications"][0]["display_name"] == "Bob 的浏览器"


def test_daily_usage_is_per_device_and_user(client):
    """两台设备同一天必须各占一行；daily_usage 不会互相覆盖。"""
    alice, _bob = _two_users(client)
    day = utcnow().date().isoformat()

    _push(
        alice,
        daily=[make_daily(device_id=alice.device_id, local_day=day, active_seconds=1000)],
    )
    alice.device_local_id = "another-local-device"
    alice.bind_device(name="Alice 的第二台")
    _push(
        alice,
        daily=[make_daily(device_id=alice.device_id, local_day=day, active_seconds=2000)],
    )

    body = alice.get(
        f"{API}/stats/devices", params={"period": "today", "tz_offset_minutes": 0}
    ).json()
    assert len(body["items"]) == 2
    assert body["total_active_seconds"] == 3000
