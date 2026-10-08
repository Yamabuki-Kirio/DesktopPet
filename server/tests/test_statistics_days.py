"""`/statistics/days` 与应用归一化的测试（契约见 docs/43 第四、五节）。

两块内容：

1. **日期游标分页**：倒序、默认与上限 7 天、``before`` 为不包含上界、
   翻到最早一天就停、按设备过滤、时区正确、未登录拒绝。
2. **应用归一化**：手机子进程名合并、原始名可追溯、未识别标记、
   重叠去重、多设备仍求和不去重（既有口径不被归一化改掉）。
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

from app.services import app_normalization as norm

from .conftest import API, ApiClient, make_app_record, make_segment

SHANGHAI = "Asia/Shanghai"
CST = timezone(timedelta(hours=8))


def local(year: int, month: int, day: int, hour: int, minute: int) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=CST).astimezone(timezone.utc)


def today_local() -> str:
    return datetime.now(CST).date().isoformat()


def push(api: ApiClient, segments: list[dict], **extra) -> dict:
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


def days(api: ApiClient, **params):
    clean = {k: v for k, v in params.items() if v is not None}
    return api.get(f"{API}/statistics/days", params=clean)


def segment(device_id: str, *, day: int, app_key: str = "code", **kw) -> dict:
    """构造今年 10 月某一天的会话（用「今天」当月份锚点，避免跨月歧义）。"""
    return make_segment(
        device_id=device_id,
        app_key=app_key,
        started_at=local(2026, 10, day, 9, 0),
        ended_at=local(2026, 10, day, 9, 30),
        active_seconds=1800,
        **kw,
    )


# ---------------------------------------------------------------------------
# 1. 日期游标分页
# ---------------------------------------------------------------------------


def test_days_returns_this_week_descending(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    push(
        api,
        [
            segment(api.device_id, day=1, app_key="code"),
            segment(api.device_id, day=2, app_key="chrome"),
            segment(api.device_id, day=3, app_key="code"),
        ],
        applications=[
            make_app_record(app_key="code", display_name="VS Code", category="development"),
            make_app_record(app_key="chrome", display_name="Chrome", category="browser"),
        ],
    )

    body = days(api, before="2026-10-05", limit=7, timezone=SHANGHAI).json()
    dates = [item["date"] for item in body["items"]]
    assert dates == ["2026-10-04", "2026-10-03", "2026-10-02", "2026-10-01"], dates
    assert dates == sorted(dates, reverse=True), "必须按日期倒序"

    by_date = {item["date"]: item for item in body["items"]}
    assert by_date["2026-10-01"]["active_seconds"] == 1800
    assert by_date["2026-10-01"]["device_count"] == 1
    assert by_date["2026-10-01"]["has_data"] is True
    assert by_date["2026-10-01"]["top_apps"][0]["app_name"] == "VS Code"
    # 没有数据的日期照样返回，但明确标记 has_data=false
    assert by_date["2026-10-04"]["has_data"] is False
    assert by_date["2026-10-04"]["active_seconds"] == 0
    assert by_date["2026-10-04"]["top_apps"] == []


def test_days_before_is_exclusive(api: ApiClient) -> None:
    """``before`` 是**不包含**的上界：before=10-03 时 10-03 自己不能出现。"""
    api.register()
    api.bind_device()
    push(api, [segment(api.device_id, day=3), segment(api.device_id, day=2)])

    body = days(api, before="2026-10-03", limit=7, timezone=SHANGHAI).json()
    dates = [item["date"] for item in body["items"]]
    assert "2026-10-03" not in dates, "before 指定的那一天必须被排除"
    assert dates[0] == "2026-10-02"


def test_days_limit_is_capped_at_seven(api: ApiClient) -> None:
    """limit 超过 7 直接 422 —— 不允许用 limit 绕过"每次只加载 7 天"。"""
    api.register()
    response = days(api, before="2026-10-10", limit=30, timezone=SHANGHAI)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_days_has_more_and_next_before_walk_backwards(api: ApiClient) -> None:
    """连续两页：第一页给 next_before，第二页从它继续往前，两页不重不漏。"""
    api.register()
    api.bind_device()
    segments = []
    for day in range(1, 13):
        segments.append(segment(api.device_id, day=day))
    push(api, segments)

    first = days(api, before="2026-10-13", limit=7, timezone=SHANGHAI).json()
    assert len(first["items"]) == 7
    assert first["has_more"] is True
    assert first["next_before"] == "2026-10-06", "游标取本页最后一天，下一页从它往前"
    assert first["items"][0]["date"] == "2026-10-12"

    second = days(api, before=first["next_before"], limit=7, timezone=SHANGHAI).json()
    assert second["items"][0]["date"] == "2026-10-05"
    # 只剩 5 天，不足一页 → 没有更早的了
    assert second["has_more"] is False
    assert second["next_before"] is None

    seen = [i["date"] for i in first["items"]] + [i["date"] for i in second["items"]]
    assert len(seen) == len(set(seen)), "两页之间不能重复"
    assert seen == sorted(seen, reverse=True)
    assert len(seen) == 12, "12 天数据必须不重不漏地翻完"


def test_days_stops_at_the_earliest_record(api: ApiClient) -> None:
    """只有 3 天数据时，has_more 为 false、next_before 为 null。

    否则界面会一直显示「加载更早的 7 天」，用户点到手软也没结果。
    """
    api.register()
    api.bind_device()
    push(api, [segment(api.device_id, day=day) for day in (1, 2, 3)])

    body = days(api, before="2026-10-04", limit=7, timezone=SHANGHAI).json()
    assert len(body["items"]) == 3
    assert body["has_more"] is False
    assert body["next_before"] is None


def test_days_empty_account_returns_empty_page(api: ApiClient) -> None:
    api.register()
    body = days(api, timezone=SHANGHAI).json()
    assert body["items"] == []
    assert body["has_more"] is False
    assert body["next_before"] is None


def test_days_respects_timezone_boundary(api: ApiClient) -> None:
    """UTC 16:30 的会话在 UTC+8 属于"第二天"，不能算到前一天去。

    同时验证分页会在**该账户最早记录**处停下：10-02 比最早一天（10-03）还早，
    因此不会被返回 —— 否则界面会出现一堆永远为空的"更早的日子"。
    """
    api.register()
    api.bind_device()
    # 2026-10-02 16:30 UTC = 2026-10-03 00:30 (+08)
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="code",
                started_at=datetime(2026, 10, 2, 16, 30, tzinfo=timezone.utc),
                ended_at=datetime(2026, 10, 2, 17, 0, tzinfo=timezone.utc),
                active_seconds=1800,
            )
        ],
    )
    body = days(api, before="2026-10-05", limit=7, timezone=SHANGHAI).json()
    by_date = {i["date"]: i for i in body["items"]}
    assert by_date["2026-10-03"]["active_seconds"] == 1800
    assert by_date["2026-10-04"]["has_data"] is False
    assert "2026-10-02" not in by_date, "早于最早记录的日子不再返回"
    assert body["has_more"] is False


def test_days_can_be_filtered_by_device(api: ApiClient, client) -> None:
    email = f"days-multi-{uuid.uuid4().hex[:8]}@example.com"
    api.register(email=email)
    api.bind_device(name="我的电脑")
    first = api.device_id

    second = ApiClient(client)
    second.device_local_id = str(uuid.uuid4())
    assert second.login(email=email).status_code == 200
    assert second.bind_device(name="办公电脑").status_code == 201

    push(api, [segment(first, day=1)])
    push(second, [segment(second.device_id, day=1)])

    only_first = days(api, before="2026-10-02", device_id=first, timezone=SHANGHAI).json()
    assert only_first["items"][0]["active_seconds"] == 1800
    assert only_first["items"][0]["device_count"] == 1

    both = days(api, before="2026-10-02", device_id="all", timezone=SHANGHAI).json()
    assert both["items"][0]["active_seconds"] == 3600, "全部设备求和（既有口径）"
    assert both["items"][0]["device_count"] == 2


def test_days_rejects_bad_before_and_unknown_device(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    bad = days(api, before="not-a-date", timezone=SHANGHAI)
    assert bad.status_code == 422
    assert bad.json()["error"]["code"] == "validation_error"

    other = days(api, device_id=str(uuid.uuid4()), timezone=SHANGHAI)
    assert other.status_code == 404
    assert other.json()["error"]["code"] == "device_not_found"


def test_days_requires_authentication(client) -> None:
    response = client.get(f"{API}/statistics/days", params={"timezone": SHANGHAI})
    assert response.status_code == 401


def test_days_is_read_only(api: ApiClient, session_factory) -> None:
    """分页查询不得写任何表（与既有统计接口同一约束）。"""
    from app.models import ActivitySegment, SyncLog

    api.register()
    api.bind_device()
    push(api, [segment(api.device_id, day=1)])

    def snapshot() -> dict[str, int]:
        with session_factory() as db:
            return {
                "segments": db.query(ActivitySegment).count(),
                "sync_log": db.query(SyncLog).count(),
            }

    before = snapshot()
    assert days(api, before="2026-10-02", timezone=SHANGHAI).status_code == 200
    assert snapshot() == before


def test_days_response_has_no_privacy_fields(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    push(api, [segment(api.device_id, day=1)])
    text = days(api, before="2026-10-02", timezone=SHANGHAI).text.lower()
    for word in ("window_title", "title", "url", "executable_path", "path", "file_path"):
        assert word not in text, f"days 响应里出现了隐私字段 {word}"


# ---------------------------------------------------------------------------
# 2. 应用归一化（纯函数）
# ---------------------------------------------------------------------------


def test_builtin_categories_are_within_the_allowed_enum() -> None:
    """内置表的分类必须全部落在客户端的合法枚举内。

    踩过的坑：一开始写了 ``work`` / ``news`` / ``shopping`` / ``game`` 这些"看起来合理"
    的值，结果客户端一旦同步 ``user_applications``（该字段严格校验）就整体 422。
    这条测试把护栏钉在测试层，配合模块导入时的断言一起防这类回归。
    """
    from app.schemas.sync import APP_CATEGORIES

    allowed = set(APP_CATEGORIES)
    used = {identity.category for identity in norm.BUILTIN_TABLE.values()}
    assert used <= allowed, f"非法分类：{sorted(used - allowed)}"


def test_builtin_display_names_are_unique_per_identity() -> None:
    """同一个统一应用不会被拆成两条身份（例如微信只应有一条 key）。"""
    wechat_keys = {
        key
        for key, identity in norm.BUILTIN_TABLE.items()
        if identity.display_name == "微信" and key == identity.key
    }
    assert wechat_keys == {"com.tencent.mm", "com.tencent.wechat"}


def test_strip_subprocess_suffix_handles_nesting() -> None:
    assert norm.strip_subprocess_suffix("com.tencent.mm") == "com.tencent.mm"
    assert norm.strip_subprocess_suffix("com.tencent.mm:push") == "com.tencent.mm"
    assert norm.strip_subprocess_suffix("com.tencent.mm:tools") == "com.tencent.mm"
    assert norm.strip_subprocess_suffix("com.tencent.mm:appbrand0") == "com.tencent.mm"
    # 多层后缀也要剥干净（Android 上确实会出现）
    assert norm.strip_subprocess_suffix("com.foo:bar:baz") == "com.foo"
    assert norm.strip_subprocess_suffix("") == ""


def test_known_and_unknown_process_names() -> None:
    wechat = norm.normalize("com.tencent.mm:tools")
    assert wechat.key == "com.tencent.mm"
    assert wechat.display_name == "微信"
    assert wechat.category == "social"
    assert wechat.recognized is True
    assert wechat.normalized is True
    assert wechat.raw_app_keys == {"com.tencent.mm:tools"}

    # Windows 可执行名同样命中同一身份
    exe = norm.normalize("WeChat.exe")
    assert exe.key == "com.tencent.mm"
    assert exe.display_name == "微信"

    strange = norm.normalize("com.some.new.app:worker")
    assert strange.recognized is False
    assert strange.display_name == "com.some.new.app:worker", "未识别必须保留原始名"
    assert strange.category == "other"


def test_unknown_suffix_is_stripped_even_if_not_in_whitelist() -> None:
    """白名单只用于解释，不用于准入：新后缀也要能剥。"""
    result = norm.normalize("com.tencent.mm:brand_new_suffix")
    assert result.key == "com.tencent.mm"
    assert result.recognized is True


def test_user_override_wins_when_flagged() -> None:
    result = norm.normalize(
        "code",
        override_name="我的编辑器",
        override_category="work",
        override=True,
    )
    assert result.display_name == "我的编辑器"
    assert result.category == "work"


def test_merge_collects_all_raw_names() -> None:
    merged = norm.merge(
        [
            norm.normalize("com.tencent.mm"),
            norm.normalize("com.tencent.mm:tools"),
            norm.normalize("com.tencent.mm:push"),
        ]
    )
    assert merged.key == "com.tencent.mm"
    assert merged.raw_app_keys == {
        "com.tencent.mm",
        "com.tencent.mm:tools",
        "com.tencent.mm:push",
    }
    assert merged.merged_raw_count == 3


def test_explain_says_why() -> None:
    same = norm.explain("com.tencent.mm")
    assert same["matched"] is True
    assert "精确" in str(same["reason"])

    via_suffix = norm.explain("com.tencent.mm:tools")
    assert via_suffix["matched"] is True
    assert via_suffix["subprocess_suffixes"] == ["tools"]
    assert "子进程" in str(via_suffix["reason"])

    unknown = norm.explain("com.some.new.app")
    assert unknown["matched"] is False
    assert "未收录" in str(unknown["reason"])


# ---------------------------------------------------------------------------
# 3. 归一化接进统计接口后的行为
# ---------------------------------------------------------------------------


def test_android_subprocesses_merge_into_one_app(api: ApiClient) -> None:
    """微信的 4 个进程名必须合成一条，时长按并集算（不翻 4 倍）。"""
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm",
                started_at=local(2026, 10, 6, 10, 0),
                ended_at=local(2026, 10, 6, 10, 30),
                active_seconds=1800,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm:tools",
                started_at=local(2026, 10, 6, 10, 30),
                ended_at=local(2026, 10, 6, 11, 0),
                active_seconds=1800,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm:push",
                started_at=local(2026, 10, 6, 11, 0),
                ended_at=local(2026, 10, 6, 11, 15),
                active_seconds=900,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm:appbrand0",
                started_at=local(2026, 10, 6, 11, 15),
                ended_at=local(2026, 10, 6, 11, 20),
                active_seconds=300,
            ),
        ]
    )

    body = api.get(
        f"{API}/statistics/summary", params={"date": "2026-10-06", "timezone": SHANGHAI}
    ).json()
    assert body["app_count"] == 1, f"四个子进程应合成一个应用：{body['apps']}"
    assert body["total_duration_seconds"] == 4800

    app = body["apps"][0]
    assert app["app_id"] == "com.tencent.mm"
    assert app["app_name"] == "微信"
    assert app["category"] == "social"
    assert app["recognized"] is True
    assert app["normalized"] is True
    assert sorted(app["raw_app_keys"]) == [
        "com.tencent.mm",
        "com.tencent.mm:appbrand0",
        "com.tencent.mm:push",
        "com.tencent.mm:tools",
    ], "原始进程名必须可追溯"


def test_merged_subprocesses_do_not_double_count_overlaps(api: ApiClient) -> None:
    """主进程与子进程的**重叠**区间只算一次。"""
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm",
                started_at=local(2026, 10, 6, 10, 0),
                ended_at=local(2026, 10, 6, 10, 30),
                active_seconds=1800,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm:tools",
                started_at=local(2026, 10, 6, 10, 15),
                ended_at=local(2026, 10, 6, 10, 45),
                active_seconds=1800,
            ),
        ]
    )
    body = api.get(
        f"{API}/statistics/summary", params={"date": "2026-10-06", "timezone": SHANGHAI}
    ).json()
    # 10:00–10:45 并集 = 45 分钟；不是 30+30=60 分钟
    assert body["total_duration_seconds"] == 2700, body


def test_normalization_does_not_break_cross_device_summing(api: ApiClient, client) -> None:
    """归一化之后，「全部设备」仍然是求和不去重（既有口径不被改掉）。"""
    email = f"norm-multi-{uuid.uuid4().hex[:8]}@example.com"
    api.register(email=email)
    api.bind_device(name="我的电脑")
    first = api.device_id

    second = ApiClient(client)
    second.device_local_id = str(uuid.uuid4())
    assert second.login(email=email).status_code == 200
    assert second.bind_device(name="手机").status_code == 201

    push(
        api,
        [
            make_segment(
                device_id=first,
                app_key="com.tencent.mm",
                started_at=local(2026, 10, 6, 10, 0),
                ended_at=local(2026, 10, 6, 10, 30),
                active_seconds=1800,
            )
        ],
    )
    push(
        second,
        [
            make_segment(
                device_id=second.device_id,
                app_key="com.tencent.mm:tools",
                started_at=local(2026, 10, 6, 10, 10),
                ended_at=local(2026, 10, 6, 10, 40),
                active_seconds=1800,
            )
        ],
    )

    body = api.get(
        f"{API}/statistics/summary",
        params={"date": "2026-10-06", "timezone": SHANGHAI, "device_id": "all"},
    ).json()
    assert body["app_count"] == 1, "跨设备的同一个应用应合成一条展示"
    assert body["total_duration_seconds"] == 3600, "跨设备求和不去重"
    assert body["overlap_warning"], "多设备必须提示可能重叠"


def test_unknown_app_is_flagged_for_cleanup(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.vendor.unknown:worker",
                started_at=local(2026, 10, 6, 9, 0),
                ended_at=local(2026, 10, 6, 9, 10),
                active_seconds=600,
            )
        ]
    )
    body = api.get(
        f"{API}/statistics/summary", params={"date": "2026-10-06", "timezone": SHANGHAI}
    ).json()
    app = body["apps"][0]
    assert app["recognized"] is False, "未识别要能被界面标出来"
    assert app["app_name"] == "com.vendor.unknown:worker"
    assert app["raw_app_keys"] == ["com.vendor.unknown:worker"]


def test_sessions_and_timeline_expose_raw_app_key(api: ApiClient) -> None:
    """会话与时间线都要能追溯到原始进程名（定稿第八节）。"""
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm:tools",
                started_at=local(2026, 10, 6, 10, 0),
                ended_at=local(2026, 10, 6, 10, 20),
                active_seconds=1200,
            )
        ]
    )
    params = {"date": "2026-10-06", "timezone": SHANGHAI}

    sessions = api.get(f"{API}/statistics/sessions", params=params).json()
    assert sessions["items"][0]["app_id"] == "com.tencent.mm"
    assert sessions["items"][0]["app_name"] == "微信"
    assert sessions["items"][0]["raw_app_key"] == "com.tencent.mm:tools"

    timeline = api.get(f"{API}/statistics/timeline", params=params).json()
    entry = timeline["items"][0]
    assert entry["app_id"] == "com.tencent.mm"
    assert entry["raw_app_keys"] == ["com.tencent.mm:tools"]
    # 子进程后缀被剥离 → 确实发生了归一（虽然只有一条记录）
    assert entry["normalized"] is True


def test_timeline_merges_main_and_subprocess_into_one_row(api: ApiClient) -> None:
    """主进程与子进程相邻时，时间线上应是一条连续的"微信"。"""
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm",
                started_at=local(2026, 10, 6, 10, 0),
                ended_at=local(2026, 10, 6, 10, 20),
                active_seconds=1200,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm:tools",
                started_at=local(2026, 10, 6, 10, 20),
                ended_at=local(2026, 10, 6, 10, 40),
                active_seconds=1200,
            ),
        ]
    )
    body = api.get(
        f"{API}/statistics/timeline", params={"date": "2026-10-06", "timezone": SHANGHAI}
    ).json()
    assert len(body["items"]) == 1, body["items"]
    entry = body["items"][0]
    assert entry["app_name"] == "微信"
    assert entry["merged_session_count"] == 2
    assert entry["duration_seconds"] == 2400
    assert sorted(entry["raw_app_keys"]) == ["com.tencent.mm", "com.tencent.mm:tools"]
    assert entry["normalized"] is True


def test_user_application_library_name_wins(api: ApiClient) -> None:
    """用户应用库里写过的显示名优先于内置名。"""
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm",
                started_at=local(2026, 10, 6, 10, 0),
                ended_at=local(2026, 10, 6, 10, 10),
                active_seconds=600,
            )
        ],
        applications=[
            make_app_record(
                app_key="com.tencent.mm",
                display_name="我的微信",
                category="productivity",
                user_overridden=True,
            )
        ],
    )
    body = api.get(
        f"{API}/statistics/summary", params={"date": "2026-10-06", "timezone": SHANGHAI}
    ).json()
    app = body["apps"][0]
    assert app["app_name"] == "我的微信"
    assert app["category"] == "productivity"


def test_days_uses_the_same_normalized_names(api: ApiClient) -> None:
    """往日摘要里的应用名与今日视图一致（同一个归一器）。"""
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm:push",
                started_at=local(2026, 10, 1, 9, 0),
                ended_at=local(2026, 10, 1, 9, 30),
                active_seconds=1800,
            )
        ]
    )
    body = days(api, before="2026-10-02", timezone=SHANGHAI).json()
    item = body["items"][0]
    assert item["top_apps"][0]["app_name"] == "微信"
    assert item["top_apps"][0]["app_id"] == "com.tencent.mm"
    assert item["top_apps"][0]["raw_app_keys"] == ["com.tencent.mm:push"]
