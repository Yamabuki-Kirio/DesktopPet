"""服务端统计：口径、跨日裁剪、时区、设备合计。"""

from __future__ import annotations

from datetime import timedelta

import pytest

from app.core.timeutil import utcnow
from app.services.stats_service import resolve_window

from .conftest import API, make_daily, make_segment

TZ = 480  # UTC+8


def _near_local_midnight(offset_minutes: int, margin_minutes: int = 3) -> bool:
    """跨日裁剪的断言依赖"测试运行时仍处于同一个本地日"，临近午夜时跳过以免偶发失败。"""
    local = utcnow() + timedelta(minutes=offset_minutes)
    return local.hour == 0 and local.minute < margin_minutes


def _push(api, *, segments=None, daily=None, apps=None):
    return api.post(
        f"{API}/sync/push",
        json={
            "activity_segments": segments or [],
            "daily_usage": daily or [],
            "applications": apps or [],
        },
    )


# ---------------------------------------------------------------------------
# resolve_window：时区与日期归属（纯函数，完全确定）
# ---------------------------------------------------------------------------


def test_resolve_window_uses_client_timezone():
    from datetime import datetime, timezone

    now = datetime(2026, 9, 27, 20, 0, tzinfo=timezone.utc)  # UTC 20:00

    plus8 = resolve_window("today", offset_minutes=480, now=now)
    # 本地已到 09-28 04:00
    assert plus8.day_keys == ["2026-09-28"]
    assert plus8.from_utc == datetime(2026, 9, 27, 16, 0, tzinfo=timezone.utc)
    assert plus8.to_utc == datetime(2026, 9, 28, 16, 0, tzinfo=timezone.utc)

    minus5 = resolve_window("today", offset_minutes=-300, now=now)
    # 本地还是 09-27 15:00
    assert minus5.day_keys == ["2026-09-27"]
    assert minus5.from_utc == datetime(2026, 9, 27, 5, 0, tzinfo=timezone.utc)

    assert plus8.day_keys != minus5.day_keys, "不同时区下「今天」不是同一天"


def test_resolve_window_ranges():
    from datetime import datetime, timezone

    now = datetime(2026, 9, 27, 12, 0, tzinfo=timezone.utc)
    seven = resolve_window("7d", offset_minutes=0, now=now)
    assert len(seven.day_keys) == 7
    assert seven.day_keys[-1] == "2026-09-27"
    assert seven.day_keys[0] == "2026-09-21"

    thirty = resolve_window("30d", offset_minutes=0, now=now)
    assert len(thirty.day_keys) == 30

    today = resolve_window("today", offset_minutes=0, now=now)
    # 7 天窗口 = 今天窗口向前推 6 天
    assert today.from_utc - seven.from_utc == timedelta(days=6)


# ---------------------------------------------------------------------------
# HTTP 层
# ---------------------------------------------------------------------------


def test_summary_separates_the_four_metrics(api):
    api.register(email="stats1@example.com")
    api.bind_device(name="统计设备")
    window = resolve_window("today", offset_minutes=TZ)
    today_local = window.day_keys[0]

    start = window.from_utc + timedelta(hours=1)
    _push(
        api,
        segments=[
            make_segment(
                device_id=api.device_id,
                started_at=start,
                ended_at=start + timedelta(hours=2),
                active_seconds=7200,
            )
        ],
        daily=[
            make_daily(
                device_id=api.device_id,
                local_day=today_local,
                active_seconds=5 * 3600,
                idle_seconds=1800,
                timezone_offset_minutes=TZ,
            )
        ],
    )

    body = api.get(
        f"{API}/stats/summary", params={"period": "today", "tz_offset_minutes": TZ}
    ).json()

    assert body["active_seconds"] == 5 * 3600
    assert body["idle_seconds"] == 1800
    assert body["session_seconds"] == 5 * 3600 + 1800
    assert body["app_active_seconds"] == 7200
    assert body["app_active_seconds"] <= body["active_seconds"]
    assert body["device_count"] == 1
    assert body["timezone_offset_minutes"] == TZ
    assert body["from_utc"].endswith("Z") and body["to_utc"].endswith("Z")


def test_summary_periods_aggregate_days(api):
    api.register(email="stats2@example.com")
    api.bind_device(name="周期设备")
    today = resolve_window("today", offset_minutes=0)
    keys = today.day_keys[0]

    from datetime import datetime

    base_date = datetime.strptime(keys, "%Y-%m-%d").date()
    days = [(base_date - timedelta(days=i)).isoformat() for i in range(5)]

    _push(
        api,
        daily=[
            make_daily(
                device_id=api.device_id, local_day=day, active_seconds=3600, idle_seconds=0
            )
            for day in days
        ],
    )

    one = api.get(f"{API}/stats/summary", params={"period": "today", "tz_offset_minutes": 0}).json()
    assert one["active_seconds"] == 3600

    seven = api.get(f"{API}/stats/summary", params={"period": "7d", "tz_offset_minutes": 0}).json()
    assert seven["active_seconds"] == 5 * 3600

    thirty = api.get(
        f"{API}/stats/summary", params={"period": "30d", "tz_offset_minutes": 0}
    ).json()
    assert thirty["active_seconds"] == 5 * 3600


def test_app_ranking_and_ratios(api):
    api.register(email="stats3@example.com")
    api.bind_device(name="排行设备")
    window = resolve_window("today", offset_minutes=0)
    start = window.from_utc + timedelta(hours=1)

    _push(
        api,
        segments=[
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=start,
                ended_at=start + timedelta(hours=1),
                active_seconds=3600,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="bilibili",
                category="entertainment",
                started_at=start + timedelta(hours=1),
                ended_at=start + timedelta(hours=2),
                active_seconds=1800,
            ),
        ],
        apps=[
            {
                "app_key": "code",
                "display_name": "Visual Studio Code",
                "category": "development",
                "user_overridden": False,
                "updated_at": start.isoformat().replace("+00:00", "Z"),
            }
        ],
    )

    body = api.get(f"{API}/stats/apps", params={"period": "today", "tz_offset_minutes": 0}).json()
    assert body["total_app_active_seconds"] == 5400
    assert body["items"][0]["app_key"] == "code"
    assert body["items"][0]["display_name"] == "Visual Studio Code"
    assert body["items"][0]["segment_count"] == 1
    assert body["items"][0]["ratio_of_app_time"] == pytest.approx(3600 / 5400, abs=1e-6)

    # 没有应用库记录的应用回退到 app_key / 自身分类，而不是报错或丢失
    bilibili = next(i for i in body["items"] if i["app_key"] == "bilibili")
    assert bilibili["display_name"] == "bilibili"
    assert bilibili["category"] == "entertainment"


def test_category_ranking(api):
    api.register(email="stats4@example.com")
    api.bind_device(name="分类统计设备")
    window = resolve_window("today", offset_minutes=0)
    start = window.from_utc + timedelta(hours=1)

    _push(
        api,
        segments=[
            make_segment(
                device_id=api.device_id,
                app_key="code",
                category="development",
                started_at=start,
                ended_at=start + timedelta(hours=1),
                active_seconds=3600,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="wechat",
                category="social",
                started_at=start + timedelta(hours=1),
                ended_at=start + timedelta(hours=2),
                active_seconds=1200,
            ),
        ],
    )

    body = api.get(
        f"{API}/stats/categories", params={"period": "today", "tz_offset_minutes": 0}
    ).json()
    by_category = {item["category"]: item for item in body["items"]}
    assert by_category["development"]["active_seconds"] == 3600
    assert by_category["social"]["active_seconds"] == 1200
    assert body["total_app_active_seconds"] == 4800


def test_device_breakdown_sums_with_overlap_warning(api):
    api.register(email="stats5@example.com")
    api.bind_device(name="设备一号")
    first = api.device_id
    window = resolve_window("today", offset_minutes=0)
    day = window.day_keys[0]

    _push(
        api,
        daily=[
            make_daily(device_id=first, local_day=day, active_seconds=3600, idle_seconds=0)
        ],
    )

    api.device_local_id = "local-device-2"
    api.bind_device(name="设备二号")
    second = api.device_id
    _push(
        api,
        daily=[
            make_daily(device_id=second, local_day=day, active_seconds=1800, idle_seconds=600)
        ],
    )

    body = api.get(
        f"{API}/stats/devices", params={"period": "today", "tz_offset_minutes": 0}
    ).json()
    assert len(body["items"]) == 2
    assert body["total_active_seconds"] == 5400
    assert "重叠" in body["overlap_warning"], "必须提示多设备合计未去重"

    names = {item["device_name"] for item in body["items"]}
    assert names == {"设备一号", "设备二号"}


def test_cross_day_segment_is_split_proportionally(api):
    """跨零点的一段必须按墙钟比例拆到两天，两天之和等于原值。"""
    api.register(email="stats6@example.com")
    api.bind_device(name="跨日设备")

    today = resolve_window("today", offset_minutes=TZ)
    midnight = today.from_utc
    if _near_local_midnight(TZ):
        pytest.skip("距离本地午夜过近，跨日断言不稳定")

    _push(
        api,
        segments=[
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=midnight - timedelta(minutes=30),
                ended_at=midnight + timedelta(minutes=30),
                active_seconds=3600,
            )
        ],
    )

    today_body = api.get(
        f"{API}/stats/summary", params={"period": "today", "tz_offset_minutes": TZ}
    ).json()
    yesterday_body = api.get(
        f"{API}/stats/summary", params={"period": "yesterday", "tz_offset_minutes": TZ}
    ).json()

    assert today_body["app_active_seconds"] == 1800
    assert yesterday_body["app_active_seconds"] == 1800
    assert (
        today_body["app_active_seconds"] + yesterday_body["app_active_seconds"] == 3600
    ), "跨日拆分不得凭空增减时间"


def test_timezone_changes_day_attribution(api):
    """同一段数据在不同时区偏移下会被算进不同的「今天」。

    做法：先算出两个偏移各自的窗口，再构造一个**只落在 +12 窗口内、
    落在 UTC 窗口外**的活动段。这样断言与运行时刻无关，完全确定。
    """
    api.register(email="stats7@example.com")
    api.bind_device(name="时区设备")

    utc_window = resolve_window("today", offset_minutes=0)
    plus12_window = resolve_window("today", offset_minutes=720)
    assert utc_window.from_utc != plus12_window.from_utc, "偏移必须改变「今天」的窗口"

    # 两个候选点相距 21 小时，而两个窗口的重叠只有 12 小时，
    # 因此至少有一个候选点位于 UTC 窗口之外 —— 无需依赖当前时刻。
    candidates = [
        plus12_window.from_utc + timedelta(hours=1),
        plus12_window.to_utc - timedelta(hours=2),
    ]
    outside = [c for c in candidates if not (utc_window.from_utc <= c < utc_window.to_utc)]
    assert outside, "至少应有一个候选点落在 UTC 今天之外"
    seg_start = outside[0]

    _push(
        api,
        segments=[
            make_segment(
                device_id=api.device_id,
                started_at=seg_start,
                ended_at=seg_start + timedelta(hours=1),
                active_seconds=3600,
            )
        ],
    )

    at_utc = api.get(
        f"{API}/stats/summary", params={"period": "today", "tz_offset_minutes": 0}
    ).json()
    at_plus12 = api.get(
        f"{API}/stats/summary", params={"period": "today", "tz_offset_minutes": 720}
    ).json()

    assert at_plus12["app_active_seconds"] == 3600, "在 +12 时区里它属于「今天」"
    assert at_utc["app_active_seconds"] == 0, "在 UTC 时区里它不属于「今天」"
    assert at_utc["app_active_seconds"] != at_plus12["app_active_seconds"]


def test_stats_validation_errors(api):
    api.register(email="stats8@example.com")
    api.bind_device(name="校验设备")

    bad_period = api.get(
        f"{API}/stats/summary", params={"period": "last-century", "tz_offset_minutes": 0}
    )
    assert bad_period.status_code == 422

    bad_offset = api.get(
        f"{API}/stats/summary", params={"period": "today", "tz_offset_minutes": 5000}
    )
    assert bad_offset.status_code == 422


def test_stats_require_authentication(api):
    response = api.http.get(f"{API}/stats/summary")
    assert response.status_code == 401
