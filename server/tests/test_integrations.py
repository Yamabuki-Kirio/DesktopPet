"""Phase 3：Telegram 绑定接口测试。

覆盖需求「九、测试要求 9.1」中与**绑定**相关的部分：

* 绑定码生成 / 归一化 / 过期 / 重复使用 / 错误码；
* Telegram 用户重复绑定（跨账户冲突、同账户幂等）；
* 解绑（含越权解绑与"解绑后可重绑"）；
* 用户之间严格隔离；
* 集成服务令牌错误 / 未配置；
* 绑定码明文不落库；
* 请求体不接受 ``user_id``（结构上无法指定任意用户）。
"""

from __future__ import annotations

import uuid
from datetime import timedelta

import pytest

from app.core.config import Settings
from app.core.errors import ApiError, ErrorCode
from app.core.timeutil import utcnow
from app.security.deps import INTEGRATION_TOKEN_HEADER, require_integration_service
from app.services import integration_service

from .conftest import API, INTEGRATION_TOKEN

LINK_CODE_PATH = f"{API}/integrations/telegram/link-code"
BINDINGS_PATH = f"{API}/integrations/telegram/bindings"
CONSUME_PATH = f"{API}/integrations/telegram/consume-link-code"
CONTEXT_PATH = f"{API}/integrations/telegram/context"


# --- 助手 -------------------------------------------------------------------


def _integration_headers(token: str | None) -> dict[str, str]:
    return {} if token is None else {INTEGRATION_TOKEN_HEADER: token}


def consume_code(
    client,
    *,
    code: str,
    telegram_user_id: int,
    telegram_chat_id: int | None = None,
    token: str | None = INTEGRATION_TOKEN,
    extra: dict | None = None,
):
    body = {
        "code": code,
        "telegram_user_id": telegram_user_id,
        "telegram_chat_id": telegram_chat_id or telegram_user_id,
    }
    if extra:
        body.update(extra)
    return client.post(
        CONSUME_PATH, headers=_integration_headers(token), json=body
    )


def fetch_context(
    client,
    *,
    telegram_user_id: int,
    token: str | None = INTEGRATION_TOKEN,
    params: dict | None = None,
):
    query = {"telegram_user_id": telegram_user_id}
    if params:
        query.update(params)
    return client.get(CONTEXT_PATH, headers=_integration_headers(token), params=query)


def error_code(response) -> str:
    return response.json()["error"]["code"]


def expire_code(session_factory, code: str) -> None:
    """把库里的绑定码改成已过期（不依赖真实时钟等待）。"""
    digest = integration_service.hash_link_code(
        integration_service.normalize_link_code(code)
    )
    with session_factory() as session:
        record = (
            session.query(integration_service.IntegrationLinkCode)
            .filter(integration_service.IntegrationLinkCode.code_hash == digest)
            .one()
        )
        record.expires_at = utcnow() - timedelta(seconds=1)
        session.commit()


# --- 绑定码生成 -------------------------------------------------------------


def test_link_code_requires_login(client):
    response = client.post(LINK_CODE_PATH)
    assert response.status_code == 401, response.text


def test_issue_link_code_returns_usable_code_once(api, session_factory):
    api.register()
    response = api.post(LINK_CODE_PATH)
    assert response.status_code == 201, response.text

    body = response.json()
    assert body["ttl_seconds"] > 0
    assert body["expires_at"].endswith("Z")
    assert body["telegram_command"] == f"/bind {body['code']}"

    normalized = integration_service.normalize_link_code(body["code"])
    assert len(normalized) == 8
    assert body["code"].isupper()

    # 库里只有哈希，没有明文
    with session_factory() as session:
        rows = session.query(integration_service.IntegrationLinkCode).all()
        assert len(rows) == 1
        assert rows[0].code_hash == integration_service.hash_link_code(normalized)
        assert normalized not in rows[0].code_hash
        assert rows[0].consumed_at is None


def test_issue_link_code_invalidates_previous_code(api, client):
    api.register()
    first = api.post(LINK_CODE_PATH).json()["code"]
    second = api.post(LINK_CODE_PATH).json()["code"]
    assert first != second

    # 旧码已被作废
    old = consume_code(client, code=first, telegram_user_id=9001)
    assert old.status_code == 409, old.text
    assert error_code(old) == ErrorCode.link_code_consumed

    fresh = consume_code(client, code=second, telegram_user_id=9001)
    assert fresh.status_code == 200, fresh.text


def test_link_code_plaintext_is_not_written_to_database(api, session_factory, tmp_path):
    """明文码不得出现在库文件里（库里只应有 SHA-256 哈希）。"""
    api.register()
    code = api.post(LINK_CODE_PATH).json()["code"]

    db_path = None
    for candidate in tmp_path.glob("*.db"):
        db_path = candidate
    assert db_path is not None

    raw = db_path.read_bytes()
    for needle in (code.encode(), code.replace("-", "").encode()):
        assert needle not in raw, "绑定码明文被写进了数据库文件"


# --- 消费绑定码 -------------------------------------------------------------


def test_consume_with_wrong_code_is_rejected(client):
    response = consume_code(client, code="ZZZZ-9999", telegram_user_id=9100)
    assert response.status_code == 400, response.text
    assert error_code(response) == ErrorCode.link_code_invalid


def test_consume_accepts_lowercase_and_missing_dash(api, client):
    api.register()
    code = api.post(LINK_CODE_PATH).json()["code"]
    normalized = integration_service.normalize_link_code(code)

    # 用户可能发小写、也可能漏掉连字符
    response = consume_code(client, code=normalized.lower(), telegram_user_id=9200)
    assert response.status_code == 200, response.text
    assert response.json()["bound"] is True


def test_consume_expired_code_is_rejected(api, client, session_factory):
    api.register()
    code = api.post(LINK_CODE_PATH).json()["code"]
    expire_code(session_factory, code)

    response = consume_code(client, code=code, telegram_user_id=9300)
    assert response.status_code == 400, response.text
    assert error_code(response) == ErrorCode.link_code_expired


def test_consume_same_code_twice_is_rejected(api, client):
    api.register()
    code = api.post(LINK_CODE_PATH).json()["code"]

    first = consume_code(client, code=code, telegram_user_id=9400)
    assert first.status_code == 200, first.text

    second = consume_code(client, code=code, telegram_user_id=9401)
    assert second.status_code == 409, second.text
    assert error_code(second) == ErrorCode.link_code_consumed


def test_consume_rejects_unknown_body_field(api, client):
    """请求体不接受 ``user_id`` —— 结构上就无法指定"绑定到哪个账户"。"""
    api.register()
    code = api.post(LINK_CODE_PATH).json()["code"]

    response = consume_code(
        client,
        code=code,
        telegram_user_id=9500,
        extra={"user_id": str(uuid.uuid4())},
    )
    assert response.status_code == 422, response.text


def test_telegram_account_cannot_bind_to_second_account(api, client):
    """一个有效的 Telegram 账号只能绑一个 PetLife 用户。"""
    api.register()
    code_a = api.post(LINK_CODE_PATH).json()["code"]
    assert consume_code(client, code=code_a, telegram_user_id=9600).status_code == 200

    other = type(api)(client)
    other.register()
    code_b = other.post(LINK_CODE_PATH).json()["code"]

    conflict = consume_code(client, code=code_b, telegram_user_id=9600)
    assert conflict.status_code == 409, conflict.text
    assert error_code(conflict) == ErrorCode.telegram_already_bound


def test_rebinding_same_account_is_idempotent(api, client):
    api.register()
    code_1 = api.post(LINK_CODE_PATH).json()["code"]
    assert consume_code(client, code=code_1, telegram_user_id=9700).status_code == 200

    # 同一账户再发一个码，同一 Telegram 账号再绑一次
    code_2 = api.post(LINK_CODE_PATH).json()["code"]
    again = consume_code(client, code=code_2, telegram_user_id=9700)
    assert again.status_code == 200, again.text
    assert again.json()["already_bound"] is True

    listings = api.get(BINDINGS_PATH).json()
    assert listings["total"] == 1, "重复绑定不应产生第二条记录"


# --- 绑定列表与解绑 ---------------------------------------------------------


def test_bindings_list_and_revoke(api, client):
    api.register()
    code = api.post(LINK_CODE_PATH).json()["code"]
    consume_code(client, code=code, telegram_user_id=9800)

    listings = api.get(BINDINGS_PATH).json()
    assert listings["total"] == 1
    binding = listings["items"][0]
    assert binding["telegram_user_id"] == 9800
    assert binding["is_active"] is True

    revoked = api.delete(f"{BINDINGS_PATH}/{binding['id']}")
    assert revoked.status_code == 200, revoked.text
    assert revoked.json()["is_active"] is False
    assert revoked.json()["revoked_at"] is not None

    # 幂等：再解绑一次也没问题
    assert api.delete(f"{BINDINGS_PATH}/{binding['id']}").status_code == 200


def test_revoke_is_scoped_to_owner(api, client):
    api.register()
    code = api.post(LINK_CODE_PATH).json()["code"]
    consume_code(client, code=code, telegram_user_id=9900)
    binding_id = api.get(BINDINGS_PATH).json()["items"][0]["id"]

    intruder = type(api)(client)
    intruder.register()
    response = intruder.delete(f"{BINDINGS_PATH}/{binding_id}")
    assert response.status_code == 404, response.text
    assert error_code(response) == ErrorCode.binding_not_found

    # 原账户的绑定没被解掉
    assert api.get(BINDINGS_PATH).json()["items"][0]["is_active"] is True


def test_revoke_then_rebind_to_another_account(api, client):
    api.register()
    code_a = api.post(LINK_CODE_PATH).json()["code"]
    consume_code(client, code=code_a, telegram_user_id=9950)
    binding_id = api.get(BINDINGS_PATH).json()["items"][0]["id"]
    api.delete(f"{BINDINGS_PATH}/{binding_id}")

    other = type(api)(client)
    other.register()
    code_b = other.post(LINK_CODE_PATH).json()["code"]
    rebound = consume_code(client, code=code_b, telegram_user_id=9950)
    assert rebound.status_code == 200, rebound.text
    assert rebound.json()["already_bound"] is False


def test_unbinding_immediately_removes_access(api, client, session_factory):
    """解绑后立即失去访问权限。"""
    api.register()
    code = api.post(LINK_CODE_PATH).json()["code"]
    consume_code(client, code=code, telegram_user_id=9960)
    assert fetch_context(client, telegram_user_id=9960).json()["bound"] is True

    binding_id = api.get(BINDINGS_PATH).json()["items"][0]["id"]
    api.delete(f"{BINDINGS_PATH}/{binding_id}")

    assert fetch_context(client, telegram_user_id=9960).json()["bound"] is False
    with session_factory() as session:
        assert (
            integration_service.resolve_active_user(
                session, telegram_user_id=9960
            )
            is None
        )


# --- 上下文接口 -------------------------------------------------------------


def test_context_for_unbound_telegram_user(client):
    body = fetch_context(client, telegram_user_id=12345).json()
    assert body["bound"] is False
    assert body["display_name"] is None


def test_context_ignores_injected_user_id_and_stays_scoped(api, client):
    """即使调用方塞一个别人的 user_id，也只返回自己绑定关系对应的账户。"""
    api.register(display_name="账户A")
    code = api.post(LINK_CODE_PATH).json()["code"]
    consume_code(client, code=code, telegram_user_id=9970)

    victim = type(api)(client)
    victim.register(display_name="受害者")
    victim_user_id = victim.user["id"]

    body = fetch_context(
        client, telegram_user_id=9970, params={"user_id": victim_user_id}
    ).json()
    assert body["bound"] is True
    assert body["display_name"] == "账户A"
    assert body["device_count"] == 1
    assert "user_id" not in body, "上下文不应回传内部 user_id"


def test_context_is_isolated_between_telegram_users(api, client):
    api.register(display_name="账户A")
    code_a = api.post(LINK_CODE_PATH).json()["code"]
    consume_code(client, code=code_a, telegram_user_id=9981)

    other = type(api)(client)
    other.register(display_name="账户B")
    code_b = other.post(LINK_CODE_PATH).json()["code"]
    consume_code(client, code=code_b, telegram_user_id=9982)

    assert fetch_context(client, telegram_user_id=9981).json()["display_name"] == "账户A"
    assert fetch_context(client, telegram_user_id=9982).json()["display_name"] == "账户B"
    assert fetch_context(client, telegram_user_id=9999).json()["bound"] is False


# --- 集成服务令牌 -----------------------------------------------------------


def test_integration_endpoints_reject_missing_token(client):
    assert (
        consume_code(client, code="ABCD-1234", telegram_user_id=1, token=None).status_code
        == 401
    )
    assert fetch_context(client, telegram_user_id=1, token=None).status_code == 401


def test_integration_endpoints_reject_wrong_token(client):
    expire = consume_code(
        client, code="ABCD-1234", telegram_user_id=1, token="not-the-token"
    )
    assert expire.status_code == 401, expire.text
    assert error_code(expire) == ErrorCode.integration_token_invalid
    assert fetch_context(client, telegram_user_id=1, token="not-the-token").status_code == 401


def test_user_token_cannot_call_integration_endpoints(api, client):
    """用户 Access Token 不能当集成令牌用（两套身份严格分开）。"""
    api.register()
    # 带上用户的 Bearer 也不行：集成接口只看集成令牌头
    response = client.post(
        CONSUME_PATH,
        headers={"Authorization": f"Bearer {api.access_token}"},
        json={"code": "ABCD-1234", "telegram_user_id": 1, "telegram_chat_id": 1},
    )
    assert response.status_code == 401, response.text


def test_dependency_rejects_when_integration_token_not_configured():
    """服务端没配置集成令牌时一律拒绝，而不是"无鉴权放行"。"""
    settings = Settings(jwt_secret="unit-test-secret-0123456789", integration_token="")
    with pytest.raises(ApiError) as excinfo:
        require_integration_service(settings=settings, token="anything")
    assert excinfo.value.code == ErrorCode.integration_token_invalid


def test_link_code_hash_is_stable_and_normalized():
    """哈希只依赖归一化结果，因此大小写/连字符差异不影响绑定。"""
    assert integration_service.normalize_link_code("abcd-1234") == "ABCD1234"
    assert integration_service.normalize_link_code(" ABCD 1234 ") == "ABCD1234"
    assert integration_service.hash_link_code("ABCD1234") == integration_service.hash_link_code(
        integration_service.normalize_link_code("abcd1234")
    )
    assert len(integration_service.hash_link_code("ABCD1234")) == 64
