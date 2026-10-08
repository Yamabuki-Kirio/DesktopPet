"""FastAPI 依赖：当前用户、当前设备、个人访问密钥、集成服务。"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, Header, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..core.config import Settings, get_settings
from ..core.errors import ApiError, ErrorCode
from ..core.timeutil import utcnow
from ..database.session import get_db
from ..models import ApiKey, Device, User, UserStatus
from ..services import api_key_service
from .tokens import decode_access_token
from .web_session import CSRF_HEADER, read_access_cookie, verify_csrf

# auto_error=False：缺头时由我们自己抛统一错误体，而不是 FastAPI 默认的 403。
bearer_scheme = HTTPBearer(auto_error=False, description="Access Token（Bearer）")

DEVICE_ID_HEADER = "X-Device-Id"

#: 集成服务（AstrBot）专用请求头，仅用于 Telegram 绑定流程
#: （``/integrations/telegram/**``）。它**不是**用户凭据，也不是数据读取凭据。
INTEGRATION_TOKEN_HEADER = "X-PetLife-Integration-Token"

#: 个人访问密钥请求头（MCP / AI 侧读取统计数据的唯一凭据）。
#: 明文形如 ``plk_...``；服务端只按 SHA-256 哈希比对，并**由密钥本身确定用户**，
#: 因此调用方无需（也无法）提交任何 ``user_id`` / Telegram ID。
API_KEY_HEADER = "X-API-Key"


def _user_from_access_token(
    db: Session, *, token: str, settings: Settings
) -> User:
    """从 Access Token 解析出用户（Bearer 与网页会话共用同一条路径）。

    两种身份载体（``Authorization: Bearer`` 头 / HttpOnly Cookie）只是**取得令牌的方式**
    不同，令牌本身的校验、账户状态判定必须完全一致，否则会出现
    「客户端被停用、网页还能读」这类口径漂移。
    """
    payload = decode_access_token(
        token,
        secret=settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
        issuer=settings.jwt_issuer,
    )

    raw_sub = payload.get("sub")
    try:
        user_id = uuid.UUID(str(raw_sub))
    except (ValueError, TypeError) as exc:
        raise ApiError(ErrorCode.token_invalid, "Access Token 无效") from exc

    user = db.get(User, user_id)
    if user is None:
        # 账户已被物理删除
        raise ApiError(ErrorCode.unauthorized, "账户不存在或已注销")
    if user.status == UserStatus.deleted.value:
        raise ApiError(ErrorCode.unauthorized, "账户已删除")
    if user.status == UserStatus.disabled.value:
        raise ApiError(ErrorCode.account_disabled, "账户已被停用")
    return user


def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> User:
    """校验 Access Token 并返回用户。"""
    if credentials is None or not credentials.credentials:
        raise ApiError(ErrorCode.unauthorized, "缺少 Authorization 头")

    return _user_from_access_token(
        db, token=credentials.credentials, settings=settings
    )


CurrentUser = Annotated[User, Depends(get_current_user)]


def get_current_web_user(
    request: Request,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> User:
    """网页会话：Access Token 从 HttpOnly Cookie 读取，**不认** Authorization 头。

    与 :func:`get_current_user` 的差别只有"令牌从哪来"：

    * 网页不能用 ``Authorization`` 头，因为那要求 JS 持有明文 Token；
    * 也**不能**因为带了 GameLog 管理密钥就放行——那套身份走 ``api.php`` 的 PHP
      session，与 PetLife 账户毫无关系（见 docs/43 第 6 节）。

    错误码用 ``web_session_expired``（而非 ``unauthorized``），
    前端据此决定"弹登录卡"而不是"报错提示"。
    """
    token = read_access_cookie(request)
    if not token:
        raise ApiError(ErrorCode.web_session_expired, "未登录或网页会话已过期")
    return _user_from_access_token(db, token=token, settings=settings)


CurrentWebUser = Annotated[User, Depends(get_current_web_user)]


def get_current_user_flexible(
    request: Request,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
    credentials: Annotated[
        HTTPAuthorizationCredentials | None, Depends(bearer_scheme)
    ] = None,
) -> User:
    """``Authorization: Bearer`` **或** 网页会话 Cookie，二者任一即可。

    用途：统计 / 设备这类**只读**接口需要同时服务两类调用方——
    Windows / Android 客户端（Bearer）与 GameLog「生活足迹」网页（HttpOnly Cookie）。
    两者最终走**同一个** :func:`_user_from_access_token`，因此权限判定、
    账户状态检查、数据范围完全一致，不存在"网页看到的数字和客户端不同"的可能。

    取舍：带齐了 ``Authorization`` 头却解析失败时**不再回退**到 Cookie——
    否则一个过期令牌会被一个无关的 Cookie 悄悄救活，问题被掩盖。
    """
    if credentials is not None and credentials.credentials:
        return _user_from_access_token(
            db, token=credentials.credentials, settings=settings
        )

    token = read_access_cookie(request)
    if token:
        return _user_from_access_token(db, token=token, settings=settings)

    raise ApiError(
        ErrorCode.unauthorized, "缺少 Authorization 头或网页会话 Cookie"
    )


#: 兼容两种身份载体的只读端点用它
CurrentUserOrWeb = Annotated[User, Depends(get_current_user_flexible)]


def require_web_csrf(
    request: Request,
    x_csrf_token: Annotated[str | None, Header(alias=CSRF_HEADER)] = None,
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
) -> None:
    """网页会话的**写**操作必须带 Double-submit CSRF 对照值。

    两条重要的例外与边界：

    1. **带 ``Authorization: Bearer`` 的请求跳过校验。**
       CSRF 攻击的前提是"浏览器会自动附带环境凭据"（Cookie）。
       Bearer 令牌必须由脚本显式放入请求头，跨站请求根本放不进去，
       因此不存在被冒用的可能。若不跳过，Windows / Android 客户端
       （它们只发 Bearer、没有 CSRF cookie）会**永久 403**，
       连整理映射都做不到 —— 这是实测踩到的缺陷。
    2. 读接口不校验：读取是幂等的，给它加 CSRF 只会让"静默续期"这类
       正常流程变复杂，却不增加任何实际防护。
    """
    if authorization:
        return
    verify_csrf(request, x_csrf_token)


#: ``user: WebCsrf`` 只用于表达"这条路由需要 CSRF"，真实返回值是 None。
WebCsrf = Annotated[None, Depends(require_web_csrf)]


def get_current_device(
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
    device_id: Annotated[str | None, Header(alias=DEVICE_ID_HEADER)] = None,
) -> Device:
    """校验 ``X-Device-Id`` 并返回设备。

    * 未携带 → ``device_not_found``（明确错误，而不是静默按"无设备"处理）；
    * 不属于当前用户 → ``device_not_found``（**不泄露**其他用户的设备是否存在）；
    * 已撤销 → ``device_revoked``（客户端据此停止同步并提示用户）。
    """
    if not device_id:
        raise ApiError(ErrorCode.device_not_found, f"缺少 {DEVICE_ID_HEADER} 请求头")

    try:
        parsed = uuid.UUID(device_id)
    except (ValueError, TypeError) as exc:
        raise ApiError(ErrorCode.invalid_uuid, "设备 ID 不是合法 UUID") from exc

    device = db.scalar(
        select(Device).where(Device.id == parsed, Device.user_id == user.id)
    )
    if device is None:
        raise ApiError(ErrorCode.device_not_found, "设备不存在或不属于当前账户")
    if device.revoked_at is not None:
        raise ApiError(ErrorCode.device_revoked, "该设备已被撤销，请重新登录或联系支持")

    # 任何一次带设备的鉴权都算一次"见到该设备"
    device.last_seen_at = utcnow()
    return device


CurrentDevice = Annotated[Device, Depends(get_current_device)]


def require_integration_service(
    settings: Annotated[Settings, Depends(get_settings)],
    token: Annotated[str | None, Header(alias=INTEGRATION_TOKEN_HEADER)] = None,
) -> None:
    """校验集成服务令牌（Phase 3）。

    与用户鉴权的三点区别：
    * 用**独立的服务身份**，不复用任何用户密码或 Access Token；
    * 服务端没配置 ``PETLIFE_INTEGRATION_TOKEN`` 时**一律拒绝**
      （不是"无鉴权放行"——那会让一个只读接口在公网上裸奔）；
    * 比较用固定时间算法，并且先做 SHA-256 再比较，
      避免 ``compare_digest`` 对非 ASCII 字符串抛 TypeError。
    """
    expected = (settings.integration_token or "").strip()
    if not expected:
        raise ApiError(
            ErrorCode.integration_token_invalid,
            "服务端未启用集成服务（未配置 PETLIFE_INTEGRATION_TOKEN）",
        )

    provided = (token or "").strip()
    if not provided or not secrets.compare_digest(
        hashlib.sha256(provided.encode("utf-8")).digest(),
        hashlib.sha256(expected.encode("utf-8")).digest(),
    ):
        raise ApiError(ErrorCode.integration_token_invalid, "集成服务令牌无效")


#: ``user: IntegrationService`` 这种写法在类型上无意义，但保持了与
#: ``CurrentUser`` 一致的调用风格；真正的返回值是 None。
IntegrationService = Annotated[None, Depends(require_integration_service)]


@dataclass(frozen=True)
class ApiKeyPrincipal:
    """通过个人访问密钥认证的调用方。

    ``user`` 由密钥记录推导，**不是**从请求里读的——这是"AI 侧无法指定
    ``user_id``"的结构性保证。
    """

    key: ApiKey
    user: User


def require_api_key(
    db: Annotated[Session, Depends(get_db)],
    provided: Annotated[str | None, Header(alias=API_KEY_HEADER)] = None,
) -> ApiKeyPrincipal:
    """校验个人访问密钥并返回 ``(密钥, 用户)``。

    * 缺失/空白 → ``api_key_invalid``（401），而不是放行；
    * 无效 → ``api_key_invalid``；已撤销 → ``api_key_revoked``；
    * 账户停用 → ``account_disabled``；缺 ``stats:read`` → ``api_key_scope_denied``。
    """
    candidate = (provided or "").strip()
    if not candidate:
        raise ApiError(ErrorCode.api_key_invalid, f"缺少 {API_KEY_HEADER} 请求头")

    key, user = api_key_service.authenticate(db, plaintext=candidate)
    return ApiKeyPrincipal(key=key, user=user)


#: ``principal.user`` 即"这把密钥属于谁"；密钥本身不再暴露给业务层。
ApiKeyAuth = Annotated[ApiKeyPrincipal, Depends(require_api_key)]
