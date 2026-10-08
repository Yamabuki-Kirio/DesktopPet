"""Phase 2C 趋势测试（契约见 docs/45 第 4.3 节）。

覆盖：只支持 7/30 两档、逐日序列完整、分类占比、专注度趋势、
深夜占比、平台比例、最多应用、无数据天数、多设备重叠提示、账户隔离、只读。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from .conftest import API, ApiClient, make_segment

SHANGHAI = "Asia/Shanghai"
CST = timezone(timedelta(hours=8))
TRENDS = f"{API}/statistics/trends"


def local(year: int, month: int, day: int, hour: int, minute: int) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=CST).astimezone(timezone.utc)


def push(api: ApiClient, segments: list[dict]) -> None:
    response = api.post(f"{API}/sync/push", json={"activity_segments": segments})
    assert response.status_code == 200, response.text


def segments_for(
    device_id: str,
    day: datetime,
    hours: list[tuple[int, int, int]],
    *,
    app_key: str = "code",
    category: str = "development",
) -> list[dict]:
    out = []
    for start_hour, start_minute, duration in hours:
        started = local(day.year, day.month, day.day, start_hour, start_minute)
        out.append(
            make_segment(
                device_id=device_id,
                app_key=app_key,
                category=category,
                started_at=started,
                ended_at=started + timedelta(minutes=duration),
                active_seconds=duration * 60,
            )
        )
    return out


def seed_days(api: ApiClient, *, days: int, per_day_minutes: int = 60) -> None:
    """在最近 days 天里造数据（含今天）。"""
    today = datetime.now(CST).date()
    segments: list[dict] = []
    for offset in range(days):
        target = today - timedelta(days=offset)
        segments += segments_for(
            api.device_id,
            datetime(target.year, target.month, target.day),
            [(10, 0, per_day_minutes)],
        )
    push(api, segments)


def trends(api: ApiClient, **params):
    clean = {k: v for k, v in params.items() if v is not None}
    clean.setdefault("timezone", SHANGHAI)
    return api.get(TRENDS, params=clean)


# ---------------------------------------------------------------------------
# 1. 档位限制
# ---------------------------------------------------------------------------


def test_only_7_and_30_are_accepted(api: ApiClient) -> None:
    """放开任意值等于允许一次拉整年 —— 必须挡住。"""
    api.register()
    api.bind_device()

    assert trends(api, days=7).status_code == 200
    assert trends(api, days=30).status_code == 200

    for bad in (1, 14, 90, 365):
        response = trends(api, days=bad)
        assert response.status_code == 422, bad
        assert response.json()["error"]["code"] == "validation_error"


def test_default_is_seven_days(api: ApiClient) -> None:
    api.register()
    body = trends(api).json()
    assert body["days"] == 7
    assert len(body["daily"]) == 7


# ---------------------------------------------------------------------------
# 2. 逐日序列
# ---------------------------------------------------------------------------


def test_daily_series_is_complete_and_ascending(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    seed_days(api, days=4, per_day_minutes=30)

    body = trends(api, days=7).json()
    dates = [item["date"] for item in body["daily"]]
    assert len(dates) == 7
    assert dates == sorted(dates), "必须按日期升序"
    assert body["date_from"] == dates[0]
    assert body["date_to"] == dates[-1]

    by_date = {item["date"]: item for item in body["daily"]}
    with_data = [d for d in dates if by_date[d]["has_data"]]
    assert len(with_data) == 4, "造了 4 天数据"
    for key in with_data:
        assert by_date[key]["total_seconds"] == 30 * 60

    assert body["insufficient_days"] == 3
    assert body["total_seconds"] == 4 * 30 * 60


def test_thirty_day_window(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    seed_days(api, days=5, per_day_minutes=20)

    body = trends(api, days=30).json()
    assert body["days"] == 30
    assert len(body["daily"]) == 30
    assert body["insufficient_days"] == 25


# ---------------------------------------------------------------------------
# 3. 各维度聚合
# ---------------------------------------------------------------------------


def test_categories_focus_late_night_and_platform(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    today = datetime.now(CST).date()

    segments: list[dict] = []
    # 今天：白天开发 60 分钟 + 深夜娱乐 30 分钟
    segments += segments_for(
        api.device_id, datetime(today.year, today.month, today.day),
        [(10, 0, 60)], app_key="com.microsoft.vscode", category="development",
    )
    segments += segments_for(
        api.device_id, datetime(today.year, today.month, today.day),
        [(23, 30, 30)], app_key="com.netease.cloudmusic", category="entertainment",
    )
    push(api, segments)

    body = trends(api, days=7).json()

    categories = {item["category"]: item for item in body["categories"]}
    assert categories["development"]["total_seconds"] == 3600
    assert categories["entertainment"]["total_seconds"] == 1800
    assert abs(categories["development"]["ratio"] - 2 / 3) < 0.01

    # 深夜 30 分钟 / 总 90 分钟 = 1/3
    assert abs(body["late_night_ratio"] - 1 / 3) < 0.01

    platforms = {item["platform"]: item for item in body["platform_split"]}
    assert "windows" in platforms

    app_names = [item["app_name"] for item in body["top_apps"]]
    assert "Visual Studio Code" in app_names
    assert "网易云音乐" in app_names

    scores = {item["date"]: item["score"] for item in body["focus_scores"]}
    assert len(scores) == 7
    assert scores[body["date_to"]] is not None, "有数据的当天应有专注度分"
    assert scores[body["date_from"]] is None, "无数据的日子不评分"


def test_focus_trend_marks_empty_days_as_null(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    seed_days(api, days=1, per_day_minutes=40)

    body = trends(api, days=7).json()
    assert len(body["focus_scores"]) == 7
    non_null = [item for item in body["focus_scores"] if item["score"] is not None]
    assert len(non_null) == 1
    for item in non_null:
        assert 0 <= item["score"] <= 100


def test_top_apps_are_normalized(api: ApiClient) -> None:
    """趋势里的应用名同样走归一化（子进程合成一条）。"""
    api.register()
    api.bind_device()
    today = datetime.now(CST).date()
    target = datetime(today.year, today.month, today.day)
    segments = segments_for(api.device_id, target, [(9, 0, 30)], app_key="com.tencent.mm")
    segments += segments_for(api.device_id, target, [(10, 0, 30)], app_key="com.tencent.mm:tools")
    push(api, segments)

    body = trends(api, days=7).json()
    wechat = [item for item in body["top_apps"] if item["app_name"] == "微信"]
    assert len(wechat) == 1, body["top_apps"]
    assert wechat[0]["total_seconds"] == 3600


# ---------------------------------------------------------------------------
# 4. 多设备与隔离
# ---------------------------------------------------------------------------


def test_multi_device_keeps_overlap_warning(api: ApiClient, client) -> None:
    email = f"trends-multi-{api.device_local_id[:6]}@example.com"
    api.register(email=email)
    api.bind_device(name="我的电脑")

    second = ApiClient(client)
    second.device_local_id = "local-android-trends"
    assert second.login(email=email).status_code == 200
    assert second.bind_device(
        name="手机", platform="android", architecture="arm64-v8a"
    ).status_code == 201

    seed_days(api, days=2, per_day_minutes=30)
    today = datetime.now(CST).date()
    push(
        second,
        segments_for(
            second.device_id,
            datetime(today.year, today.month, today.day),
            [(10, 15, 30)],
        ),
    )

    body = trends(api, days=7, device_id="all").json()
    assert body["overlap_warning"], "多设备必须提示时长可能重叠"
    platforms = {item["platform"] for item in body["platform_split"]}
    assert {"windows", "android"} <= platforms

    single = trends(api, days=7, device_id=api.device_id).json()
    assert single["overlap_warning"] is None


def test_trends_requires_authentication(client) -> None:
    assert client.get(TRENDS, params={"days": 7, "timezone": SHANGHAI}).status_code == 401


def test_trends_is_isolated_between_accounts(api: ApiClient, client) -> None:
    api.register()
    api.bind_device()
    seed_days(api, days=3, per_day_minutes=45)

    other = ApiClient(client)
    other.register()
    other.bind_device()
    body = trends(other, days=7).json()
    assert body["total_seconds"] == 0
    assert body["insufficient_days"] == 7
    assert body["top_apps"] == []


def test_trends_is_read_only(api: ApiClient, session_factory) -> None:
    from app.models import ActivitySegment, SyncLog

    api.register()
    api.bind_device()
    seed_days(api, days=2)

    def snapshot() -> dict[str, int]:
        with session_factory() as db:
            return {
                "segments": db.query(ActivitySegment).count(),
                "sync_log": db.query(SyncLog).count(),
            }

    before = snapshot()
    assert trends(api, days=7).status_code == 200
    assert trends(api, days=30).status_code == 200
    assert snapshot() == before


def test_trends_response_has_no_privacy_fields(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    seed_days(api, days=2)
    text = trends(api, days=7).text.lower()
    for word in ("window_title", "title", "url", "executable_path", "file_path"):
        assert word not in text, f"trends 响应里出现了隐私字段 {word}"


def test_empty_account_returns_zeroed_trends(api: ApiClient) -> None:
    api.register()
    body = trends(api, days=7).json()
    assert body["total_seconds"] == 0
    assert body["insufficient_days"] == 7
    assert body["late_night_ratio"] == 0.0
    assert all(item["score"] is None for item in body["focus_scores"])
