"""GameLog「生活足迹」网页会话：Cookie 装载 + CSRF 防护。

为什么需要这一层（而不是让网页直接用 ``/auth/login`` 拿 JSON Token）
------------------------------------------------------------------
``/auth/login`` 把 Access / Refresh Token **明文放在响应体**里，客户端（Windows /
Android）会安全地存进系统钥匙串。但网页没有等价的安全存储：
放到 ``localStorage`` 就等于暴露给任何一次 XSS，且 js 能读的 Token 一定能被读走。

因此本模块只做一件事：把同一套令牌**塞进 HttpOnly Cookie**，
让浏览器自己保管、JS 永远拿不到明文。令牌的签发 / 轮换 / 吊销逻辑
**完全复用** ``auth_service``（同一张 ``refresh_tokens`` 表），
所以"客户端与网页看到的数据一致""注销一处即全局失效"都是结构保证。

三个 Cookie 的分工
------------------
=================  ==========  =========================  ==================================
Cookie              HttpOnly     Path                       用途
=================  ==========  =========================  ==================================
``pl_web_at``       ✅          ``/petlife-api/``           Access Token（JWT），统计读取鉴权
``pl_web_rt``       ✅          ``/petlife-api/``           Refresh Token，静默续期
``pl_web_csrf``     ❌          ``/``                       Double-submit CSRF 对照值
=================  ==========  =========================  ==================================

CSRF Cookie 为什么单独放 ``Path=/``
----------------------------------
``document.cookie`` **只暴露路径匹配当前文档**的 Cookie。页面在 ``/usage/``，
若 CSRF Cookie 也设成 ``/petlife-api/``，页面 JS 就读不到它，Double-submit 直接失效。
它本身不是机密（随机串，只用于"证明请求来自同源脚本"），因此放宽路径是安全的；
两个**真正的凭据** Cookie 仍然严格限制在 ``/petlife-api/`` 下。
"""

from __future__ import annotations

import secrets
from datetime import datetime

from fastapi import Request, Response

from ..core.config import Settings
from ..core.errors import ApiError, ErrorCode
from ..core.timeutil import utcnow

#: Access Token Cookie（HttpOnly）
ACCESS_COOKIE = "pl_web_at"
#: Refresh Token Cookie（HttpOnly）
REFRESH_COOKIE = "pl_web_rt"
#: CSRF 对照 Cookie（**故意**不是 HttpOnly，页面 JS 需要读它）
CSRF_COOKIE = "pl_web_csrf"

#: 凭据 Cookie 的路径：只在反向代理前缀下收发，其它路径（含 game.html、api.php）看不到。
#: 这只是**默认值**，实际以 ``Settings.web_session_cookie_path`` 为准 ——
#: 浏览器只回传路径匹配的 Cookie，而反向代理会剥掉前缀，所以它属于部署事实。
SESSION_COOKIE_PATH = "/petlife-api/"
#: CSRF Cookie 的路径：必须覆盖页面所在路径，否则 JS 读不到
CSRF_COOKIE_PATH = "/"

#: CSRF 对照值的请求头
CSRF_HEADER = "X-CSRF-Token"

#: CSRF 随机串长度（token_urlsafe 的熵字节数）
_CSRF_BYTES = 24

#: Lax 已能挡住跨站表单 POST；Double-submit 作为第二道防线
_SAME_SITE = "lax"


def issue_csrf_token() -> str:
    """生成一个新的 CSRF 对照值。"""
    return secrets.token_urlsafe(_CSRF_BYTES)


def _max_age(expires_at: datetime, *, now: datetime) -> int:
    """Cookie ``Max-Age``：至少 0，避免时钟漂移导致负数。"""
    return max(0, int((expires_at - now).total_seconds()))


def _write(
    response: Response,
    *,
    key: str,
    value: str,
    path: str,
    max_age: int,
    httponly: bool,
    settings: Settings,
) -> None:
    response.set_cookie(
        key=key,
        value=value,
        max_age=max_age,
        path=path,
        httponly=httponly,
        secure=bool(settings.web_session_cookie_secure),
        samesite=_SAME_SITE,
    )


def set_session_cookies(
    response: Response,
    *,
    access_token: str,
    access_expires_at: datetime,
    refresh_token: str,
    refresh_expires_at: datetime,
    csrf_token: str,
    settings: Settings,
    now: datetime | None = None,
) -> None:
    """把令牌对与 CSRF 对照值写进 Cookie。

    明文 Token **只出现在 Set-Cookie 头里**，响应体不包含它们——
    这是"浏览器 JS 不接触明文 Token"的实现方式。
    """
    moment = now or utcnow()
    session_path = settings.web_session_cookie_path
    _write(
        response,
        key=ACCESS_COOKIE,
        value=access_token,
        path=session_path,
        max_age=_max_age(access_expires_at, now=moment),
        httponly=True,
        settings=settings,
    )
    _write(
        response,
        key=REFRESH_COOKIE,
        value=refresh_token,
        path=session_path,
        max_age=_max_age(refresh_expires_at, now=moment),
        httponly=True,
        settings=settings,
    )
    _write(
        response,
        key=CSRF_COOKIE,
        value=csrf_token,
        path=CSRF_COOKIE_PATH,
        # CSRF 值需要被页面 JS 读出来放进请求头，因此不能 HttpOnly。
        # 它等同于"同源证明"，不是凭据；真正的凭据是上面两个 HttpOnly Cookie。
        max_age=_max_age(refresh_expires_at, now=moment),
        httponly=False,
        settings=settings,
    )


def clear_session_cookies(response: Response, *, settings: Settings) -> None:
    """清空三个 Cookie（``Max-Age=0``）。

    路径必须与写入时一致，否则浏览器会留下一个"删不掉的"同名 Cookie。
    """
    for key, path in (
        (ACCESS_COOKIE, settings.web_session_cookie_path),
        (REFRESH_COOKIE, settings.web_session_cookie_path),
        (CSRF_COOKIE, CSRF_COOKIE_PATH),
    ):
        response.delete_cookie(
            key=key,
            path=path,
            secure=bool(settings.web_session_cookie_secure),
            samesite=_SAME_SITE,
        )


def read_csrf_cookie(request: Request) -> str | None:
    value = request.cookies.get(CSRF_COOKIE)
    return value or None


def verify_csrf(request: Request, provided: str | None) -> None:
    """校验 Double-submit CSRF：Cookie 与请求头必须同时存在且一致。

    用固定时间比较，避免用比较耗时泄露字节信息。
    """
    cookie_value = read_csrf_cookie(request)
    supplied = (provided or "").strip()
    if not cookie_value or not supplied:
        raise ApiError(
            ErrorCode.csrf_token_invalid,
            f"缺少 CSRF 校验（需要在 {CSRF_HEADER} 头里带上 {CSRF_COOKIE} 的值）",
        )
    if not secrets.compare_digest(cookie_value, supplied):
        raise ApiError(ErrorCode.csrf_token_invalid, "CSRF 校验失败，请刷新页面后重试")


def read_access_cookie(request: Request) -> str | None:
    value = request.cookies.get(ACCESS_COOKIE)
    return value or None


def ensure_csrf_cookie(
    request: Request, response: Response, *, settings: Settings
) -> str:
    """保证 CSRF 对照值同时存在于 Cookie 与返回值里。

    为什么需要它：会话 Cookie 还在、但 CSRF Cookie 被单独清掉时，
    后续 refresh / logout 会因为"对照值缺失"而永远失败，用户只能手动清 Cookie。
    ``/web-session/me`` 每次都会走这里，把缺失的对照值补上。

    Cookie 与返回的字符串**必须是同一个值**，否则前端发出的 ``X-CSRF-Token``
    与 Cookie 里的值不一致，Double-submit 反而必然失败。
    """
    existing = read_csrf_cookie(request)
    if existing:
        return existing

    fresh = issue_csrf_token()
    _write(
        response,
        key=CSRF_COOKIE,
        value=fresh,
        path=CSRF_COOKIE_PATH,
        max_age=60 * 60 * 24 * 30,
        httponly=False,
        settings=settings,
    )
    return fresh


def read_refresh_cookie(request: Request) -> str | None:
    value = request.cookies.get(REFRESH_COOKIE)
    return value or None


__all__ = [
    "ACCESS_COOKIE",
    "CSRF_COOKIE",
    "CSRF_COOKIE_PATH",
    "CSRF_HEADER",
    "REFRESH_COOKIE",
    "SESSION_COOKIE_PATH",
    "clear_session_cookies",
    "ensure_csrf_cookie",
    "issue_csrf_token",
    "read_access_cookie",
    "read_csrf_cookie",
    "read_refresh_cookie",
    "set_session_cookies",
    "verify_csrf",
]
