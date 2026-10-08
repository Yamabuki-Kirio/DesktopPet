"""同步协议：幂等、冲突、校验、批量边界。"""

from __future__ import annotations

import uuid
from datetime import timedelta

from sqlalchemy import func, select

from app.models import ActivitySegment, DailyUsage, UserApplication
from app.core.timeutil import utcnow

from .conftest import API, make_app_record, make_daily, make_segment


def _push(api, *, segments=None, daily=None, apps=None, **extra):
    body = {
        "activity_segments": segments or [],
        "daily_usage": daily or [],
        "applications": apps or [],
        **extra,
    }
    return api.post(f"{API}/sync/push", json=body)


def test_push_activity_segment_then_pull_returns_it(api):
    api.register(email="sync1@example.com")
    api.bind_device(name="同步设备")

    start = utcnow() - timedelta(minutes=10)
    segment = make_segment(
        device_id=api.device_id, started_at=start, ended_at=start + timedelta(minutes=5)
    )
    response = _push(api, segments=[segment])
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["accepted_activity_segments"] == 1
    assert body["rejected"] == []
    assert body["cursor"] > 0

    pulled = api.get(f"{API}/sync/pull", params={"cursor": 0}).json()
    assert len(pulled["activity_segments"]) == 1
    row = pulled["activity_segments"][0]
    assert row["id"] == segment["id"]
    assert row["app_key"] == "code"
    assert row["category"] == "development"
    assert row["started_at"].endswith("Z")


def test_reuploading_same_record_does_not_duplicate(api, session_factory):
    api.register(email="sync2@example.com")
    api.bind_device(name="幂等设备")

    start = utcnow() - timedelta(minutes=30)
    segment = make_segment(
        device_id=api.device_id, started_at=start, ended_at=start + timedelta(minutes=5)
    )

    for _ in range(3):
        response = _push(api, segments=[segment])
        assert response.status_code == 200
        assert response.json()["accepted_activity_segments"] == 1

    with session_factory() as session:
        count = session.scalar(select(func.count()).select_from(ActivitySegment))
    assert count == 1, "重复上传相同 UUID 不得产生重复数据"


def test_resubmitting_identical_batch_changes_nothing(api, session_factory):
    """同一个批次重复提交：行数与汇总口径都不变。"""
    api.register(email="sync3@example.com")
    api.bind_device(name="批设备")

    start = utcnow() - timedelta(hours=2)
    segments = [
        make_segment(
            device_id=api.device_id,
            app_key=f"app{i}",
            started_at=start + timedelta(minutes=i * 10),
            ended_at=start + timedelta(minutes=i * 10 + 5),
            active_seconds=300,
        )
        for i in range(5)
    ]
    batch_id = str(uuid.uuid4())

    first = _push(api, segments=segments, batch_id=batch_id).json()
    second = _push(api, segments=segments, batch_id=batch_id).json()

    assert first["accepted_activity_segments"] == second["accepted_activity_segments"] == 5
    with session_factory() as session:
        count = session.scalar(select(func.count()).select_from(ActivitySegment))
        total = session.scalar(select(func.sum(ActivitySegment.active_seconds)))
    assert count == 5
    assert total == 1500


def test_daily_usage_resend_does_not_double_count(api, session_factory):
    """每日用量是整行快照覆盖：重传同一份快照不能累加。"""
    api.register(email="sync4@example.com")
    api.bind_device(name="日用设备")

    day = (utcnow()).date().isoformat()
    snapshot = make_daily(
        device_id=api.device_id, local_day=day, active_seconds=3600, idle_seconds=600
    )

    for _ in range(4):
        response = _push(api, daily=[snapshot])
        assert response.status_code == 200
        assert response.json()["accepted_daily_usage"] == 1

    with session_factory() as session:
        rows = list(session.scalars(select(DailyUsage)))
    assert len(rows) == 1
    assert rows[0].active_seconds == 3600, "重传不得把活跃秒数累加"
    assert rows[0].session_seconds == 4200
    assert rows[0].idle_seconds == 600


def test_daily_usage_newer_snapshot_overwrites(api, session_factory):
    api.register(email="sync5@example.com")
    api.bind_device(name="日用设备2")

    day = (utcnow()).date().isoformat()
    older = make_daily(
        device_id=api.device_id, local_day=day, active_seconds=600, updated_at=utcnow()
    )
    newer = make_daily(
        device_id=api.device_id,
        local_day=day,
        active_seconds=1800,
        updated_at=utcnow() + timedelta(minutes=5),
    )

    _push(api, daily=[newer])
    _push(api, daily=[older])  # 旧快照必须被忽略

    with session_factory() as session:
        row = session.scalar(select(DailyUsage))
    assert row.active_seconds == 1800


def test_activity_segment_last_write_wins(api, session_factory):
    api.register(email="sync6@example.com")
    api.bind_device(name="LWW设备")

    start = utcnow() - timedelta(hours=1)
    record_id = str(uuid.uuid4())
    early = make_segment(
        device_id=api.device_id,
        started_at=start,
        ended_at=start + timedelta(minutes=10),
        active_seconds=600,
        record_id=record_id,
        updated_at=start + timedelta(minutes=10),
    )
    late = dict(early)
    late["active_seconds"] = 900
    late["end_reason"] = "user_idle"
    late["updated_at"] = (start + timedelta(minutes=20)).isoformat().replace("+00:00", "Z")

    _push(api, segments=[late])
    _push(api, segments=[early])  # 更旧的必须被忽略

    with session_factory() as session:
        row = session.scalar(
            select(ActivitySegment).where(ActivitySegment.id == uuid.UUID(record_id))
        )
    assert row.active_seconds == 900
    assert row.end_reason == "user_idle"


def test_application_manual_category_beats_builtin(api, session_factory):
    """人工分类优先：内置分类即使时间更新也不能覆盖用户的选择。"""
    api.register(email="sync7@example.com")
    api.bind_device(name="分类设备")

    manual = make_app_record(
        app_key="chrome",
        display_name="Chrome（我的浏览器）",
        category="productivity",
        user_overridden=True,
        updated_at=utcnow(),
    )
    _push(api, apps=[manual])

    builtin_later = make_app_record(
        app_key="chrome",
        display_name="Chrome",
        category="browser",
        user_overridden=False,
        updated_at=utcnow() + timedelta(hours=1),
    )
    _push(api, apps=[builtin_later])

    with session_factory() as session:
        row = session.scalar(select(UserApplication))
    assert row.category == "productivity"
    assert row.user_overridden is True
    assert row.display_name == "Chrome（我的浏览器）"


def test_invalid_uuid_is_rejected_with_precise_code(api):
    api.register(email="sync8@example.com")
    api.bind_device(name="校验设备")

    response = _push(
        api,
        segments=[
            {
                "id": "not-a-uuid",
                "device_id": api.device_id,
                "app_key": "code",
                "category": "development",
                "started_at": "2026-09-27T10:00:00Z",
                "created_at": "2026-09-27T10:00:00Z",
                "updated_at": "2026-09-27T10:00:00Z",
            }
        ],
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_uuid"


def test_invalid_time_range_is_rejected_per_record(api):
    api.register(email="sync9@example.com")
    api.bind_device(name="时间设备")

    start = utcnow()
    bad = make_segment(
        device_id=api.device_id,
        started_at=start,
        ended_at=start - timedelta(minutes=5),  # 结束早于开始
    )
    good = make_segment(
        device_id=api.device_id,
        app_key="good",
        started_at=start - timedelta(minutes=5),
        ended_at=start,
    )

    body = _push(api, segments=[bad, good]).json()
    assert body["accepted_activity_segments"] == 1
    assert len(body["rejected"]) == 1
    assert body["rejected"][0]["code"] == "invalid_time_range"
    assert body["rejected"][0]["key"] == bad["id"]


def test_device_id_mismatch_is_rejected(api):
    """不能把记录挂到别的设备上（哪怕是自己的另一台设备）。"""
    api.register(email="sync10@example.com")
    api.bind_device(name="设备甲")

    other_device_id = str(uuid.uuid4())
    segment = make_segment(
        device_id=other_device_id,
        started_at=utcnow(),
        ended_at=utcnow() + timedelta(minutes=1),
    )
    body = _push(api, segments=[segment]).json()
    assert body["accepted_activity_segments"] == 0
    assert body["rejected"][0]["code"] == "invalid_batch"


def test_app_key_with_path_separator_is_rejected(api):
    """隐私防线：app_key 里出现路径分隔符直接拒绝，防止本地路径被上传。"""
    api.register(email="sync11@example.com")
    api.bind_device(name="隐私设备")

    response = _push(
        api,
        apps=[
            make_app_record(
                app_key=r"C:\Program Files\VS Code\Code.exe",
                display_name="Code",
            )
        ],
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_batch_too_large_is_rejected(api):
    api.register(email="sync12@example.com")
    api.bind_device(name="大批设备")

    start = utcnow() - timedelta(hours=5)
    segments = [
        make_segment(
            device_id=api.device_id,
            app_key=f"app{i}",
            started_at=start + timedelta(seconds=i * 10),
            ended_at=start + timedelta(seconds=i * 10 + 5),
        )
        for i in range(201)
    ]
    response = _push(api, segments=segments)
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "batch_too_large"


def test_max_size_batch_is_accepted(api, session_factory):
    """单批 200 条（需求建议上限）必须能一次写完。"""
    api.register(email="sync13@example.com")
    api.bind_device(name="满批设备")

    start = utcnow() - timedelta(hours=5)
    segments = [
        make_segment(
            device_id=api.device_id,
            app_key=f"app{i}",
            started_at=start + timedelta(seconds=i * 10),
            ended_at=start + timedelta(seconds=i * 10 + 5),
        )
        for i in range(200)
    ]
    body = _push(api, segments=segments).json()
    assert body["accepted_activity_segments"] == 200
    assert body["rejected"] == []

    with session_factory() as session:
        count = session.scalar(select(func.count()).select_from(ActivitySegment))
    assert count == 200


def test_pull_cursor_is_monotonic_and_respects_limit(api):
    api.register(email="sync14@example.com")
    api.bind_device(name="游标设备")

    start = utcnow() - timedelta(hours=3)
    segments = [
        make_segment(
            device_id=api.device_id,
            app_key=f"app{i}",
            started_at=start + timedelta(seconds=i * 10),
            ended_at=start + timedelta(seconds=i * 10 + 5),
        )
        for i in range(10)
    ]
    _push(api, segments=segments)

    first = api.get(f"{API}/sync/pull", params={"cursor": 0, "limit": 4}).json()
    assert first["has_more"] is True
    assert len(first["activity_segments"]) == 4
    cursor = first["cursor"]

    second = api.get(f"{API}/sync/pull", params={"cursor": cursor, "limit": 4}).json()
    assert len(second["activity_segments"]) == 4
    assert second["cursor"] > cursor

    # 用最终游标再拉一次：不应再有数据
    final = api.get(f"{API}/sync/pull", params={"cursor": second["cursor"]}).json()
    assert len(final["activity_segments"]) == 2

    empty = api.get(f"{API}/sync/pull", params={"cursor": final["cursor"]}).json()
    assert empty["activity_segments"] == []
    assert empty["cursor"] == final["cursor"], "游标只增不减"


def test_pull_can_filter_by_device(api):
    api.register(email="sync15@example.com")
    api.bind_device(name="过滤设备")
    first_device = api.device_id

    start = utcnow() - timedelta(hours=1)
    _push(
        api,
        segments=[
            make_segment(
                device_id=first_device,
                started_at=start,
                ended_at=start + timedelta(minutes=1),
            )
        ],
    )

    # 换一台设备（同一账户）再上传
    api.device_local_id = str(uuid.uuid4())
    api.bind_device(name="第二台设备")
    _push(
        api,
        segments=[
            make_segment(
                device_id=api.device_id,
                app_key="chrome",
                category="browser",
                started_at=start + timedelta(minutes=5),
                ended_at=start + timedelta(minutes=6),
            )
        ],
    )

    all_rows = api.get(f"{API}/sync/pull", params={"cursor": 0}).json()
    assert len(all_rows["activity_segments"]) == 2, "默认返回账户下全部设备的数据"

    only_first = api.get(
        f"{API}/sync/pull", params={"cursor": 0, "device_ids": [first_device]}
    ).json()
    assert len(only_first["activity_segments"]) == 1
    assert only_first["activity_segments"][0]["device_id"] == first_device


def test_negative_cursor_is_rejected(api):
    api.register(email="sync16@example.com")
    api.bind_device(name="负游标设备")
    response = api.get(f"{API}/sync/pull", params={"cursor": -1})
    assert response.status_code == 422


def test_unknown_fields_are_rejected(api):
    """extra=forbid：客户端不小心传了隐私字段会被立刻拒绝，而不是静默入库。"""
    api.register(email="sync17@example.com")
    api.bind_device(name="严格模式设备")

    start = utcnow()
    segment = make_segment(
        device_id=api.device_id, started_at=start, ended_at=start + timedelta(minutes=1)
    )
    segment["window_title"] = "不该存在的字段"

    response = _push(api, segments=[segment])
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_empty_batch_is_accepted_and_returns_cursor(api):
    api.register(email="sync18@example.com")
    api.bind_device(name="空批设备")
    body = _push(api).json()
    assert body["accepted_total"] == 0
    assert body["rejected"] == []
    assert body["cursor"] >= 0


def test_pull_rejects_bad_limit(api):
    api.register(email="sync19@example.com")
    api.bind_device(name="limit设备")
    assert api.get(f"{API}/sync/pull", params={"limit": 0}).status_code == 422
    assert api.get(f"{API}/sync/pull", params={"limit": 99999}).status_code == 422
