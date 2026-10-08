"""Phase 3（改版）：个人访问密钥的生成 / 查看 / 撤销 / 鉴权。

覆盖的关键结论：

* 明文只返回一次，库里只有 SHA-256 哈希（连数据库文件里都搜不到明文）；
* 权限固定为只读统计，越界 scope 一律拒绝；
* 撤销立即生效且幂等；越权撤销别人的密钥只得到 404；
* **由密钥确定用户**：密钥之间严格隔离，调用方无法指定 ``user_id``。
"""

from __future__ import annotations

import uuid

from app.models import ALLOWED_SCOPES, API_KEY_PREFIX, SCOPE_STATS_READ, ApiKey, User, UserStatus
from app.security.deps import API_KEY_HEADER
from app.security.tokens import hash_token

from .conftest import API
from .test_integrations import error_code

KEYS_PATH = f"{API}/api-keys"
STATS_SUMMARY = f"{API}/integrations/stats/summary"


def key_headers(key: str | None) -> dict[str, str]:
    return {} if key is None else {API_KEY_HEADER: key}


def issue_key(api, *, name: str = "AstrBot", scopes: list[str] | None = None) -> dict:
    """在客户端（用户 Access Token）下生成一把密钥，返回创建响应体。"""
    body: dict = {"name": name}
    if scopes is not None:
        body["scopes"] = scopes
    response = api.post(KEYS_PATH, json=body)
    assert response.status_code == 201, response.text
    return response.json()


# --- 生成 -------------------------------------------------------------------


def test_create_requires_login(client):
    assert client.post(KEYS_PATH, json={"name": "x"}).status_code == 401


def test_create_returns_plaintext_once_and_stores_only_hash(api, session_factory):
    api.register()
    body = issue_key(api, name="家里的助手")

    assert body["key"].startswith(API_KEY_PREFIX)
    assert body["key_prefix"] == body["key"][:12]
    assert body["name"] == "家里的助手"
    assert body["scopes"] == [SCOPE_STATS_READ]
    assert body["is_active"] is True
    assert body["last_used_at"] is None
    assert body["revoked_at"] is None

    with session_factory() as session:
        rows = session.query(ApiKey).all()
        assert len(rows) == 1
        assert rows[0].key_hash == hash_token(body["key"])
        assert body["key"] not in rows[0].key_hash
        # 前缀只是明文的一小段，不足以还原密钥
        assert rows[0].key_prefix == body["key"][:12]
        assert len(body["key"]) > len(rows[0].key_prefix)


def test_plaintext_never_lands_in_database_file(api, tmp_path):
    """明文密钥不得出现在库文件里（只应有 SHA-256 十六进制）。"""
    api.register()
    key = issue_key(api)["key"]

    db_path = None
    for candidate in tmp_path.glob("*.db"):
        db_path = candidate
    assert db_path is not None

    assert key.encode() not in db_path.read_bytes(), "密钥明文被写进了数据库文件"


def test_create_rejects_unknown_scope(api):
    api.register()
    response = api.post(
        KEYS_PATH, json={"name": "x", "scopes": ["stats:write"]}
    )
    assert response.status_code == 422, response.text
    assert error_code(response) == "validation_error"


def test_create_rejects_blank_name(api):
    api.register()
    assert api.post(KEYS_PATH, json={"name": "   "}).status_code == 422
    assert api.post(KEYS_PATH, json={"name": "x" * 200}).status_code == 422


def test_create_rejects_unknown_body_field(api):
    """请求体里没有 ``user_id`` 这类字段——结构上无法"给别人建密钥"。"""
    api.register()
    response = api.post(
        KEYS_PATH, json={"name": "x", "user_id": str(uuid.uuid4())}
    )
    assert response.status_code == 422, response.text


def test_two_keys_are_distinct(api):
    api.register()
    first = issue_key(api)["key"]
    second = issue_key(api)["key"]
    assert first != second
    assert api.get(KEYS_PATH).json()["total"] == 2


# --- 列表 -------------------------------------------------------------------


def test_list_returns_only_prefix_and_metadata(api):
    api.register()
    created = issue_key(api)
    body = api.get(KEYS_PATH).json()

    assert body["total"] == 1
    item = body["items"][0]
    assert item["key_prefix"] == created["key_prefix"]
    assert set(item) == {
        "id",
        "name",
        "key_prefix",
        "scopes",
        "created_at",
        "last_used_at",
        "revoked_at",
        "is_active",
    }
    assert "key" not in item and "key_hash" not in item
    assert created["key"] not in str(body)


def test_list_is_scoped_to_owner(api, client):
    api.register()
    issue_key(api)

    other = type(api)(client)
    other.register()
    assert other.get(KEYS_PATH).json()["total"] == 0


# --- 撤销 -------------------------------------------------------------------


def test_revoke_marks_inactive_and_is_idempotent(api):
    api.register()
    created = issue_key(api)

    revoked = api.delete(f"{KEYS_PATH}/{created['id']}")
    assert revoked.status_code == 200, revoked.text
    assert revoked.json()["is_active"] is False
    assert revoked.json()["revoked_at"] is not None

    again = api.delete(f"{KEYS_PATH}/{created['id']}")
    assert again.status_code == 200, again.text
    assert again.json()["revoked_at"] == revoked.json()["revoked_at"]


def test_revoke_is_scoped_to_owner(api, client):
    api.register()
    created = issue_key(api)

    intruder = type(api)(client)
    intruder.register()
    response = intruder.delete(f"{KEYS_PATH}/{created['id']}")
    assert response.status_code == 404, response.text
    assert error_code(response) == "api_key_not_found"

    # 原账户的密钥仍然有效
    assert api.get(KEYS_PATH).json()["items"][0]["is_active"] is True


def test_revoke_unknown_key_is_not_found(api):
    api.register()
    response = api.delete(f"{KEYS_PATH}/{uuid.uuid4()}")
    assert response.status_code == 404, response.text


# --- 鉴权语义 ---------------------------------------------------------------


def test_stats_reject_missing_or_blank_key(client):
    assert client.get(STATS_SUMMARY).status_code == 401
    assert client.get(STATS_SUMMARY, headers=key_headers("")).status_code == 401
    assert client.get(STATS_SUMMARY, headers=key_headers("   ")).status_code == 401


def test_stats_reject_unknown_key(client):
    response = client.get(STATS_SUMMARY, headers=key_headers("plk_not-a-real-key"))
    assert response.status_code == 401, response.text
    assert error_code(response) == "api_key_invalid"


def test_stats_accept_valid_key_and_stamp_last_used(api, client):
    api.register()
    created = issue_key(api)
    assert api.get(KEYS_PATH).json()["items"][0]["last_used_at"] is None

    response = client.get(
        STATS_SUMMARY,
        headers=key_headers(created["key"]),
        params={"period": "today", "tz_offset_minutes": 0},
    )
    assert response.status_code == 200, response.text

    listed = api.get(KEYS_PATH).json()["items"][0]
    assert listed["last_used_at"] is not None, "成功鉴权应刷新 last_used_at"


def test_revoked_key_is_rejected_immediately(api, client):
    api.register()
    created = issue_key(api)
    assert client.get(STATS_SUMMARY, headers=key_headers(created["key"])).status_code == 200

    api.delete(f"{KEYS_PATH}/{created['id']}")

    response = client.get(STATS_SUMMARY, headers=key_headers(created["key"]))
    assert response.status_code == 401, response.text
    assert error_code(response) == "api_key_revoked"


def test_disabled_account_key_is_rejected(api, client, session_factory):
    api.register()
    created = issue_key(api)

    with session_factory() as session:
        user = session.get(User, uuid.UUID(api.user["id"]))
        user.status = UserStatus.disabled.value
        session.commit()

    response = client.get(STATS_SUMMARY, headers=key_headers(created["key"]))
    assert response.status_code == 403, response.text
    assert error_code(response) == "account_disabled"


def test_user_access_token_cannot_be_used_as_api_key(api, client):
    """Access Token 与个人访问密钥是两套身份，不能互相顶替。"""
    api.register()
    response = client.get(
        STATS_SUMMARY, headers={"Authorization": f"Bearer {api.access_token}"}
    )
    assert response.status_code == 401, response.text


def test_api_key_cannot_be_used_as_user_token(api, client):
    """反过来也不行：密钥不能拿来调需要登录的账户接口。"""
    api.register()
    created = issue_key(api)
    response = client.get(KEYS_PATH, headers=key_headers(created["key"]))
    assert response.status_code == 401, response.text


def test_scopes_constant_is_read_only():
    assert ALLOWED_SCOPES == frozenset({SCOPE_STATS_READ})
