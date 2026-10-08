"""网页会话（GameLog「生活足迹」）schema。

设计要点：响应体里**没有** ``access_token`` / ``refresh_token`` 字段。
令牌只经 ``Set-Cookie`` 下发（HttpOnly），因此前端代码、前端日志、
浏览器 ``localStorage`` 都不会出现凭据——这是定稿第 7 条的硬要求。
"""

from __future__ import annotations

from pydantic import EmailStr, Field

from .auth import PASSWORD_MAX, UserOut
from .common import StrictModel


class WebSessionLoginRequest(StrictModel):
    """网页登录：邮箱 + 密码。

    **不接受 ``device``**：网页不是一台设备，不应污染设备列表与统计口径
    （定稿第 4 条要求设备粒度按 ``device_id`` 区分，凭空多一台"浏览器"会误导用户）。
    也**不接受** ``plk_`` 个人访问密钥——那属于 MCP 集成身份。
    """

    email: EmailStr
    password: str = Field(min_length=1, max_length=PASSWORD_MAX)


class WebSessionOut(StrictModel):
    """当前网页会话状态。"""

    user: UserOut
    #: Double-submit CSRF 对照值。前端把它放进 ``X-CSRF-Token`` 头。
    #: 它不是凭据：只证明"请求来自同源脚本"。
    csrf_token: str
    #: Access Token 到期时刻（UTC ISO8601）。仅在登录 / 续期时有值，
    #: ``/web-session/me`` 返回 null——前端以"401 即静默续期"为准，
    #: 不依赖本地时钟推算（本地时钟不可信）。
    access_expires_at: str | None = None


__all__ = ["WebSessionLoginRequest", "WebSessionOut"]
