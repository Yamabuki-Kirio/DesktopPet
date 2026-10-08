"""GameLog「生活足迹」网页会话接口（契约见 docs/43 第六节）。

```
POST   /api/v1/web-session/login
POST   /api/v1/web-session/refresh
POST   /api/v1/web-session/logout
GET    /api/v1/web-session/me
```

为什么不能复用 ``/auth/login``
------------------------------
``/auth/login`` 的响应体里有明文 Access / Refresh Token，Windows 与 Android
客户端会把它们存进系统钥匙串；而网页**没有**等价的存储——放进 ``localStorage``
等于交给任何一次 XSS。因此这里额外提供一组"只发 Cookie"的端点：

* 令牌的签发 / 轮换 / 复用检测 / 吊销**全部复用** ``auth_service``
  （同一张 ``refresh_tokens`` 表），所以不存在第二套认证逻辑；
* 原有 ``/auth/*`` 契约与行为**完全不变**（回归测试 ``test_auth.py`` 覆盖）；
* 网页会话与 GameLog 管理密钥是两套身份：管理密钥走 ``api.php`` 的 PHP session，
  它**读不到**这里的任何数据（docs/43 第八节）。
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy.orm import Session

from ...core.config import Settings, get_settings
from ...core.errors import ApiError, ErrorCode
from ...core.logger import get_logger
from ...database.session import get_db
from ...schemas.auth import MessageOut, UserOut
from ...schemas.common import to_iso
from ...schemas.web_session import WebSessionLoginRequest, WebSessionOut
from ...security import web_session
from ...security.deps import CurrentWebUser, WebCsrf
from ...services import auth_service

router = APIRouter(tags=["web-session"])
logger = get_logger(__name__)


def _state(user, bundle, csrf_token: str) -> WebSessionOut:
    """统一的会话状态响应（令牌不进响应体）。"""
    return WebSessionOut(
        user=UserOut.from_model(user),
        csrf_token=csrf_token,
        access_expires_at=to_iso(bundle.access_expires_at),
    )


def _apply_cookies(
    response: Response, *, bundle, csrf_token: str, settings: Settings
) -> None:
    web_session.set_session_cookies(
        response,
        access_token=bundle.access_token,
        access_expires_at=bundle.access_expires_at,
        refresh_token=bundle.refresh_token,
        refresh_expires_at=bundle.refresh_expires_at,
        csrf_token=csrf_token,
        settings=settings,
    )


@router.post("/web-session/login", response_model=WebSessionOut)
async def web_login(
    payload: WebSessionLoginRequest,
    response: Response,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
):
    """邮箱 + 密码登录，令牌只下发到 HttpOnly Cookie。

    登录本身无需 CSRF 校验：此时还没有会话可被冒用，
    而"跨站冒用别人的密码登录"不构成攻击（攻击者拿不到凭据）。
    """
    user = auth_service.authenticate(db, email=payload.email, password=payload.password)
    bundle = auth_service.create_session(
        db,
        user=user,
        settings=settings,
        # 网页是长驻标签页，用配置里的网页专用 TTL（默认 30 分钟）
        access_ttl_minutes=settings.web_session_access_ttl_minutes,
    )
    csrf = web_session.issue_csrf_token()
    _apply_cookies(response, bundle=bundle, csrf_token=csrf, settings=settings)
    logger.info("网页会话建立 user_id=%s", user.id)
    return _state(user, bundle, csrf)


@router.post("/web-session/refresh", response_model=WebSessionOut)
async def web_refresh(
    request: Request,
    response: Response,
    _csrf: WebCsrf,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
):
    """用 Refresh Cookie 静默续期（轮换 + 复用检测沿用 ``auth_service``）。

    失败时（cookie 缺失 / 已轮换 / 已吊销 / 已过期）直接返回 401 系错误码，
    前端据此弹出登录卡。**不在这里清 Cookie**：异常路径无法携带响应头，
    清理由前端的 ``logout`` 调用完成（``logout`` 不要求会话有效）。
    """
    raw = web_session.read_refresh_cookie(request)
    if not raw:
        raise ApiError(ErrorCode.web_session_expired, "网页会话已过期，请重新登录")

    user, bundle, _device = auth_service.refresh_session(
        db,
        raw_refresh_token=raw,
        settings=settings,
        access_ttl_minutes=settings.web_session_access_ttl_minutes,
    )
    csrf = web_session.issue_csrf_token()
    _apply_cookies(response, bundle=bundle, csrf_token=csrf, settings=settings)
    return _state(user, bundle, csrf)


@router.post("/web-session/logout", response_model=MessageOut)
async def web_logout(
    request: Request,
    response: Response,
    _csrf: WebCsrf,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
):
    """退出登录：吊销当前 Refresh 链 + 清空三个 Cookie。

    **刻意不要求会话有效**：Access Token 已过期时用户仍然需要能"退出"，
    否则会卡在"既进不去也退不出"。CSRF 校验仍在（防止跨站强制登出）。
    """
    raw = web_session.read_refresh_cookie(request)
    revoked = (
        auth_service.revoke_by_token(db, raw_refresh_token=raw) if raw else 0
    )
    web_session.clear_session_cookies(response, settings=settings)
    logger.info("网页会话注销 revoked=%s", revoked)
    return MessageOut(message="已退出登录", revoked_sessions=revoked)


@router.get("/web-session/me", response_model=WebSessionOut)
async def web_me(
    request: Request,
    response: Response,
    user: CurrentWebUser,
    settings: Annotated[Settings, Depends(get_settings)],
):
    """读取当前会话。前端每次加载页面先调它：拿到了就有会话，401 就弹登录卡。

    顺带补发缺失的 CSRF Cookie（见 ``web_session.ensure_csrf_cookie``）。
    """
    csrf = web_session.ensure_csrf_cookie(request, response, settings=settings)
    return WebSessionOut(
        user=UserOut.from_model(user), csrf_token=csrf, access_expires_at=None
    )


__all__ = ["router"]
