"""Phase 3（改版）：集成统计接口测试（只读，密钥鉴权）。

重点验证四件事：

1. **身份只从密钥推导**：``X-API-Key`` → ``api_keys`` → 用户；
   调用方给不出也无法影响 PetLife ``user_id``，路径与查询串里都没有身份字段；
2. **数字与用户侧统计 API 完全一致**（同一套 ``stats_service``）；
3. **上限与截断**：单次返回不超过 ``integration_max_items``，并如实报告截断；
4. **撤销/停用后立即失权**。
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

from app.core.config import get_settings
from app.core.errors import ErrorCode
from app.models import User, UserStatus

from .conftest import API, make_app_record, make_daily, make_segment
from .test_api_keys import issue_key, key_headers
from .test_integrations import error_code

STATS = f"{API}/integrations/stats"
COMPARE_PATH = f"{API}/integrations/compare"
SYNC_STATUS_PATH = f"{API}/integrations/sync-status"


# --- 助手 -------------------------------------------------------------------


def _today_start() -> datetime:
    return datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)


def seed_usage(api) -> None:
    """灌入"今天 30 分钟 code + 昨天 10 分钟 chrome"，两个自然日都完整落在窗口内。

    刻意把段放在当天 00:00 起，避免"测试正好跑在午夜前后"造成的偶发失败。
    """
    device_id = api.device_id
    today = _today_start()
    yesterday = today - timedelta(days=1)

    segments = [
        make_segment(
            device_id=device_id,
            app_key="code",
            category="development",
            started_at=today,
            ended_at=today + timedelta(minutes=30),
            active_seconds=1800,
        ),
        make_segment(
            device_id=device_id,
            app_key="chrome",
            category="browser",
            started_at=yesterday,
            ended_at=yesterday + timedelta(minutes=10),
            active_seconds=600,
        ),
    ]
    daily = [
        make_daily(
            device_id=device_id,
            local_day=today.date().isoformat(),
            active_seconds=1800,
            idle_seconds=600,
        ),
        make_daily(
            device_id=device_id,
            local_day=yesterday.date().isoformat(),
            active_seconds=600,
            idle_seconds=300,
        ),
    ]
    apps = [
        make_app_record(app_key="code", display_name="VS Code", category="development"),
        make_app_record(app_key="chrome", display_name="Chrome", category="browser"),
    ]

    response = api.post(
        f"{API}/sync/push",
        json={"activity_segments": segments, "daily_usage": daily, "applications": apps},
    )
    assert response.status_code == 200, response.text
    # 2 段 + 2 天用量 + 2 个应用
    assert response.json()["accepted_total"] == 6


def seeded_account(api, *, name: str = "AI") -> str:
    """注册 + 灌数据 + 发一把密钥，返回密钥明文。"""
    api.register()
    seed_usage(api)
    return issue_key(api, name=name)["key"]


def fetch_stats(client, path: str, *, key: str | None, **params):
    query = {"tz_offset_minutes": 0, **params}
    return client.get(path, headers=key_headers(key), params=query)


# --- 鉴权 -------------------------------------------------------------------


def test_stats_endpoints_require_api_key(client):
    for path in (f"{STATS}/summary", f"{STATS}/apps", COMPARE_PATH, SYNC_STATUS_PATH):
        assert client.get(path).status_code == 401
        assert client.get(path, headers=key_headers("plk_wrong")).status_code == 401


def test_stats_reject_query_string_identity(client):
    """旧版靠 ``telegram_user_id`` 查询参数确定身份——现在这个入口不存在了。"""
    response = client.get(f"{STATS}/summary", params={"telegram_user_id": 424242})
    assert response.status_code == 401, "只带 telegram_user_id 不应通过鉴权"


def test_stats_work_with_valid_key(api, client):
    key = seeded_account(api)
    response = fetch_stats(client, f"{STATS}/summary", key=key, period="today")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["active_seconds"] == 1800
    assert body["app_active_seconds"] == 1800
    assert body["device_count"] == 1


def test_stats_are_identical_to_user_facing_api(api, client):
    """AI 看到的数字必须与 /api/v1/stats/* 一模一样（同一套统计服务）。"""
    key = seeded_account(api)

    for period in ("today", "yesterday", "7d", "30d"):
        user_side = api.get(
            f"{API}/stats/summary", params={"period": period, "tz_offset_minutes": 0}
        ).json()
        ai_side = fetch_stats(client, f"{STATS}/summary", key=key, period=period).json()
        for field in (
            "session_seconds",
            "active_seconds",
            "idle_seconds",
            "app_active_seconds",
            "device_count",
            "from_utc",
            "to_utc",
        ):
            assert user_side[field] == ai_side[field], f"{period}.{field} 不一致"


def test_stats_are_isolated_between_accounts(api, client):
    """密钥只读它所属账户的数据：别人的密钥看不到我的数据（反之亦然）。"""
    key = seeded_account(api)

    other = type(api)(client)
    other.register()  # 只注册，没有任何使用数据
    other_key = issue_key(other)["key"]

    mine = fetch_stats(client, f"{STATS}/summary", key=key, period="today").json()
    theirs = fetch_stats(client, f"{STATS}/summary", key=other_key, period="today").json()

    assert mine["active_seconds"] == 1800
    assert mine["device_count"] == 1
    assert theirs["active_seconds"] == 0
    # overview 的 device_count 口径是"窗口内有数据的设备数"，
    # 因此另一个账户虽然注册了设备，这里仍然是 0
    assert theirs["device_count"] == 0


def test_stats_ignore_injected_petlife_user_id(api, client):
    """即使调用方在查询串里塞一个别人的 PetLife user_id，也只返回自己账户的数据。"""
    key = seeded_account(api)

    victim = type(api)(client)
    victim.register(display_name="受害者")
    issue_key(victim)

    response = client.get(
        f"{STATS}/summary",
        headers=key_headers(key),
        params={
            "period": "today",
            "tz_offset_minutes": 0,
            "user_id": victim.user["id"],
        },
    )
    assert response.status_code == 200, response.text
    assert response.json()["active_seconds"] == 1800, "应当只看到自己账户的数据"


def test_stats_stop_working_after_key_revoked(api, client):
    api.register()
    seed_usage(api)
    created = issue_key(api)
    key = created["key"]

    assert fetch_stats(client, f"{STATS}/summary", key=key).status_code == 200

    api.delete(f"{API}/api-keys/{created['id']}")

    response = fetch_stats(client, f"{STATS}/summary", key=key)
    assert response.status_code == 401, response.text
    assert error_code(response) == ErrorCode.api_key_revoked


def test_stats_reject_disabled_account(api, client, session_factory):
    """账户被停用后，密钥必须立刻失效（不能继续读数据）。"""
    key = seeded_account(api)

    with session_factory() as session:
        user = session.get(User, uuid.UUID(api.user["id"]))
        user.status = UserStatus.disabled.value
        session.commit()

    response = fetch_stats(client, f"{STATS}/summary", key=key)
    assert response.status_code == 403, response.text
    assert error_code(response) == ErrorCode.account_disabled


# --- 应用 / 分类 / 设备 -----------------------------------------------------


def test_apps_ranking_and_limit(api, client):
    key = seeded_account(api)

    today = fetch_stats(client, f"{STATS}/apps", key=key, period="today").json()
    assert today["returned"] == 1
    assert today["truncated"] is False
    assert today["items"][0]["app_key"] == "code"
    assert today["items"][0]["active_seconds"] == 1800
    assert today["items"][0]["display_name"] == "VS Code"

    # 7 天窗口里两个应用都在，按使用时长倒序
    week = fetch_stats(client, f"{STATS}/apps", key=key, period="7d").json()
    assert [i["app_key"] for i in week["items"]] == ["code", "chrome"]

    # limit 只能收紧
    narrowed = fetch_stats(client, f"{STATS}/apps", key=key, period="7d", limit=1).json()
    assert narrowed["returned"] == 1
    assert narrowed["truncated"] is True


def test_apps_limit_cannot_exceed_server_cap(api, client):
    """请求一个比服务端上限更大的 limit 时，服务端按自己的上限截断。"""
    key = seeded_account(api)
    cap = get_settings().integration_max_items
    assert cap >= 1

    response = fetch_stats(client, f"{STATS}/apps", key=key, period="today", limit=200)
    assert response.status_code == 200, response.text
    assert response.json()["returned"] <= cap


def test_categories_and_devices(api, client):
    key = seeded_account(api)

    categories = fetch_stats(
        client, f"{STATS}/categories", key=key, period="today"
    ).json()
    assert categories["items"][0]["category"] == "development"
    assert categories["items"][0]["active_seconds"] == 1800
    assert categories["items"][0]["ratio_of_app_time"] == 1.0

    devices = fetch_stats(client, f"{STATS}/devices", key=key, period="today").json()
    assert devices["returned"] == 1
    assert devices["items"][0]["active_seconds"] == 1800
    assert "重叠" in devices["overlap_warning"], "必须显式提示多设备时间可能重叠"


# --- 时段对比 ---------------------------------------------------------------


def test_compare_today_vs_yesterday(api, client):
    key = seeded_account(api)

    body = fetch_stats(
        client, COMPARE_PATH, key=key, kind="today_vs_yesterday"
    ).json()

    assert body["current"]["active_seconds"] == 1800
    assert body["previous"]["active_seconds"] == 600
    assert body["active_seconds_delta"] == 1200
    assert body["active_seconds_change_ratio"] == 2.0
    assert body["app_active_seconds_delta"] == 1200
    assert body["has_data"] is True
    assert "自然日" in body["note"]


def test_compare_ratio_is_null_when_baseline_empty(api, client):
    """上一时段没有数据时不得编造百分比。"""
    api.register()
    device_id = api.device_id
    today = _today_start()
    response = api.post(
        f"{API}/sync/push",
        json={
            "activity_segments": [
                make_segment(
                    device_id=device_id,
                    started_at=today,
                    ended_at=today + timedelta(minutes=10),
                    active_seconds=600,
                )
            ],
            "daily_usage": [
                make_daily(
                    device_id=device_id,
                    local_day=today.date().isoformat(),
                    active_seconds=600,
                    idle_seconds=0,
                )
            ],
            "applications": [],
        },
    )
    assert response.status_code == 200, response.text
    key = issue_key(api)["key"]

    body = fetch_stats(
        client, COMPARE_PATH, key=key, kind="today_vs_yesterday"
    ).json()
    assert body["previous"]["active_seconds"] == 0
    assert body["active_seconds_change_ratio"] is None, "基线为 0 时必须是 null"
    assert body["app_active_seconds_change_ratio"] is None


def test_compare_week_and_last7_kinds(api, client):
    key = seeded_account(api)

    for kind in ("week_vs_last_week", "last7_vs_previous7"):
        body = fetch_stats(client, COMPARE_PATH, key=key, kind=kind).json()
        assert body["kind"] == kind
        assert body["current"]["label"]
        assert body["previous"]["label"]
        # 两侧窗口长度必须一致
        assert body["current"]["from_utc"] <= body["current"]["to_utc"]
        assert body["note"]

    week = fetch_stats(client, COMPARE_PATH, key=key, kind="week_vs_last_week").json()
    current_len = datetime.fromisoformat(
        week["current"]["to_utc"].replace("Z", "+00:00")
    ) - datetime.fromisoformat(week["current"]["from_utc"].replace("Z", "+00:00"))
    previous_len = datetime.fromisoformat(
        week["previous"]["to_utc"].replace("Z", "+00:00")
    ) - datetime.fromisoformat(week["previous"]["from_utc"].replace("Z", "+00:00"))
    assert current_len == previous_len, "本周与上周必须取相同时长"


def test_compare_rejects_unknown_kind(api, client):
    key = seeded_account(api)
    response = fetch_stats(client, COMPARE_PATH, key=key, kind="nonsense")
    assert response.status_code == 422, response.text


# --- 同步状态 ---------------------------------------------------------------


def test_sync_status_reports_fresh_data(api, client):
    key = seeded_account(api)

    body = fetch_stats(client, SYNC_STATUS_PATH, key=key).json()
    assert body["registered_device_count"] == 1
    assert body["data_may_be_stale"] is False
    assert body["last_data_received_at"] is not None
    assert body["last_activity_at"] is not None
    assert body["stale_after_minutes"] > 0


def test_sync_status_flags_missing_data(api, client):
    api.register()  # 只注册，没有任何使用数据
    key = issue_key(api)["key"]

    body = fetch_stats(client, SYNC_STATUS_PATH, key=key).json()
    assert body["data_may_be_stale"] is True
    assert body["last_data_received_at"] is None
    assert "还没有收到" in body["note"]


def test_sync_status_does_not_leak_tokens_or_errors(api, client):
    key = seeded_account(api)

    raw = fetch_stats(client, SYNC_STATUS_PATH, key=key).text
    for forbidden in ("access_token", "refresh_token", "token_hash", "password", "Traceback"):
        assert forbidden not in raw
    assert key not in raw, "响应里绝不能出现密钥明文"
