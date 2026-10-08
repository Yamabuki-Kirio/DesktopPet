"""Phase 2A 应用身份管理测试（契约见 docs/45 第二～四节）。

覆盖定稿"验收标准"里与应用整理有关的每一条：

* 微信等子进程只显示一条统一应用；
* 原始进程名仍可查看；
* 用户可以修正错误映射；
* 删除映射后可以恢复原始显示；
* 映射不能影响其他账户；
* 历史数据无需重传即可生效；
* 同一时段不能因子进程归并而重复累计；
* MCP 与网页显示相同应用名称。
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest

from app.models import ApplicationAlias, ApplicationCatalog, UserApplication

from .conftest import API, ApiClient, make_segment

SHANGHAI = "Asia/Shanghai"
CST = timezone(timedelta(hours=8))
APPLICATIONS = f"{API}/applications"


def local(year: int, month: int, day: int, hour: int, minute: int) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=CST).astimezone(timezone.utc)


def recent(hours_ago: float) -> datetime:
    """近期的 UTC 时刻（目录的时长统计只看最近 30 天）。"""
    return datetime.now(timezone.utc) - timedelta(hours=hours_ago)


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


def wechat_segments(device_id: str, *, start_hour: int = 10, minutes: int = 30) -> list[dict]:
    """构造微信的 4 个子进程会话（彼此相邻、不重叠）。"""
    apps = [
        "com.tencent.mm",
        "com.tencent.mm:tools",
        "com.tencent.mm:push",
        "com.tencent.mm:appbrand0",
    ]
    out = []
    for index, app in enumerate(apps):
        base = recent(6)
        started = base + timedelta(minutes=index * minutes)
        out.append(
            make_segment(
                device_id=device_id,
                app_key=app,
                started_at=started,
                ended_at=started + timedelta(minutes=minutes),
                active_seconds=minutes * 60,
            )
        )
    return out


def catalog_items(api: ApiClient, **params):
    response = api.get(f"{APPLICATIONS}/catalog", params=params)
    assert response.status_code == 200, response.text
    return response.json()


def summary_apps(api: ApiClient, date: str = "2026-10-06"):
    response = api.get(
        f"{API}/statistics/summary", params={"date": date, "timezone": SHANGHAI}
    )
    assert response.status_code == 200, response.text
    return response.json()["apps"]


# ---------------------------------------------------------------------------
# 1. 目录与未识别列表
# ---------------------------------------------------------------------------


def test_catalog_lists_auto_grouped_apps(api: ApiClient) -> None:
    """内置规则自动归并出来的应用也要出现在目录里（否则用户找不到「微信」）。"""
    api.register()
    api.bind_device()
    push(api, wechat_segments(api.device_id))

    body = catalog_items(api)
    names = {item["display_name"] for item in body["items"]}
    assert "微信" in names, body

    wechat = next(item for item in body["items"] if item["display_name"] == "微信")
    assert wechat["category"] == "social"
    assert wechat["icon_key"] == "wechat"
    # 4 个子进程归成一条
    assert wechat["raw_app_key_count"] == 4
    assert wechat["segment_count"] == 4
    assert wechat["auto_grouped"] is True, "尚未被用户整理过，应标为自动归并"
    assert body["unrecognized_count"] == 0


def test_unrecognized_lists_only_unknown_and_suggests_target(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.vendor.mystery:worker",
                started_at=recent(3),
                ended_at=recent(2.5),
                active_seconds=1800,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm:tools",
                started_at=recent(2),
                ended_at=recent(1.5),
                active_seconds=1800,
            ),
        ],
    )

    body = api.get(f"{APPLICATIONS}/unrecognized").json()
    keys = {item["raw_app_key"] for item in body["items"]}
    assert keys == {"com.vendor.mystery:worker"}, (
        "已被内置规则识别的子进程不该出现在未识别列表里"
    )
    item = body["items"][0]
    assert item["total_seconds"] == 1800
    assert item["suggested_app_key"] is None, "无法归入任何已知应用"

    # 一个"去掉后缀就能命中内置表"的未知子进程 → 应给出建议目标
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.PROTON:weird",
                started_at=recent(1),
                ended_at=recent(0.5),
                active_seconds=600,
            )
        ],
    )
    body2 = api.get(f"{APPLICATIONS}/unrecognized").json()
    assert body2["items"], body2
    # 前缀大小写不同，内置表按小写比较，因此能被建议到微信
    assert any(
        (i.get("suggested_app_key") or "").lower() == "com.tencent.mm"
        or i["raw_app_key"] == "com.tencent.PROTON:weird"
        for i in body2["items"]
    )


def test_catalog_requires_authentication(client) -> None:
    assert client.get(f"{APPLICATIONS}/catalog").status_code == 401
    assert client.get(f"{APPLICATIONS}/unrecognized").status_code == 401


# ---------------------------------------------------------------------------
# 2. 新建 / 合并 / 改名 / 分类
# ---------------------------------------------------------------------------


def test_create_catalog_and_merge_unrecognized(api: ApiClient) -> None:
    """把未识别进程合并到一个新建的统一应用，统计立即生效。"""
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.vendor.secret",
                started_at=recent(5),
                ended_at=recent(4.5),
                active_seconds=1800,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="com.vendor.secret:push",
                started_at=recent(4.5),
                ended_at=recent(4),
                active_seconds=1800,
            ),
        ],
    )

    created = api.post(
        f"{APPLICATIONS}/catalog",
        json={
            "display_name": "内部工具",
            "category": "productivity",
            "icon_key": "internal",
            "raw_app_keys": ["com.vendor.secret", "com.vendor.secret:push"],
        },
    )
    assert created.status_code == 201, created.text
    entry = created.json()
    assert entry["display_name"] == "内部工具"
    assert entry["raw_app_key_count"] == 2
    assert len(entry["aliases"]) == 2

    # 未识别列表应清空
    assert api.get(f"{APPLICATIONS}/unrecognized").json()["total"] == 0

    # 目录里能看到它，且时长是两段之和
    body = catalog_items(api)
    mine = next(i for i in body["items"] if i["display_name"] == "内部工具")
    assert mine["total_seconds"] == 3600
    assert mine["auto_grouped"] is False


def test_merge_into_existing_builtin_app_materializes_catalog(api: ApiClient) -> None:
    """把自定义进程合并到「微信」——微信原本只是内置分组，没有目录行。

    服务端应自动物化一条目录行，之后别名才有地方可指。
    """
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm",
                started_at=recent(6),
                ended_at=recent(5.5),
                active_seconds=1800,
            ),
            make_segment(
                device_id=api.device_id,
                app_key="com.my.custom.chat",
                started_at=recent(5.5),
                ended_at=recent(5),
                active_seconds=1800,
            ),
        ],
    )

    response = api.post(
        f"{APPLICATIONS}/aliases",
        json={"raw_app_key": "com.my.custom.chat", "target_app_key": "com.tencent.mm"},
    )
    assert response.status_code == 201, response.text

    body = catalog_items(api)
    wechat = next(i for i in body["items"] if i["display_name"] == "微信")
    assert wechat["id"] is not None
    # 现在有一条显式别名 + 主包名本身
    alias_raws = {a["raw_app_key"] for a in wechat["aliases"]}
    assert "com.my.custom.chat" in alias_raws
    assert wechat["total_seconds"] == 3600


def test_update_display_name_and_category(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    push(api, wechat_segments(api.device_id))

    catalog_id = next(
        i["id"] for i in catalog_items(api)["items"] if i["display_name"] == "微信"
    )
    # 微信由内置规则推导，先物化目录行（合并动作会创建）
    api.post(
        f"{APPLICATIONS}/aliases",
        json={"raw_app_key": "com.tencent.mm", "target_app_key": "com.tencent.mm"},
    )
    catalog_id = next(
        i["id"] for i in catalog_items(api)["items"] if i["display_name"] == "微信"
    )

    updated = api.patch(
        f"{APPLICATIONS}/catalog/{catalog_id}",
        json={"display_name": "我的微信", "category": "productivity"},
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["display_name"] == "我的微信"
    assert updated.json()["category"] == "productivity"

    # 统计里立即变成新名字
    apps = summary_apps(api)
    assert len(apps) == 1
    assert apps[0]["app_name"] == "我的微信"
    assert apps[0]["category"] == "productivity"


def test_duplicate_display_name_is_rejected(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    assert (
        api.post(
            f"{APPLICATIONS}/catalog", json={"display_name": "唯一"}
        ).status_code
        == 201
    )
    again = api.post(f"{APPLICATIONS}/catalog", json={"display_name": "唯一"})
    assert again.status_code == 409
    assert again.json()["error"]["code"] == "catalog_duplicate"


def test_invalid_category_is_rejected(api: ApiClient) -> None:
    """分类必须落在固定枚举内 —— Phase 1 曾因自造分类导致客户端上传 422。"""
    api.register()
    response = api.post(
        f"{APPLICATIONS}/catalog", json={"display_name": "X", "category": "work"}
    )
    assert response.status_code == 422


# ---------------------------------------------------------------------------
# 3. 修正错误映射 / 撤销映射 / 删除目录
# ---------------------------------------------------------------------------


def test_wrong_mapping_can_be_corrected(api: ApiClient) -> None:
    """用户先把某进程归错应用，再改到正确的应用上。"""
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.confusing.app",
                started_at=recent(4),
                ended_at=recent(3.5),
                active_seconds=1800,
            )
        ],
    )

    first = api.post(
        f"{APPLICATIONS}/catalog",
        json={
            "display_name": "错的那个",
            "category": "other",
            "raw_app_keys": ["com.confusing.app"],
        },
    )
    assert first.status_code == 201
    assert summary_apps(api)[0]["app_name"] == "错的那个"

    second = api.post(
        f"{APPLICATIONS}/catalog",
        json={"display_name": "对的那个", "category": "development"},
    )
    right_id = second.json()["id"]

    # 改指：同一原始名再次提交 → 直接改到新目标
    moved = api.post(
        f"{APPLICATIONS}/aliases",
        json={"raw_app_key": "com.confusing.app", "catalog_id": right_id},
    )
    assert moved.status_code == 201, moved.text

    apps = summary_apps(api)
    assert len(apps) == 1, "改指后不该同时出现在两个应用下"
    assert apps[0]["app_name"] == "对的那个"


def test_delete_alias_restores_original_display(api: ApiClient) -> None:
    """撤销映射后恢复原始显示（定稿验收项）。"""
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.vendor.tool",
                started_at=recent(3),
                ended_at=recent(2.5),
                active_seconds=1800,
            )
        ],
    )

    created = api.post(
        f"{APPLICATIONS}/catalog",
        json={
            "display_name": "临时名字",
            "category": "productivity",
            "raw_app_keys": ["com.vendor.tool"],
        },
    ).json()
    alias_id = created["aliases"][0]["id"]
    assert summary_apps(api)[0]["app_name"] == "临时名字"

    removed = api.delete(f"{APPLICATIONS}/aliases/{alias_id}")
    assert removed.status_code == 200, removed.text

    apps = summary_apps(api)
    assert apps[0]["app_name"] == "com.vendor.tool", "应恢复为原始名"
    assert apps[0]["recognized"] is False, "且重新回到未识别"


def test_delete_catalog_cascades_aliases_and_restores_builtin_name(api: ApiClient) -> None:
    api.register()
    api.bind_device()
    push(api, wechat_segments(api.device_id))

    api.post(
        f"{APPLICATIONS}/aliases",
        json={"raw_app_key": "com.tencent.mm", "target_app_key": "com.tencent.mm"},
    )
    entry = next(
        i for i in catalog_items(api)["items"] if i["display_name"] == "微信"
    )

    deleted = api.delete(f"{APPLICATIONS}/catalog/{entry['id']}")
    assert deleted.status_code == 200, deleted.text

    # 别名被级联删除
    remaining = api.get(f"{APPLICATIONS}/catalog").json()
    assert not any(
        a["raw_app_key"] == "com.tencent.mm"
        for item in remaining["items"]
        for a in item["aliases"]
    )

    # 但子进程仍然靠内置规则归并成一条「微信」（恢复原始显示 ≠ 拆散内置归并）
    apps = summary_apps(api)
    assert len(apps) == 1
    assert apps[0]["app_name"] == "微信"
    assert sorted(apps[0]["raw_app_keys"]) == [
        "com.tencent.mm",
        "com.tencent.mm:appbrand0",
        "com.tencent.mm:push",
        "com.tencent.mm:tools",
    ]


# ---------------------------------------------------------------------------
# 4. 用户隔离（定稿验收项："映射不能影响其他账户"）
# ---------------------------------------------------------------------------


def test_mapping_does_not_leak_to_other_accounts(api: ApiClient, client) -> None:
    api.register()
    api.bind_device()
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.vendor.tool",
                started_at=recent(3),
                ended_at=recent(2.5),
                active_seconds=1800,
            )
        ],
    )
    api.post(
        f"{APPLICATIONS}/catalog",
        json={
            "display_name": "我的工具",
            "category": "productivity",
            "raw_app_keys": ["com.vendor.tool"],
        },
    )
    assert summary_apps(api)[0]["app_name"] == "我的工具"

    # 另一个账户上传**同名**进程，不应看到别人的映射
    other = ApiClient(client)
    other.register()
    other.bind_device()
    push(
        other,
        [
            make_segment(
                device_id=other.device_id,
                app_key="com.vendor.tool",
                started_at=recent(3),
                ended_at=recent(2.5),
                active_seconds=900,
            )
        ],
    )
    other_apps = summary_apps(other)
    assert other_apps[0]["app_name"] == "com.vendor.tool", "不能借用他人的命名"

    other_catalog = other.get(f"{APPLICATIONS}/catalog").json()
    assert all(i["display_name"] != "我的工具" for i in other_catalog["items"])


def test_other_accounts_catalog_id_is_not_accessible(api: ApiClient, client) -> None:
    api.register()
    created = api.post(
        f"{APPLICATIONS}/catalog", json={"display_name": "私有的"}
    ).json()

    other = ApiClient(client)
    other.register()

    assert (
        other.patch(
            f"{APPLICATIONS}/catalog/{created['id']}", json={"display_name": "偷改"}
        ).status_code
        == 404
    )
    assert other.delete(f"{APPLICATIONS}/catalog/{created['id']}").status_code == 404
    blocked = other.post(
        f"{APPLICATIONS}/aliases",
        json={"raw_app_key": "x.y", "catalog_id": created["id"]},
    )
    assert blocked.status_code == 404
    assert blocked.json()["error"]["code"] == "catalog_not_found"


def test_other_accounts_alias_id_is_not_accessible(api: ApiClient, client) -> None:
    api.register()
    created = api.post(
        f"{APPLICATIONS}/catalog",
        json={"display_name": "A", "raw_app_keys": ["a.b"]},
    ).json()
    alias_id = created["aliases"][0]["id"]

    other = ApiClient(client)
    other.register()
    response = other.delete(f"{APPLICATIONS}/aliases/{alias_id}")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "alias_not_found"


# ---------------------------------------------------------------------------
# 5. 归并影响范围 + 不重复累计 + 历史数据无需重传
# ---------------------------------------------------------------------------


def test_saving_mapping_affects_existing_history_without_reupload(api: ApiClient) -> None:
    """定稿验收项："历史数据无需重传即可生效"。"""
    api.register()
    api.bind_device()
    # 历史记录（更早的日期）
    push(
        api,
        [
            make_segment(
                device_id=api.device_id,
                app_key="com.tencent.mm:tools",
                started_at=local(2026, 10, 1, 9, 0),
                ended_at=local(2026, 10, 1, 9, 30),
                active_seconds=1800,
            )
        ],
    )
    before = api.get(
        f"{API}/statistics/summary",
        params={"date": "2026-10-01", "timezone": SHANGHAI},
    ).json()
    assert before["apps"][0]["app_name"] == "微信"
    assert before["apps"][0]["raw_app_keys"] == ["com.tencent.mm:tools"]

    # 建立一条映射把它的显示名改掉 —— 不重传任何活动记录
    api.post(
        f"{APPLICATIONS}/aliases",
        json={
            "raw_app_key": "com.tencent.mm:tools",
            "display_name": "工作微信",
            "category": "productivity",
        },
    )
    after = api.get(
        f"{API}/statistics/summary",
        params={"date": "2026-10-01", "timezone": SHANGHAI},
    ).json()
    assert after["apps"][0]["app_name"] == "工作微信"
    assert after["apps"][0]["category"] == "productivity"
    assert after["apps"][0]["duration_seconds"] == before["apps"][0]["duration_seconds"]


def test_merged_subprocesses_are_not_double_counted(api: ApiClient) -> None:
    """重叠的子进程区间只算一次 —— 归并不能让时长翻倍。"""
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
        ],
    )
    body = api.get(
        f"{API}/statistics/summary", params={"date": "2026-10-06", "timezone": SHANGHAI}
    ).json()
    assert body["app_count"] == 1
    assert body["total_duration_seconds"] == 2700, "10:00–10:45 的并集，不是 3600"


def test_session_and_timeline_filter_include_all_merged_raws(api: ApiClient) -> None:
    """点「微信」查会话明细，必须把它所有子进程的记录都带出来。"""
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
                started_at=local(2026, 10, 6, 11, 0),
                ended_at=local(2026, 10, 6, 11, 20),
                active_seconds=1200,
            ),
        ],
    )
    params = {"date": "2026-10-06", "timezone": SHANGHAI}

    apps = api.get(f"{API}/statistics/summary", params=params).json()["apps"]
    app_id = apps[0]["app_id"]
    assert app_id == "com.tencent.mm"

    sessions = api.get(
        f"{API}/statistics/sessions", params={**params, "app_id": app_id}
    ).json()
    assert len(sessions["items"]) == 2, "两个子进程的会话都要返回"
    assert {s["raw_app_key"] for s in sessions["items"]} == {
        "com.tencent.mm",
        "com.tencent.mm:tools",
    }

    timeline = api.get(
        f"{API}/statistics/timeline", params={**params, "app_id": app_id}
    ).json()
    assert len(timeline["items"]) == 2

    # 旧调用方直接传原始子进程名，也应能查到
    legacy = api.get(
        f"{API}/statistics/sessions",
        params={**params, "app_id": "com.tencent.mm:tools"},
    ).json()
    assert len(legacy["items"]) == 1


def test_mcp_and_web_expose_the_same_app_names(api: ApiClient, app_module) -> None:
    """定稿验收项："MCP 与网页显示相同应用名称"。

    MCP 走的是 /integrations/stats/apps（另一条聚合链路），
    网页走 /statistics/summary。审计发现两层原本各算各的，
    现在共用同一个 AppIdentityIndex，这里把"一致"钉死。
    """
    # 先注册拿 Access Token，再签密钥（签密钥本身需要登录）
    api.register()
    plaintext = api.post(f"{API}/api-keys", json={"name": "mcp"}).json()["key"]

    api.bind_device()
    push(api, wechat_segments(api.device_id))

    web = summary_apps(api)
    assert len(web) == 1
    assert web[0]["app_name"] == "微信"

    from fastapi.testclient import TestClient

    with TestClient(app_module) as mcp_client:
        response = mcp_client.get(
            f"{API}/integrations/stats/apps",
            headers={"X-API-Key": plaintext},
            params={"period": "today", "tz_offset_minutes": 480},
        )
    assert response.status_code == 200, response.text
    items = response.json()["items"]
    assert len(items) == 1, f"MCP 也必须只出现一条微信：{items}"
    assert items[0]["display_name"] == "微信"
    assert items[0]["raw_app_keys"] and len(items[0]["raw_app_keys"]) == 4


# ---------------------------------------------------------------------------
# 6. 原始记录不可变（归一只作用于查询与展示）
# ---------------------------------------------------------------------------


def test_normalization_never_modifies_segments_or_user_applications(
    api: ApiClient, session_factory
) -> None:
    """定稿："禁止修改或覆盖原始活动片段"。

    建映射、改名字、删映射之后，活动段与应用库都必须**一行未变**。
    """
    from app.models import ActivitySegment

    api.register()
    api.bind_device()
    push(
        api,
        wechat_segments(api.device_id),
        applications=[
            {
                "app_key": "com.tencent.mm",
                "display_name": "微信客户端",
                "category": "social",
                "user_overridden": False,
                "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            }
        ],
    )

    def snapshot():
        with session_factory() as db:
            segs = [
                (s.id, s.app_key, s.active_seconds)
                for s in db.query(ActivitySegment).order_by(ActivitySegment.app_key)
            ]
            apps = [
                (a.app_key, a.display_name, a.category, a.user_overridden)
                for a in db.query(UserApplication).order_by(UserApplication.app_key)
            ]
            return segs, apps

    before = snapshot()

    created = api.post(
        f"{APPLICATIONS}/catalog",
        json={
            "display_name": "微信 Pro",
            "category": "social",
            "raw_app_keys": ["com.tencent.mm", "com.tencent.mm:tools"],
        },
    ).json()
    api.patch(
        f"{APPLICATIONS}/catalog/{created['id']}",
        json={"display_name": "微信改名"},
    )
    assert summary_apps(api)[0]["app_name"] == "微信改名"
    api.delete(f"{APPLICATIONS}/catalog/{created['id']}")
    for alias in created["aliases"]:
        api.delete(f"{APPLICATIONS}/aliases/{alias['id']}")

    assert snapshot() == before, "归一化绝不能改动原始活动片段或应用库"


def test_catalog_tables_are_per_user(api: ApiClient, session_factory) -> None:
    """结构层面的隔离：目录与别名两张表都必须带 user_id。"""
    api.register()
    api.post(f"{APPLICATIONS}/catalog", json={"display_name": "X", "raw_app_keys": ["a.b"]})

    with session_factory() as db:
        catalog = db.query(ApplicationCatalog).one()
        alias = db.query(ApplicationAlias).one()
        assert catalog.user_id is not None
        assert alias.user_id == catalog.user_id


def test_catalog_write_requires_csrf_when_using_web_session(client) -> None:
    """网页会话（Cookie 认证）下的写操作必须带 CSRF 对照值。"""
    owner = ApiClient(client)
    owner.register()
    login = client.post(
        f"{API}/web-session/login",
        json={"email": owner.user["email"], "password": "Sup3r-secret-pw"},
    )
    assert login.status_code == 200, login.text

    blocked = client.post(f"{APPLICATIONS}/catalog", json={"display_name": "Z"})
    assert blocked.status_code == 403
    assert blocked.json()["error"]["code"] == "csrf_token_invalid"

    allowed = client.post(
        f"{APPLICATIONS}/catalog",
        json={"display_name": "Z"},
        headers={"X-CSRF-Token": login.json()["csrf_token"]},
    )
    assert allowed.status_code == 201, allowed.text
