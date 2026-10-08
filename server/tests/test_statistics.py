"""Phase 4B：跨设备云端统计接口测试。

覆盖需求第十六节的全部要点：权限隔离、幂等、时区与日期边界、
区间重叠去重、展示合并、跨午夜拆分、分页不重不漏、撤销设备、隐私字段。

数据来源是**真实的同步上传链路**（``POST /api/v1/sync/push``）：
先像 Windows 客户端那样上传原始会话，再用统计接口读回来，
因此这里验证的是"上传 → 落库 → 查询"的完整事实，而不是手工插行。
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

from .conftest import API, ApiClient, make_app_record, make_daily, make_segment

#: 测试固定用的一天（避免依赖真实时钟）
DAY = "2026-09-29"
DAY2 = "2026-09-30"
SHANGHAI = "Asia/Shanghai"
#: Asia/Shanghai = UTC+8
CST = timezone(timedelta(hours=8))


def local(year: int, month: int, day: int, hour: int, minute: int, second: int = 0) -> datetime:
    """构造"上海本地时间"对应的 datetime（返回 UTC 瞬时）。"""
    return datetime(year, month, day, hour, minute, second, tzinfo=CST).astimezone(timezone.utc)


def push_segments(api: ApiClient, segments: list[dict], **extra) -> dict:
    response = api.post(
        f"{API}/sync/push",
        json={
            "activity_segments": segments,
            "daily_usage": extra.get("daily_usage", []),
            "applications": extra.get("applications", []),
        },
    )
    assert response.status_code == 200, response.text
    return response.json()


def query(api: ApiClient, path: str, **params):
    clean = {k: v for k, v in params.items() if v is not None}
    return api.get(f"{API}/statistics/{path}", params=clean)


def apps_by_id(body: dict) -> dict[str, dict]:
    return {item["app_id"]: item for item in body["apps"]}


def test_summary_counts_a_single_device(api: ApiClient) -> None:
    """单设备累计：两段不重叠的会话相加。"""
    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="msedge",
                started_at=local(2026, 9, 29, 9, 12),
                ended_at=local(2026, 9, 29, 9, 35),
                active_seconds=1380,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="msedge",
                started_at=local(2026, 9, 29, 10, 6),
                ended_at=local(2026, 9, 29, 10, 41),
                active_seconds=2100,
            ),
        ],
        applications=[make_app_record(app_key="msedge", display_name="Microsoft Edge", category="browser")],
    )

    body = query(api, "summary", date=DAY, timezone=SHANGHAI).json()
    assert body["date"] == DAY
    assert body["timezone"] == SHANGHAI
    assert body["total_duration_seconds"] == 1380 + 2100
    assert body["session_count"] == 2
    assert body["app_count"] == 1
    assert body["overlap_warning"] is None, "单设备不该出现多设备重叠提示"
    assert body["last_synced_at"] is not None

    app = apps_by_id(body)["msedge"]
    assert app["app_name"] == "Microsoft Edge"
    assert app["category"] == "browser"
    assert app["duration_seconds"] == 3480
    assert app["session_count"] == 2


def test_overlapping_sessions_on_same_device_are_deduplicated(api: ApiClient) -> None:
    """同一设备同一应用的重叠区间只算一次（09:00–09:20 + 09:15–09:30 = 30 分钟）。"""
    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 0),
                ended_at=local(2026, 9, 29, 9, 20),
                active_seconds=1200,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 15),
                ended_at=local(2026, 9, 29, 9, 30),
                active_seconds=900,
            ),
        ]
    )

    body = query(api, "summary", date=DAY, timezone=SHANGHAI).json()
    assert body["total_duration_seconds"] == 1800, "重叠 5 分钟不该被算两次（不是 2100 秒）"
    app = apps_by_id(body)["code"]
    assert app["duration_seconds"] == 1800
    assert app["session_count"] == 2, "去重只影响时长，原始会话条数仍是 2"


def test_all_devices_sums_without_dedup_and_warns(api: ApiClient, client) -> None:
    """全部设备：时长求和（可能重叠），并显式给出提示。"""
    email = f"multi-{uuid.uuid4().hex[:8]}@example.com"
    api.register(email=email, display_name="多设备用户")
    api.bind_device(name="我的电脑")
    first_device = api.device_id

    second = ApiClient(client)
    second.device_local_id = str(uuid.uuid4())
    assert second.login(email=email).status_code == 200
    assert second.bind_device(name="办公电脑").status_code == 201

    push_segments(
        api,
        [
            make_segment(
                device_id=first_device,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 0),
                ended_at=local(2026, 9, 29, 9, 30),
                active_seconds=1800,
            )
        ],
    )
    push_segments(
        second,
        [
            make_segment(
                device_id=second.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 10),
                ended_at=local(2026, 9, 29, 9, 40),
                active_seconds=1800,
            )
        ],
    )

    single = query(api, "summary", date=DAY, timezone=SHANGHAI, device_id=first_device).json()
    assert single["total_duration_seconds"] == 1800

    both = query(api, "summary", date=DAY, timezone=SHANGHAI, device_id="all").json()
    assert both["device_id"] is None
    assert both["total_duration_seconds"] == 3600, "全部设备是求和，不去重"
    assert both["overlap_warning"], "多设备必须提示可能重叠"


def test_cross_midnight_is_split_by_timezone(api: ApiClient) -> None:
    """23:50–00:20 按当地日期拆成 10 分钟 + 20 分钟，原始记录不变。"""
    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 23, 50),
                ended_at=local(2026, 9, 30, 0, 20),
                active_seconds=1800,
            )
        ]
    )

    first = query(api, "summary", date=DAY, timezone=SHANGHAI).json()
    second = query(api, "summary", date=DAY2, timezone=SHANGHAI).json()
    assert first["total_duration_seconds"] == 600, "09-29 只应计入 10 分钟"
    assert second["total_duration_seconds"] == 1200, "09-30 只应计入 20 分钟"

    # 换成 UTC 看：同一条记录会落在 09-29 的 15:50–16:20（不跨 UTC 午夜）
    utc_view = query(api, "summary", date=DAY, timezone="UTC").json()
    assert utc_view["total_duration_seconds"] == 1800


def test_date_boundaries_do_not_leak(api: ApiClient) -> None:
    """日期边界：前一天最后一秒与当天第一秒分别归属正确的日期。"""
    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 28, 23, 59, 30),
                ended_at=local(2026, 9, 28, 23, 59, 59),
                active_seconds=29,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 0, 0, 0),
                ended_at=local(2026, 9, 29, 0, 0, 30),
                active_seconds=30,
            ),
        ]
    )

    yesterday = query(api, "summary", date="2026-09-28", timezone=SHANGHAI).json()
    today = query(api, "summary", date=DAY, timezone=SHANGHAI).json()
    assert yesterday["total_duration_seconds"] == 29
    assert today["total_duration_seconds"] == 30


def test_timeline_merges_adjacent_sessions_for_display(api: ApiClient) -> None:
    """相邻 ≤60s 的同应用会话在时间线合并；时长按区间并集，不用首尾相减。"""
    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 12, 0),
                ended_at=local(2026, 9, 29, 9, 18, 0),
                active_seconds=360,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 18, 20),
                ended_at=local(2026, 9, 29, 9, 35, 0),
                active_seconds=1000,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="wechat",
                started_at=local(2026, 9, 29, 9, 35, 0),
                ended_at=local(2026, 9, 29, 9, 48, 0),
                active_seconds=780,
            ),
        ]
    )

    body = query(api, "timeline", date=DAY, timezone=SHANGHAI).json()
    items = body["items"]
    assert len(items) == 2, "同应用的两次会话应合并；不同应用不合并"

    merged = items[0]
    assert merged["app_id"] == "code"
    assert merged["merged_session_count"] == 2
    assert merged["duration_seconds"] == 360 + 1000, "20 秒间隙不得计入时长"
    # 09:12–09:35（首尾）是 1380 秒，正确结果是 1360 秒 —— 两者必须不同
    assert merged["duration_seconds"] != 1380

    assert items[1]["app_id"] == "wechat"
    assert items[1]["merged_session_count"] == 1
    assert [i["app_id"] for i in items] == ["code", "wechat"], "时间线按开始时间升序"


def test_timeline_does_not_merge_across_large_gap(api: ApiClient) -> None:
    """间隔超过 60 秒不合并。"""
    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 0),
                ended_at=local(2026, 9, 29, 9, 5),
                active_seconds=300,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 6, 1),
                ended_at=local(2026, 9, 29, 9, 10),
                active_seconds=239,
            ),
        ]
    )
    body = query(api, "timeline", date=DAY, timezone=SHANGHAI).json()
    assert len(body["items"]) == 2


def test_sessions_pagination_is_complete_and_unique(api: ApiClient) -> None:
    """分页不重复、不漏项，且会话按开始时间升序。"""
    api.register()
    api.bind_device()
    segments = [
        make_segment(
            device_id=api.device_id,
            app_key="code",
            started_at=local(2026, 9, 29, 9, minute),
            ended_at=local(2026, 9, 29, 9, minute + 1),
            active_seconds=60,
        )
        for minute in range(5)
    ]
    push_segments(api, segments)

    collected: list[str] = []
    cursor = None
    pages = 0
    while True:
        body = query(api, "sessions", date=DAY, timezone=SHANGHAI, limit=2, cursor=cursor).json()
        pages += 1
        collected.extend(item["local_record_id"] for item in body["items"])
        cursor = body["next_cursor"]
        if cursor is None:
            break
        assert pages < 10, "分页未终止，可能是游标实现有误"

    assert len(collected) == 5
    assert len(set(collected)) == 5, "分页出现了重复项"
    assert set(collected) == {s["id"] for s in segments}, "分页漏掉了记录"

    ascending = query(api, "sessions", date=DAY, timezone=SHANGHAI, limit=5).json()
    starts = [item["started_at"] for item in ascending["items"]]
    assert starts == sorted(starts), "会话必须按开始时间升序"


def test_sessions_can_be_filtered_by_app(api: ApiClient) -> None:
    """展开某个应用的时间段：/statistics/sessions?app_id=..."""
    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 48),
                ended_at=local(2026, 9, 29, 10, 20),
                active_seconds=1920,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 15, 13),
                ended_at=local(2026, 9, 29, 15, 33),
                active_seconds=1200,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="msedge",
                started_at=local(2026, 9, 29, 10, 20),
                ended_at=local(2026, 9, 29, 10, 41),
                active_seconds=1260,
            ),
        ],
        applications=[
            make_app_record(app_key="code", display_name="Visual Studio Code", category="development"),
            make_app_record(app_key="msedge", display_name="Microsoft Edge", category="browser"),
        ],
    )

    body = query(api, "sessions", date=DAY, timezone=SHANGHAI, app_id="code").json()
    assert len(body["items"]) == 2
    assert {i["app_id"] for i in body["items"]} == {"code"}
    first = body["items"][0]
    assert first["app_name"] == "Visual Studio Code"
    assert first["duration_seconds"] == 1920
    assert first["device_name"] == "测试设备"
    assert first["platform"] == "windows"
    assert first["local_record_id"] == first["id"]


def test_reuploading_the_same_record_does_not_double_count(api: ApiClient, session_factory) -> None:
    """同一 local_record_id 重复上传：只更新原行，累计不翻倍。"""
    api.register()
    api.bind_device()
    record_id = str(uuid.uuid4())
    payload = make_segment(
        device_id=api.device_id,
        app_key="code",
        started_at=local(2026, 9, 29, 9, 0),
        ended_at=local(2026, 9, 29, 9, 30),
        active_seconds=1800,
        record_id=record_id,
    )
    push_segments(api, [payload])
    push_segments(api, [payload])
    push_segments(api, [payload])

    body = query(api, "summary", date=DAY, timezone=SHANGHAI).json()
    assert body["total_duration_seconds"] == 1800
    assert body["session_count"] == 1

    with session_factory() as db:
        from app.models import ActivitySegment

        count = db.query(ActivitySegment).filter(ActivitySegment.id == uuid.UUID(record_id)).count()
    assert count == 1, "重复上传必须只保留一行"


def test_updating_an_open_session_does_not_insert_a_new_row(api: ApiClient) -> None:
    """未结束会话可以用同一个 local_record_id 持续更新。"""
    api.register()
    api.bind_device()
    record_id = str(uuid.uuid4())
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 0),
                ended_at=None,
                active_seconds=300,
                record_id=record_id,
            )
        ]
    )
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 0),
                ended_at=local(2026, 9, 29, 9, 15),
                active_seconds=900,
                record_id=record_id,
            )
        ]
    )

    body = query(api, "summary", date=DAY, timezone=SHANGHAI).json()
    assert body["session_count"] == 1
    assert body["total_duration_seconds"] == 900


def test_other_users_device_is_not_queryable(api: ApiClient, client) -> None:
    """不能使用别人的 device_id 查询（404，不泄露设备是否存在）。"""
    api.register(email=f"owner-{uuid.uuid4().hex[:8]}@example.com")
    api.bind_device()
    victim_device = api.device_id
    push_segments(
        api,
        [
            make_segment(
                device_id=victim_device,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 0),
                ended_at=local(2026, 9, 29, 9, 30),
                active_seconds=1800,
            )
        ]
    )

    attacker = ApiClient(client)
    attacker.register(email=f"attacker-{uuid.uuid4().hex[:8]}@example.com")
    attacker.bind_device()

    denied = query(attacker, "summary", date=DAY, timezone=SHANGHAI, device_id=victim_device)
    assert denied.status_code == 404
    assert denied.json()["error"]["code"] == "device_not_found"

    # 攻击者自己的汇总里看不到别人的数据
    own = query(attacker, "summary", date=DAY, timezone=SHANGHAI, device_id="all").json()
    assert own["total_duration_seconds"] == 0


def test_invalid_timezone_returns_a_clear_error(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    response = query(api, "summary", date=DAY, timezone="Mars/Olympus")
    assert response.status_code == 422
    body = response.json()
    assert body["error"]["code"] == "validation_error"
    assert "时区" in body["error"]["message"]


def test_invalid_date_and_range_are_rejected(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    bad = query(api, "summary", date="2026-13-99", timezone=SHANGHAI)
    assert bad.status_code == 422

    mixed = query(api, "summary", date=DAY, date_from=DAY, timezone=SHANGHAI)
    assert mixed.status_code == 422, "date 与 date_from 不能同时使用"

    reversed_range = query(api, "summary", date_from=DAY2, date_to=DAY, timezone=SHANGHAI)
    assert reversed_range.status_code == 422


def test_tz_offset_minutes_is_accepted_as_alternative(api: ApiClient) -> None:
    """客户端只有偏移量时也能查询（timezone 的等价替代）。"""
    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 0),
                ended_at=local(2026, 9, 29, 9, 30),
                active_seconds=1800,
            )
        ]
    )
    body = query(api, "summary", date=DAY, tz_offset_minutes=480).json()
    assert body["total_duration_seconds"] == 1800
    assert body["timezone"] == "UTC+08:00"


def test_revoked_device_cannot_upload_anymore(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    assert api.delete(f"{API}/devices/{api.device_id}").status_code in (200, 204)

    response = api.post(
        f"{API}/sync/push",
        json={
            "activity_segments": [
                make_segment(
                    device_id=api.device_id,
                    app_key="code",
                    started_at=local(2026, 9, 29, 9, 0),
                    ended_at=local(2026, 9, 29, 9, 30),
                    active_seconds=1800,
                )
            ],
            "daily_usage": [],
            "applications": [],
        },
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "device_revoked"


def test_statistics_reads_do_not_write_anything(api: ApiClient, session_factory) -> None:
    """云端统计是只读的：查询前后表内容完全不变，也不会产生 outbox 之类副作用。"""
    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 0),
                ended_at=local(2026, 9, 29, 9, 30),
                active_seconds=1800,
            )
        ],
        daily_usage=[make_daily(device_id=api.device_id, local_day=DAY)],
    )

    def snapshot() -> dict[str, int]:
        with session_factory() as db:
            from app.models import ActivitySegment, DailyUsage, SyncLog

            return {
                "segments": db.query(ActivitySegment).count(),
                "daily": db.query(DailyUsage).count(),
                "sync_log": db.query(SyncLog).count(),
            }

    before = snapshot()
    for path in ("summary", "apps", "sessions", "timeline"):
        assert query(api, path, date=DAY, timezone=SHANGHAI).status_code == 200
    assert query(api, "summary", date_from="2026-09-01", date_to=DAY, timezone=SHANGHAI).status_code == 200
    assert snapshot() == before, "统计接口不得写入任何表"


def test_response_contains_no_privacy_fields(api: ApiClient) -> None:
    """响应里不得出现窗口标题 / 路径 / URL 之类的隐私字段。"""
    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 0),
                ended_at=local(2026, 9, 29, 9, 30),
                active_seconds=1800,
            )
        ]
    )

    forbidden = ("window_title", "title", "url", "executable_path", "path", "file_path")
    for path in ("summary", "apps", "sessions", "timeline"):
        text = query(api, path, date=DAY, timezone=SHANGHAI).text.lower()
        for word in forbidden:
            assert word not in text, f"{path} 响应里出现了隐私字段 {word}"


def test_range_query_covers_multiple_days(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 28, 9, 0),
                ended_at=local(2026, 9, 28, 9, 10),
                active_seconds=600,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 0),
                ended_at=local(2026, 9, 29, 9, 20),
                active_seconds=1200,
            ),
        ]
    )
    body = query(api, "summary", date_from="2026-09-28", date_to=DAY, timezone=SHANGHAI).json()
    assert body["date_from"] == "2026-09-28"
    assert body["date_to"] == DAY
    assert body["total_duration_seconds"] == 1800


def test_unauthenticated_requests_are_rejected(client) -> None:
    response = client.get(f"{API}/statistics/summary", params={"date": DAY})
    assert response.status_code == 401


def test_mcp_and_app_api_return_exactly_the_same_numbers(api: ApiClient, app_module) -> None:
    """同一条统计链路：App 的 Bearer 接口、MCP 的密钥接口、真实 MCP 客户端三层完全一致。

    这是需求「MCP 返回值与客户端 API 使用同一统计逻辑，避免两套结果不一致」的
    可执行版本：三者调用同一个服务函数，因此结果必须**逐字段相等**。
    """
    import asyncio

    import httpx

    from mcp_server.client import PetLifeApiClient

    from .test_api_keys import issue_key

    api.register()
    api.bind_device()
    push_segments(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="msedge",
                started_at=local(2026, 9, 29, 9, 12),
                ended_at=local(2026, 9, 29, 9, 35),
                active_seconds=1380,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=local(2026, 9, 29, 9, 48),
                ended_at=local(2026, 9, 29, 10, 20),
                active_seconds=1920,
            ),
        ],
        applications=[
            make_app_record(app_key="msedge", display_name="Microsoft Edge", category="browser"),
            make_app_record(app_key="code", display_name="Visual Studio Code", category="development"),
        ],
    )

    # 1) App 走 Bearer 接口
    app_body = query(api, "summary", date=DAY, timezone=SHANGHAI).json()
    assert app_body["total_duration_seconds"] == 3300

    # 2) MCP 走的密钥接口
    created = issue_key(api)
    key_body = api.http.get(
        f"{API}/integrations/statistics/summary",
        headers={"X-API-Key": created["key"]},
        params={"date": DAY, "timezone": SHANGHAI},
    )
    assert key_body.status_code == 200, key_body.text
    assert key_body.json() == app_body

    # 3) 真实 MCP 客户端（进程内直连 ASGI，不 mock API）
    async def call_mcp() -> dict:
        http = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app_module),
            base_url="http://petlife.test",
        )
        client = PetLifeApiClient(
            base_url="http://petlife.test", api_key=created["key"], http=http
        )
        try:
            return await client.usage_summary(date=DAY, timezone_name=SHANGHAI)
        finally:
            await client.aclose()

    assert asyncio.run(call_mcp()) == app_body


def test_mcp_client_cannot_reach_another_users_device(api: ApiClient, client, app_module) -> None:
    """MCP 密钥同样受设备归属约束：查别人的 device_id 返回 404。"""
    import asyncio

    import httpx

    from mcp_server.client import PetLifeApiClient, PetLifeApiError

    from .test_api_keys import issue_key

    api.register(email=f"owner2-{uuid.uuid4().hex[:8]}@example.com")
    api.bind_device()
    victim_device = api.device_id

    attacker = ApiClient(client)
    attacker.register(email=f"attacker2-{uuid.uuid4().hex[:8]}@example.com")
    attacker.bind_device()
    created = issue_key(attacker)

    async def call_mcp():
        http = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app_module),
            base_url="http://petlife.test",
        )
        mcp_client = PetLifeApiClient(
            base_url="http://petlife.test", api_key=created["key"], http=http
        )
        try:
            return await mcp_client.usage_summary(
                device_id=victim_device, date=DAY, timezone_name=SHANGHAI
            )
        finally:
            await mcp_client.aclose()

    try:
        asyncio.run(call_mcp())
        raise AssertionError("越权查询必须失败")
    except PetLifeApiError as exc:
        assert exc.status_code == 404
        assert exc.code == "device_not_found"
