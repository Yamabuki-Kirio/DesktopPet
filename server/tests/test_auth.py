"""账户与令牌：注册 / 登录 / 刷新轮换 / 注销 / 改密 / 删除 / 过期。"""

from __future__ import annotations

import uuid
from datetime import timedelta

from app.core.config import get_settings
from app.core.timeutil import utcnow
from app.security.tokens import create_access_token

from .conftest import API, DEFAULT_PASSWORD


def test_register_returns_tokens_and_profile(api):
    response = api.register(email="alice@example.com", display_name="Alice")
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["access_token"]
    assert body["refresh_token"]
    assert body["expires_in"] > 0
    assert body["refresh_expires_at"].endswith("Z")
    assert body["user"]["email"] == "alice@example.com"
    assert body["user"]["display_name"] == "Alice"
    assert body["user"]["status"] == "active"


def test_duplicate_email_is_rejected(api):
    api.register(email="dup@example.com")
    response = api.http.post(
        f"{API}/auth/register",
        json={
            "email": "dup@example.com",
            "password": DEFAULT_PASSWORD,
            "display_name": "另一个",
        },
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "email_taken"


def test_email_is_case_insensitive(api):
    api.register(email="MixedCase@Example.COM")
    response = api.http.post(
        f"{API}/auth/login",
        json={"email": "mixedcase@example.com", "password": DEFAULT_PASSWORD},
    )
    assert response.status_code == 200


def test_login_success(api):
    api.register(email="login@example.com")
    fresh = type(api)(api.http)
    response = fresh.login(email="login@example.com")
    assert response.status_code == 200
    assert fresh.access_token


def test_wrong_password_and_unknown_email_share_the_same_error(api):
    """登录不得泄露邮箱是否已注册：两种情况必须返回同一个错误码与文案。"""
    api.register(email="known@example.com")

    wrong_pw = api.http.post(
        f"{API}/auth/login",
        json={"email": "known@example.com", "password": "definitely-wrong"},
    )
    unknown = api.http.post(
        f"{API}/auth/login",
        json={"email": "nobody@example.com", "password": DEFAULT_PASSWORD},
    )

    assert wrong_pw.status_code == unknown.status_code == 401
    assert (
        wrong_pw.json()["error"]["code"]
        == unknown.json()["error"]["code"]
        == "invalid_credentials"
    )
    assert wrong_pw.json()["error"]["message"] == unknown.json()["error"]["message"]


def test_refresh_rotates_token_and_invalidates_previous(api):
    api.register(email="rotate@example.com")
    old_refresh = api.refresh_token

    first = api.http.post(f"{API}/auth/refresh", json={"refresh_token": old_refresh})
    assert first.status_code == 200, first.text
    new_refresh = first.json()["refresh_token"]
    assert new_refresh != old_refresh

    # 旧 token 已被轮换：再次使用属于复用 → 判定泄露并把该用户全部会话注销
    reuse = api.http.post(f"{API}/auth/refresh", json={"refresh_token": old_refresh})
    assert reuse.status_code == 401
    assert reuse.json()["error"]["code"] == "refresh_token_reused"

    # 全量注销后，连最新的 refresh token 也失效了
    after = api.http.post(f"{API}/auth/refresh", json={"refresh_token": new_refresh})
    assert after.status_code == 401
    assert after.json()["error"]["code"] in {"token_invalid", "refresh_token_reused"}


def test_refresh_with_unknown_token_is_rejected(api):
    response = api.http.post(
        f"{API}/auth/refresh", json={"refresh_token": "x" * 64}
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_invalid"


def test_logout_revokes_current_session_only(api):
    api.register(email="logout@example.com")
    other = api.http.post(
        f"{API}/auth/login",
        json={"email": "logout@example.com", "password": DEFAULT_PASSWORD},
    ).json()

    response = api.http.post(
        f"{API}/auth/logout", json={"refresh_token": api.refresh_token}
    )
    assert response.status_code == 200
    assert response.json()["revoked_sessions"] >= 1

    revoked = api.http.post(
        f"{API}/auth/refresh", json={"refresh_token": api.refresh_token}
    )
    assert revoked.status_code == 401
    # 另一个会话不受影响
    still_ok = api.http.post(
        f"{API}/auth/refresh", json={"refresh_token": other["refresh_token"]}
    )
    assert still_ok.status_code == 200


def test_logout_all_revokes_every_session(api):
    api.register(email="logoutall@example.com")
    sessions = [
        api.http.post(
            f"{API}/auth/login",
            json={"email": "logoutall@example.com", "password": DEFAULT_PASSWORD},
        ).json()
        for _ in range(2)
    ]

    response = api.post(f"{API}/auth/logout-all")
    assert response.status_code == 200
    assert response.json()["revoked_sessions"] >= 3

    for session in sessions:
        revoked = api.http.post(
            f"{API}/auth/refresh", json={"refresh_token": session["refresh_token"]}
        )
        assert revoked.status_code == 401


def test_change_password_invalidates_sessions_and_old_password(api):
    api.register(email="pwchange@example.com")

    wrong_current = api.post(
        f"{API}/me/password",
        json={"current_password": "nope-nope-nope", "new_password": "Brand-new-pw-1"},
    )
    assert wrong_current.status_code == 401

    ok = api.post(
        f"{API}/me/password",
        json={"current_password": DEFAULT_PASSWORD, "new_password": "Brand-new-pw-1"},
    )
    assert ok.status_code == 200
    assert ok.json()["revoked_sessions"] >= 1

    # 旧密码不能再登录
    old = api.http.post(
        f"{API}/auth/login",
        json={"email": "pwchange@example.com", "password": DEFAULT_PASSWORD},
    )
    assert old.status_code == 401
    # 新密码可以
    new = api.http.post(
        f"{API}/auth/login",
        json={"email": "pwchange@example.com", "password": "Brand-new-pw-1"},
    )
    assert new.status_code == 200
    # 改密前的 refresh token 已失效
    assert (
        api.http.post(
            f"{API}/auth/refresh", json={"refresh_token": api.refresh_token}
        ).status_code
        == 401
    )


def test_delete_account_blocks_login_and_releases_email(api):
    api.register(email="bye@example.com")
    delete_password = DEFAULT_PASSWORD

    response = api.delete(
        f"{API}/me",
        json={"current_password": delete_password, "new_password": delete_password},
    )
    assert response.status_code == 200

    login = api.http.post(
        f"{API}/auth/login",
        json={"email": "bye@example.com", "password": DEFAULT_PASSWORD},
    )
    assert login.status_code == 401

    # 已删除账户的 access token 也不能再用
    me = api.get(f"{API}/me")
    assert me.status_code == 401
    assert me.json()["error"]["code"] == "unauthorized"

    # 邮箱被释放（可以重新注册）
    again = api.http.post(
        f"{API}/auth/register",
        json={
            "email": "bye@example.com",
            "password": DEFAULT_PASSWORD,
            "display_name": "新主人",
        },
    )
    assert again.status_code == 201


def test_delete_account_requires_password(api):
    api.register(email="safedelete@example.com")
    response = api.delete(
        f"{API}/me",
        json={"current_password": "wrong-password", "new_password": "whatever-1"},
    )
    assert response.status_code == 401


def test_me_endpoints(api):
    api.register(email="me@example.com", display_name="原名")
    assert api.get(f"{API}/me").json()["display_name"] == "原名"

    updated = api.patch(f"{API}/me", json={"display_name": "改后名字"})
    assert updated.status_code == 200
    assert updated.json()["display_name"] == "改后名字"
    assert api.get(f"{API}/me").json()["display_name"] == "改后名字"


def test_missing_access_token_is_unauthorized(api):
    response = api.http.get(f"{API}/me")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


def test_garbage_access_token_is_invalid(api):
    response = api.http.get(
        f"{API}/me", headers={"Authorization": "Bearer not-a-jwt"}
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_invalid"


def test_expired_access_token_reports_token_expired(api):
    """过期与"签名错误"必须是不同错误码：客户端据此决定刷新还是重新登录。"""
    api.register(email="expired@example.com")
    settings = get_settings()
    expired = create_access_token(
        user_id=uuid.UUID(api.user["id"]),
        secret=settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
        ttl_minutes=-5,
        issuer=settings.jwt_issuer,
    )
    response = api.http.get(
        f"{API}/me", headers={"Authorization": f"Bearer {expired.token}"}
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_expired"


def test_access_token_of_deleted_user_is_rejected(api, session_factory):
    """令牌签名有效但账户已不存在时必须拒绝（防止"幽灵令牌"）。"""
    api.register(email="ghost@example.com")
    settings = get_settings()
    orphan = create_access_token(
        user_id=uuid.uuid4(),
        secret=settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
        ttl_minutes=15,
        issuer=settings.jwt_issuer,
    )
    response = api.http.get(
        f"{API}/me", headers={"Authorization": f"Bearer {orphan.token}"}
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


def test_weak_password_is_rejected(api):
    response = api.http.post(
        f"{API}/auth/register",
        json={"email": "weak@example.com", "password": "short", "display_name": "x"},
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_refresh_token_returns_rotated_pair_with_new_expiry(api):
    api.register(email="expiry@example.com")
    before = api.refresh_token
    response = api.http.post(f"{API}/auth/refresh", json={"refresh_token": before})
    body = response.json()
    assert response.status_code == 200
    assert body["refresh_expires_at"].endswith("Z")
    # 新的 access token 有效
    me = api.http.get(
        f"{API}/me", headers={"Authorization": f"Bearer {body['access_token']}"}
    )
    assert me.status_code == 200


def test_refresh_token_cannot_be_used_as_access_token(api):
    api.register(email="typmix@example.com")
    response = api.http.get(
        f"{API}/me", headers={"Authorization": f"Bearer {api.refresh_token}"}
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_invalid"


def test_expired_refresh_token_is_rejected(api, session_factory):
    """把库里的 refresh token 改成已过期，刷新应返回 token_expired。"""
    api.register(email="rtexpire@example.com")
    import uuid as _uuid

    from sqlalchemy import select

    from app.models import RefreshToken
    from app.security.tokens import hash_token

    with session_factory() as session:
        record = session.scalar(
            select(RefreshToken).where(
                RefreshToken.token_hash == hash_token(api.refresh_token)
            )
        )
        assert record is not None
        record.expires_at = utcnow() - timedelta(seconds=1)
        session.commit()

    response = api.http.post(
        f"{API}/auth/refresh", json={"refresh_token": api.refresh_token}
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_expired"
    assert _uuid  # 保持导入被使用
