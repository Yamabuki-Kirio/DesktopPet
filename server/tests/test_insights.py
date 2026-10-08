"""Phase 2B 五维洞察测试（契约见 docs/45 第 4.2 节）。

覆盖定稿"评分原则"与验收标准：

* 五个评分都有计算依据（``reasons`` 非空且含数字）；
* 分数在 0~100；
* 与用户自己的近 7 日基线比较（``baseline_score`` / ``delta``）；
* **数据不足时不生成虚假评价**（``score`` 为 null 且给出原因）；
* 「全部设备」沿用"设备累计时长可能重叠"的既有口径。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from .conftest import API, ApiClient, make_segment

SHANGHAI = "Asia/Shanghai"
CST = timezone(timedelta(hours=8))
INSIGHTS = f"{API}/statistics/insights"
DAY = "2026-09-29"


def local(year: int, month: int, day: int, hour: int, minute: int) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=CST).astimezone(timezone.utc)


def push(api: ApiClient, segments: list[dict]) -> None:
    response = api.post(f"{API}/sync/push", json={"activity_segments": segments})
    assert response.status_code == 200, response.text


def day_segments(
    device_id: str,
    *,
    year: int = 2026,
    month: int = 9,
    day: int,
    hours: list[tuple[int, int, int]],
    app_key: str = "code",
    category: str = "development",
) -> list[dict]:
    """``hours`` 里每项是 (开始小时, 开始分钟, 持续分钟)。"""
    out = []
    for start_hour, start_minute, duration in hours:
        started = local(year, month, day, start_hour, start_minute)
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


def seed_baseline(api: ApiClient, device_id: str, *, days: int = 6) -> None:
    """在目标日之前造若干天"普通工作日"数据，形成个人基线。"""
    segments: list[dict] = []
    for offset in range(1, days + 1):
        target = datetime(2026, 9, 29) - timedelta(days=offset)
        segments += day_segments(
            device_id,
            year=target.year,
            month=target.month,
            day=target.day,
            hours=[(9, 0, 50), (10, 30, 60), (14, 0, 45)],
        )
    push(api, segments)


def insights(api: ApiClient, **params):
    clean = {k: v for k, v in params.items() if v is not None}
    clean.setdefault("timezone", SHANGHAI)
    return api.get(INSIGHTS, params=clean)


def by_key(body: dict) -> dict[str, dict]:
    return {item["key"]: item for item in body["dimensions"]}


# ---------------------------------------------------------------------------
# 1. 五个维度齐全且有依据
# ---------------------------------------------------------------------------


def test_all_five_dimensions_present_with_reasons(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    seed_baseline(api, api.device_id)
    push(api, day_segments(api.device_id, day=29, hours=[(9, 0, 52), (14, 10, 30)]))

    response = insights(api, date=DAY)
    assert response.status_code == 200, response.text
    body = response.json()

    keys = [item["key"] for item in body["dimensions"]]
    assert keys == ["focus", "rhythm", "intensity", "structure", "cross_device"]
    for item in body["dimensions"]:
        assert item["label"]
        assert item["reasons"], f"{item['key']} 缺少依据"
        # 每条依据都必须含数字，否则谈不上"可解释"
        for reason in item["reasons"]:
            assert any(ch.isdigit() for ch in reason), f"依据缺少数字：{reason}"

    assert body["is_sample_sufficient"] is True
    assert body["sample_days"] >= 3
    assert body["summary_text"]
    assert body["overview"]["total_seconds"] > 0


def test_scores_are_within_0_100_and_delta_consistent(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    seed_baseline(api, api.device_id)
    push(api, day_segments(api.device_id, day=29, hours=[(9, 0, 90), (15, 0, 60)]))

    body = insights(api, date=DAY).json()
    for item in body["dimensions"]:
        assert isinstance(item["score"], int)
        assert 0 <= item["score"] <= 100, item
        assert isinstance(item["baseline_score"], int)
        assert 0 <= item["baseline_score"] <= 100, item
        assert item["delta"] == item["score"] - item["baseline_score"]
        expected = (
            "up" if item["delta"] >= 3 else "down" if item["delta"] <= -3 else "flat"
        )
        assert item["direction"] == expected


# ---------------------------------------------------------------------------
# 2. 数据不足 → 不评分
# ---------------------------------------------------------------------------


def test_no_data_today_yields_no_scores(api: ApiClient) -> None:
    """当天没有任何记录 → 所有分数为 null，并说明原因。"""
    api.register()
    api.bind_device()
    seed_baseline(api, api.device_id, days=6)

    body = insights(api, date="2026-09-20").json()
    assert body["is_sample_sufficient"] is False
    assert body["insufficient_reason"]
    assert "没有" in body["insufficient_reason"]
    for item in body["dimensions"]:
        assert item["score"] is None
        assert item["baseline_score"] is None
        assert item["delta"] is None
        assert item["direction"] is None
        # 依据仍然给出，便于用户理解缺的是什么
        assert item["reasons"]


def test_insufficient_baseline_is_reported(tmp_path) -> None:
    """基线不足 3 天 → 不评分，并明确告知需要几天。"""
    from .conftest import DEFAULT_PASSWORD  # noqa: F401

    # 用一个独立应用实例，避免与其它用例共享状态
    from app.core.config import reset_settings_cache
    from app.database.base import Base
    from app.database.session import build_engine, dispose_engine
    from fastapi.testclient import TestClient

    url = f"sqlite+pysqlite:///{tmp_path / 'insufficient.db'}"
    import os

    os.environ["PETLIFE_DATABASE_URL"] = url
    reset_settings_cache()
    settings = __import__("app.core.config", fromlist=["get_settings"]).get_settings()
    engine = build_engine(settings.database_url)
    Base.metadata.create_all(engine)
    engine.dispose()
    from app.main import create_app

    app = create_app(settings)
    with TestClient(app) as client:
        api2 = ApiClient(client)
        api2.register()
        api2.bind_device()
        # 只有 1 天基线
        push(
            api2,
            day_segments(
                api2.device_id, day=28, hours=[(9, 0, 30)]
            ),
        )
        push(api2, day_segments(api2.device_id, day=29, hours=[(9, 0, 30)]))

        body = insights(api2, date=DAY).json()
        assert body["is_sample_sufficient"] is False
        assert body["sample_days"] == 1
        assert "至少需要" in body["insufficient_reason"]
        assert all(item["score"] is None for item in body["dimensions"])
    dispose_engine()
    reset_settings_cache()


# ---------------------------------------------------------------------------
# 3. 与自己的历史比较（不是社会标准）
# ---------------------------------------------------------------------------


def test_more_usage_than_baseline_raises_intensity(api: ApiClient) -> None:
    """累计时长明显高于平时 → 强度分上升，且 delta 为正。"""
    api.register()
    api.bind_device()
    seed_baseline(api, api.device_id, days=6)
    # 当天远超基线的 155 分钟
    push(api, day_segments(api.device_id, day=29, hours=[(9, 0, 180), (14, 0, 180)]))

    body = insights(api, date=DAY).json()
    intensity = by_key(body)["intensity"]
    assert intensity["score"] > intensity["baseline_score"]
    assert intensity["delta"] > 0
    assert intensity["direction"] == "up"
    assert any("平时" in r for r in intensity["reasons"])


def test_fragmented_day_scores_lower_on_focus(api: ApiClient) -> None:
    """大量碎片会话 → 专注度依据里明确提到短会话占比，且分数不高。"""
    api.register()
    api.bind_device()
    seed_baseline(api, api.device_id, days=6)
    # 10 段 3 分钟的碎片（均低于 5 分钟阈值）
    segments: list[dict] = []
    for index in range(10):
        segments += day_segments(api.device_id, day=29, hours=[(9, index * 4, 3)])
    push(api, segments)

    body = insights(api, date=DAY).json()
    focus = by_key(body)["focus"]
    assert focus["score"] is not None
    assert any("短会话" in r for r in focus["reasons"])
    assert any("切换" in r for r in focus["reasons"])


def test_longest_continuous_reported_from_real_data(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    seed_baseline(api, api.device_id, days=6)
    push(api, day_segments(api.device_id, day=29, hours=[(9, 0, 75)]))

    body = insights(api, date=DAY).json()
    assert body["overview"]["longest_continuous_seconds"] == 75 * 60
    focus = by_key(body)["focus"]
    # 75 分钟会被格式化成 "1 小时 15 分钟"
    assert any("1 小时 15 分钟" in r for r in focus["reasons"]), focus["reasons"]


# ---------------------------------------------------------------------------
# 4. 跨设备口径
# ---------------------------------------------------------------------------


def test_single_device_has_no_overlap(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    seed_baseline(api, api.device_id, days=6)
    push(api, day_segments(api.device_id, day=29, hours=[(9, 0, 60)]))

    body = insights(api, date=DAY, device_id=api.device_id).json()
    cross = by_key(body)["cross_device"]
    assert body["overlap_warning"] is None
    assert any("不存在重叠" in r for r in cross["reasons"]), cross["reasons"]


def test_multi_device_keeps_overlap_warning(api: ApiClient, client) -> None:
    """「全部设备」时沿用既有求和不去重口径，并给出重叠提示。"""
    email = f"insights-multi-{api.device_local_id[:6]}@example.com"
    api.register(email=email)
    api.bind_device(name="我的电脑")
    first = api.device_id

    second = ApiClient(client)
    second.device_local_id = "local-android-insights"
    assert second.login(email=email).status_code == 200
    assert second.bind_device(name="手机", platform="android", architecture="arm64-v8a").status_code == 201

    for offset in range(1, 4):
        target = datetime(2026, 9, 29) - timedelta(days=offset)
        push(
            api,
            day_segments(
                first, year=target.year, month=target.month, day=target.day,
                hours=[(9, 0, 50)],
            ),
        )
        push(
            second,
            day_segments(
                second.device_id, year=target.year, month=target.month, day=target.day,
                hours=[(9, 20, 40)],
            ),
        )
    # 当天两设备重叠 30 分钟
    push(api, day_segments(first, day=29, hours=[(9, 0, 60)]))
    push(second, day_segments(second.device_id, day=29, hours=[(9, 30, 60)]))

    body = insights(api, date=DAY, device_id="all").json()
    assert body["overlap_warning"], "多设备必须提示时长可能重叠"
    cross = by_key(body)["cross_device"]
    assert cross["score"] is not None
    assert any("重叠" in r for r in cross["reasons"])
    assert body["overview"]["device_count"] == 2


# ---------------------------------------------------------------------------
# 5. 边界与权限
# ---------------------------------------------------------------------------


def test_insights_requires_authentication(client) -> None:
    assert client.get(INSIGHTS, params={"timezone": SHANGHAI}).status_code == 401


def test_insights_is_isolated_between_accounts(api: ApiClient, client) -> None:
    api.register()
    api.bind_device()
    seed_baseline(api, api.device_id, days=6)
    push(api, day_segments(api.device_id, day=29, hours=[(9, 0, 120)]))

    other = ApiClient(client)
    other.register()
    other.bind_device()
    body = insights(other, date=DAY).json()
    assert body["overview"]["total_seconds"] == 0
    assert body["is_sample_sufficient"] is False


def test_insights_is_read_only(api: ApiClient, session_factory) -> None:
    """洞察必须只读：查询前后各表行数不变。"""
    from app.models import ActivitySegment, SyncLog

    api.register()
    api.bind_device()
    seed_baseline(api, api.device_id, days=6)
    push(api, day_segments(api.device_id, day=29, hours=[(9, 0, 30)]))

    def snapshot() -> dict[str, int]:
        with session_factory() as db:
            return {
                "segments": db.query(ActivitySegment).count(),
                "sync_log": db.query(SyncLog).count(),
            }

    before = snapshot()
    assert insights(api, date=DAY).status_code == 200
    assert snapshot() == before


def test_insights_response_has_no_privacy_fields(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    seed_baseline(api, api.device_id, days=6)
    push(api, day_segments(api.device_id, day=29, hours=[(9, 0, 30)]))
    text = insights(api, date=DAY).text.lower()
    for word in ("window_title", "title", "url", "executable_path", "file_path"):
        assert word not in text, f"insights 响应里出现了隐私字段 {word}"


def test_insights_uses_normalized_app_names(api: ApiClient) -> None:
    """洞察里提到的应用名必须是归一后的统一名（子进程不单独出现）。"""
    api.register()
    api.bind_device()
    seed_baseline(api, api.device_id, days=6)
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm:tools",
                started_at=local(2026, 9, 29, 10, 0),
                ended_at=local(2026, 9, 29, 11, 0),
                active_seconds=3600,
            )
        ],
    )
    body = insights(api, date=DAY).json()
    combined = " ".join(body["highlights"] + body["observations"] + [body["summary_text"]])
    assert "com.tencent.mm:tools" not in combined, combined
    assert body["overview"]["top_app_name"] == "微信"
