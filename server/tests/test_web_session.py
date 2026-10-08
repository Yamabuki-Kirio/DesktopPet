"""GameLog「生活足迹」网页会话测试（契约见 docs/43 第六节）。

覆盖四件事：

1. **凭据不外泄**：登录 / 续期 / 读会话的响应体里没有明文 Token；
   两个凭据 Cookie 是 HttpOnly 且限制在 ``/petlife-api/`` 下。
2. **真的能用**：只带 Cookie（无 ``Authorization`` 头）就能读统计接口。
3. **CSRF 有效**：写操作缺对照值即拒绝。
4. **不破坏原接口**：``/auth/login`` 仍然返回 JSON 令牌，客户端流程一字未改。
"""

from __future__ import annotations

import uuid
from datetime import timedelta

from fastapi import Response
from fastapi.testclient import TestClient

from app.core.config import Settings
from app.core.timeutil import utcnow
from app.security import web_session

from .conftest import API, DEFAULT_PASSWORD, ApiClient, make_segment

AT = web_session.ACCESS_COOKIE
RT = web_session.REFRESH_COOKIE
CSRF = web_session.CSRF_COOKIE
#: 生产默认的凭据 Cookie 路径（部署事实，见 Settings.web_session_cookie_path）
PRODUCTION_SESSION_PATH = web_session.SESSION_COOKIE_PATH
CSRF_HEADER = web_session.CSRF_HEADER

DAY = "2026-09-29"
SHANGHAI = "Asia/Shanghai"


def register_account(client) -> str:
    """注册一个账户，返回邮箱（注册走客户端链路，不带任何网页 Cookie）。"""
    owner = ApiClient(client)
    owner.register()
    return owner.user["email"]


def web_login(client, *, email: str, password: str = DEFAULT_PASSWORD):
    return client.post(
        f"{API}/web-session/login", json={"email": email, "password": password}
    )


def set_cookie_headers(response) -> list[str]:
    """取出全部 ``Set-Cookie`` 行。

    两种响应对象的取法不同：httpx（TestClient 返回）用 ``get_list``，
    starlette 的 ``Response`` 用 ``getlist``。这里统一兼容，
    这样同一个辅助函数既能断言真实响应，也能断言手工构造的 Response。
    """
    headers = response.headers
    getter = getattr(headers, "get_list", None) or headers.getlist
    return list(getter("set-cookie"))


def find_cookie(response, name: str) -> str:
    """从 Set-Cookie 头里取出某个 Cookie 的整行（区分大小写的前缀匹配）。"""
    for line in set_cookie_headers(response):
        if line.startswith(f"{name}="):
            return line
    raise AssertionError(f"响应里没有 {name} 的 Set-Cookie：{set_cookie_headers(response)}")


def cookie_value(response, name: str) -> str:
    line = find_cookie(response, name)
    return line.split(";", 1)[0].split("=", 1)[1]


def csrf_headers(token: str) -> dict[str, str]:
    return {CSRF_HEADER: token}


def drop_cookie(client, name: str) -> None:
    """按名字删掉客户端持有的某个 Cookie。

    必须用 Cookie 自身记录的 domain / path 去删：httpx 的 ``Cookies.delete``
    需要调用方自己提供正确的 domain，传错会直接 ``KeyError``。
    """
    jar = client.cookies.jar
    for cookie in list(jar):
        if cookie.name == name:
            jar.clear(cookie.domain, cookie.path, cookie.name)


# ---------------------------------------------------------------------------
# 1. 凭据不外泄
# ---------------------------------------------------------------------------


def test_web_login_sets_httponly_cookies_without_leaking_tokens(client) -> None:
    email = register_account(client)
    response = web_login(client, email=email)
    assert response.status_code == 200, response.text
    body = response.json()

    # 响应体只有会话状态，没有任何明文令牌
    assert set(body) == {"user", "csrf_token", "access_expires_at"}
    assert body["user"]["email"] == email
    assert body["csrf_token"]
    assert body["access_expires_at"]

    text = response.text
    assert "access_token" not in text, "网页会话不得把明文 Access Token 放进响应体"
    assert "refresh_token" not in text, "网页会话不得把明文 Refresh Token 放进响应体"

    # 三个 Cookie：凭据 HttpOnly，CSRF 非 HttpOnly
    assert len(set_cookie_headers(response)) == 3
    assert "HttpOnly" in find_cookie(response, AT)
    assert "HttpOnly" in find_cookie(response, RT)
    assert "HttpOnly" not in find_cookie(response, CSRF)

    # CSRF Cookie 必须覆盖页面所在路径，否则页面 JS 读不到它
    assert f"Path={web_session.CSRF_COOKIE_PATH}" in find_cookie(response, CSRF)

    # SameSite=Lax 三道 Cookie 一致
    for name in (AT, RT, CSRF):
        assert "SameSite=lax" in find_cookie(response, name), find_cookie(response, name)


def test_wrong_password_returns_error_and_sets_no_cookies(client) -> None:
    email = register_account(client)
    response = web_login(client, email=email, password="wrong-password-123")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_credentials"
    assert set_cookie_headers(response) == [], "登录失败不得下发任何 Cookie"


def test_unknown_email_is_indistinguishable_from_wrong_password(client) -> None:
    """登录不泄露"邮箱是否已注册"（与 /auth/login 同一口径）。"""
    register_account(client)
    response = web_login(client, email=f"nobody-{uuid.uuid4().hex[:8]}@example.com")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_credentials"


# ---------------------------------------------------------------------------
# 2. 真的能用：只靠 Cookie 读统计接口
# ---------------------------------------------------------------------------


def test_cookie_alone_is_enough_to_read_statistics(client) -> None:
    """核心验收：不带 Authorization 头，仅凭 HttpOnly Cookie 读今日汇总。"""
    owner = ApiClient(client)
    owner.register()
    owner.bind_device(name="我的电脑")
    push = owner.post(
        f"{API}/sync/push",
        json={
            "activity_segments": [
                make_segment(
                    device_id=owner.device_id,
                    app_key="code",
                    started_at=utcnow() - timedelta(hours=2),
                    ended_at=utcnow() - timedelta(hours=1),
                    active_seconds=3600,
                )
            ]
        },
    )
    assert push.status_code == 200, push.text

    login = web_login(client, email=owner.user["email"])
    assert login.status_code == 200, login.text

    # 只带 Cookie，不带 Authorization
    response = client.get(
        f"{API}/statistics/summary", params={"timezone": SHANGHAI}
    )
    assert response.status_code == 200, response.text
    assert response.json()["total_duration_seconds"] == 3600

    # 设备列表同样可用（裸数组形状）
    devices = client.get(f"{API}/devices")
    assert devices.status_code == 200
    assert isinstance(devices.json(), list)
    assert any(d["device_name"] == "我的电脑" for d in devices.json())


def test_cookie_alone_works_but_a_forged_token_does_not(client) -> None:
    """伪造的 Access Cookie 必须被拒（签名校验生效）。"""
    register_account(client)
    client.cookies.set(AT, "not-a-real-jwt")
    response = client.get(f"{API}/statistics/summary", params={"timezone": SHANGHAI})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_invalid"


def test_web_session_is_isolated_between_accounts(client) -> None:
    """账户隔离：网页会话读到的是自己的数据，看不到别人的。"""
    owner = ApiClient(client)
    owner.register()
    owner.bind_device()
    owner.post(
        f"{API}/sync/push",
        json={
            "activity_segments": [
                make_segment(
                    device_id=owner.device_id,
                    started_at=utcnow() - timedelta(hours=3),
                    ended_at=utcnow() - timedelta(hours=2),
                    active_seconds=3600,
                )
            ]
        },
    )

    # 另开一个干净客户端注册第二个账户并建立网页会话
    other = ApiClient(client)
    other.register()
    assert web_login(client, email=other.user["email"]).status_code == 200

    body = client.get(f"{API}/statistics/summary", params={"timezone": SHANGHAI}).json()
    assert body["total_duration_seconds"] == 0, "第二个账户不该看到第一个账户的时长"


def test_other_accounts_device_is_not_queryable_from_web_session(client) -> None:
    owner = ApiClient(client)
    owner.register()
    owner.bind_device()

    other = ApiClient(client)
    other.register()
    assert web_login(client, email=other.user["email"]).status_code == 200

    response = client.get(
        f"{API}/statistics/summary",
        params={"timezone": SHANGHAI, "device_id": owner.device_id},
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "device_not_found"


# ---------------------------------------------------------------------------
# 3. /me、续期与 CSRF
# ---------------------------------------------------------------------------


def test_me_returns_same_user_and_matching_csrf(client) -> None:
    email = register_account(client)
    login = web_login(client, email=email)
    assert login.status_code == 200

    me = client.get(f"{API}/web-session/me")
    assert me.status_code == 200, me.text
    body = me.json()
    assert body["user"]["email"] == email
    # /me 不返回到期时间（前端以"401 即续期"为准，不信任本地时钟）
    assert body["access_expires_at"] is None
    # 返回值必须与 Cookie 里的对照值一致，否则前端发出的头会校验失败
    assert body["csrf_token"] == cookie_value(login, CSRF)


def test_me_without_session_is_rejected_with_web_session_expired(client) -> None:
    register_account(client)
    response = client.get(f"{API}/web-session/me")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "web_session_expired"


def test_me_reissues_missing_csrf_cookie(client) -> None:
    """CSRF Cookie 被单独清掉时，/me 必须补发，否则用户会卡在"永远校验失败"。"""
    email = register_account(client)
    assert web_login(client, email=email).status_code == 200
    drop_cookie(client, CSRF)

    me = client.get(f"{API}/web-session/me")
    assert me.status_code == 200, me.text
    issued = cookie_value(me, CSRF)
    assert me.json()["csrf_token"] == issued, "补发的 Cookie 与返回值必须是同一个值"

    # 补发之后，写操作又能正常通过
    assert (
        client.post(
            f"{API}/web-session/logout", headers=csrf_headers(issued)
        ).status_code
        == 200
    )


def test_refresh_rotates_the_refresh_token(client) -> None:
    email = register_account(client)
    login = web_login(client, email=email)
    old_refresh = cookie_value(login, RT)

    refreshed = client.post(
        f"{API}/web-session/refresh",
        headers=csrf_headers(cookie_value(login, CSRF)),
    )
    assert refreshed.status_code == 200, refreshed.text
    new_refresh = cookie_value(refreshed, RT)
    assert new_refresh != old_refresh, "续期必须轮换 Refresh Token"
    assert refreshed.json()["user"]["email"] == email

    # 续期后媒体会话仍然可用
    assert client.get(f"{API}/web-session/me").status_code == 200


def test_reusing_a_rotated_refresh_token_is_detected(app_module, client) -> None:
    """已轮换过的 Refresh Token 再次出现 → 判定泄露，吊销该账户全部会话。"""
    email = register_account(client)
    login = web_login(client, email=email)
    old_refresh = cookie_value(login, RT)
    csrf = cookie_value(login, CSRF)

    first = client.post(f"{API}/web-session/refresh", headers=csrf_headers(csrf))
    assert first.status_code == 200
    rotated_refresh = cookie_value(first, RT)

    # 用一个只带"旧 Refresh Token"的干净客户端重放
    with TestClient(
        app_module, cookies={RT: old_refresh, CSRF: csrf}
    ) as replayer:
        replay = replayer.post(
            f"{API}/web-session/refresh", headers=csrf_headers(csrf)
        )
    assert replay.status_code == 401
    assert replay.json()["error"]["code"] == "refresh_token_reused"

    # 全量吊销的验证：连**刚刚轮换出来的新** Refresh Token 也必须失效。
    # （不校验 Access Cookie：JWT 无状态，在到期前仍有效，
    #   这是本服务既有的设计，故这里针对 Refresh 链断言。）
    with TestClient(
        app_module, cookies={RT: rotated_refresh, CSRF: csrf}
    ) as third:
        again = third.post(f"{API}/web-session/refresh", headers=csrf_headers(csrf))
    assert again.status_code == 401
    assert again.json()["error"]["code"] == "token_invalid", (
        "泄露判定后该账户的 refresh 链应全部失效"
    )


def test_refresh_without_csrf_is_rejected(client) -> None:
    email = register_account(client)
    assert web_login(client, email=email).status_code == 200
    response = client.post(f"{API}/web-session/refresh")
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "csrf_token_invalid"


def test_refresh_with_mismatched_csrf_is_rejected(client) -> None:
    email = register_account(client)
    assert web_login(client, email=email).status_code == 200
    response = client.post(
        f"{API}/web-session/refresh", headers=csrf_headers("not-the-cookie-value")
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "csrf_token_invalid"


def test_refresh_without_cookie_returns_web_session_expired(client) -> None:
    """Refresh Cookie 不在（但 CSRF 对照值还在）时给出"会话过期"而不是 CSRF 错误。

    这是浏览器上的真实场景：CSRF Cookie 在 ``Path=/`` 且有效期更长，
    Refresh Cookie 在 ``Path=/petlife-api/``，两者生命周期不一致。
    前端据 ``web_session_expired`` 弹登录卡，而不是报"CSRF 失败"。
    """
    register_account(client)
    client.cookies.set(CSRF, "csrf-only")
    response = client.post(
        f"{API}/web-session/refresh", headers=csrf_headers("csrf-only")
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "web_session_expired"


def test_refresh_without_any_cookie_is_rejected_by_csrf_first(client) -> None:
    """两个 Cookie 都不在时，先被 CSRF 拦下（403）。

    这里固化的是**校验顺序**：CSRF 在会话读取之前。它不影响真实用户
    （浏览器一定带着 CSRF Cookie），但顺序变化会让前端错误处理走错分支，
    所以用测试钉住。
    """
    register_account(client)
    response = client.post(f"{API}/web-session/refresh")
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "csrf_token_invalid"


# ---------------------------------------------------------------------------
# 4. 退出登录
# ---------------------------------------------------------------------------


def test_logout_requires_csrf(client) -> None:
    email = register_account(client)
    assert web_login(client, email=email).status_code == 200
    response = client.post(f"{API}/web-session/logout")
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "csrf_token_invalid"


def test_logout_clears_cookies_and_revokes_the_session(client) -> None:
    email = register_account(client)
    login = web_login(client, email=email)
    csrf = cookie_value(login, CSRF)

    response = client.post(f"{API}/web-session/logout", headers=csrf_headers(csrf))
    assert response.status_code == 200, response.text
    assert response.json()["revoked_sessions"] == 1

    # 三个 Cookie 都必须被清（Max-Age=0）
    for name in (AT, RT, CSRF):
        line = find_cookie(response, name)
        assert "Max-Age=0" in line, line

    client.cookies.clear()
    assert client.get(f"{API}/web-session/me").status_code == 401


def test_logout_works_even_after_access_token_is_gone(client) -> None:
    """Access Token 已失效时用户仍要能退出（否则进不去也退不出）。"""
    email = register_account(client)
    login = web_login(client, email=email)
    csrf = cookie_value(login, CSRF)

    # 单独删掉 Access Cookie，模拟"已过期"
    drop_cookie(client, AT)
    assert client.get(f"{API}/web-session/me").status_code == 401

    response = client.post(f"{API}/web-session/logout", headers=csrf_headers(csrf))
    assert response.status_code == 200, response.text


# ---------------------------------------------------------------------------
# 5. 不破坏既有接口 & 生产 Cookie 属性
# ---------------------------------------------------------------------------


def test_auth_login_still_returns_json_tokens(client) -> None:
    """原客户端流程一字未改：/auth/login 仍返回明文令牌与到期时间。"""
    email = register_account(client)
    response = client.post(
        f"{API}/auth/login", json={"email": email, "password": DEFAULT_PASSWORD}
    )
    assert response.status_code == 200, response.text
    body = response.json()
    for key in (
        "access_token",
        "refresh_token",
        "refresh_expires_at",
        "expires_in",
        "user",
    ):
        assert key in body, f"/auth/login 响应缺少 {key}"

    # 原接口不下发网页 Cookie
    assert not any(
        line.startswith(f"{AT}=") for line in set_cookie_headers(response)
    ), "/auth/login 不应下发网页会话 Cookie"


def test_statistics_still_requires_bearer_for_plain_clients(client) -> None:
    """没有 Cookie 也没有 Authorization 时，统计接口依然拒绝。"""
    register_account(client)
    response = client.get(f"{API}/statistics/summary", params={"timezone": SHANGHAI})
    assert response.status_code == 401


def test_production_cookie_attributes() -> None:
    """生产（默认配置）的三个 Cookie 属性必须齐全。

    特别是 ``Path``：它决定浏览器会不会把凭据带回来。写错（例如漏掉尾斜杠）
    时登录看起来成功、后续请求却全部未登录，属于最难排查的一类部署事故，
    所以这里把默认值钉死。
    """
    settings = Settings(
        web_session_cookie_secure=True, web_session_cookie_path="/petlife-api/"
    )
    # 字段默认值就是生产用的反代前缀（测试环境靠环境变量覆盖，不影响默认值）
    assert (
        Settings.model_fields["web_session_cookie_path"].default == PRODUCTION_SESSION_PATH
    )

    response = Response()
    web_session.set_session_cookies(
        response,
        access_token="at",
        access_expires_at=utcnow() + timedelta(minutes=30),
        refresh_token="rt",
        refresh_expires_at=utcnow() + timedelta(days=30),
        csrf_token="csrf",
        settings=settings,
    )
    headers = set_cookie_headers(response)
    assert len(headers) == 3
    for line in headers:
        assert "Secure" in line, f"生产环境缺少 Secure：{line}"
        assert "SameSite=lax" in line, line

    for name in (AT, RT):
        line = find_cookie(response, name)
        assert f"Path={PRODUCTION_SESSION_PATH}" in line, line
        assert "HttpOnly" in line, line
    csrf_line = find_cookie(response, CSRF)
    assert f"Path={web_session.CSRF_COOKIE_PATH}" in csrf_line, csrf_line
    assert "HttpOnly" not in csrf_line, "CSRF 对照值必须能被页面 JS 读到"


def test_cookie_path_is_normalized_to_avoid_silent_cookie_loss() -> None:
    """``Path`` 缺尾斜杠时会被规范化补上。

    RFC 6265 的路径匹配下 ``Path=/petlife-api`` **不匹配** ``/petlife-api/api/v1/...``，
    浏览器就不会回传凭据 —— 表现为"登录成功但一直未登录"。
    """

    def normalize(value: str) -> str:
        # model_fields 默认值不受测试环境变量影响，这里显式传入待规范化的值
        return Settings(web_session_cookie_path=value).web_session_cookie_path

    assert normalize("petlife-api") == "/petlife-api/"
    assert normalize("/petlife-api") == "/petlife-api/"
    assert normalize("/petlife-api/") == "/petlife-api/"
    assert normalize("/") == "/"


def test_clear_cookies_uses_the_same_path_as_writing() -> None:
    """清理时必须用与写入一致的 Path，否则会留下删不掉的名 Cookie。"""
    settings = Settings(web_session_cookie_path="/petlife-api/")
    response = Response()
    web_session.clear_session_cookies(response, settings=settings)
    headers = set_cookie_headers(response)
    assert len(headers) == 3
    for name in (AT, RT):
        line = find_cookie(response, name)
        assert f"Path={PRODUCTION_SESSION_PATH}" in line, line
        assert "Max-Age=0" in line, line
    assert f"Path={web_session.CSRF_COOKIE_PATH}" in find_cookie(response, CSRF)
