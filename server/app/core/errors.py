"""统一错误响应。

格式（与需求一致）：

```json
{
  "error": {
    "code": "invalid_credentials",
    "message": "邮箱或密码错误",
    "request_id": "..."
  }
}
```

约定：
* **任何** 4xx / 5xx 都走这个结构，客户端只需实现一套解析逻辑。
* ``request_id`` 同时写入响应头 ``X-Request-Id``，便于与服务端日志对齐。
* 5xx 只返回通用文案，细节留在服务端日志里，避免把内部结构泄露给客户端。
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

logger = logging.getLogger("petlife.api.error")

REQUEST_ID_HEADER = "X-Request-Id"

# 直接使用数字状态码，避免依赖 starlette 里已被弃用的常量名
HTTP_400_BAD_REQUEST = 400
HTTP_401_UNAUTHORIZED = 401
HTTP_403_FORBIDDEN = 403
HTTP_404_NOT_FOUND = 404
HTTP_409_CONFLICT = 409
HTTP_413_CONTENT_TOO_LARGE = 413
HTTP_422_UNPROCESSABLE_CONTENT = 422
HTTP_500_INTERNAL_SERVER_ERROR = 500


class ErrorCode:
    """稳定的错误码。客户端不应依赖文案，只应依赖这些码。"""

    # 认证
    invalid_credentials = "invalid_credentials"
    email_taken = "email_taken"
    unauthorized = "unauthorized"
    token_expired = "token_expired"
    token_invalid = "token_invalid"
    refresh_token_reused = "refresh_token_reused"
    account_disabled = "account_disabled"
    # 设备
    device_not_found = "device_not_found"
    device_revoked = "device_revoked"
    # 同步
    invalid_batch = "invalid_batch"
    batch_too_large = "batch_too_large"
    invalid_uuid = "invalid_uuid"
    invalid_time_range = "invalid_time_range"
    invalid_cursor = "invalid_cursor"
    # 集成（Phase 3：Telegram / MCP）
    integration_token_invalid = "integration_token_invalid"
    link_code_invalid = "link_code_invalid"
    link_code_expired = "link_code_expired"
    link_code_consumed = "link_code_consumed"
    telegram_already_bound = "telegram_already_bound"
    telegram_not_bound = "telegram_not_bound"
    binding_not_found = "binding_not_found"
    # 个人访问密钥（Phase 3 改版）
    api_key_invalid = "api_key_invalid"
    api_key_revoked = "api_key_revoked"
    api_key_not_found = "api_key_not_found"
    api_key_scope_denied = "api_key_scope_denied"
    # 网页会话（GameLog「生活足迹」，见 docs/43）
    csrf_token_invalid = "csrf_token_invalid"
    web_session_expired = "web_session_expired"
    # 应用目录（Phase 2A，见 docs/45）
    catalog_not_found = "catalog_not_found"
    catalog_duplicate = "catalog_duplicate"
    alias_not_found = "alias_not_found"
    alias_conflict = "alias_conflict"
    # 通用
    validation_error = "validation_error"
    not_found = "not_found"
    conflict = "conflict"
    internal_error = "internal_error"


#: 错误码 -> 默认 HTTP 状态码
DEFAULT_STATUS: dict[str, int] = {
    ErrorCode.invalid_credentials: HTTP_401_UNAUTHORIZED,
    ErrorCode.unauthorized: HTTP_401_UNAUTHORIZED,
    ErrorCode.token_expired: HTTP_401_UNAUTHORIZED,
    ErrorCode.token_invalid: HTTP_401_UNAUTHORIZED,
    ErrorCode.refresh_token_reused: HTTP_401_UNAUTHORIZED,
    ErrorCode.account_disabled: HTTP_403_FORBIDDEN,
    ErrorCode.device_revoked: HTTP_403_FORBIDDEN,
    ErrorCode.email_taken: HTTP_409_CONFLICT,
    ErrorCode.device_not_found: HTTP_404_NOT_FOUND,
    ErrorCode.not_found: HTTP_404_NOT_FOUND,
    ErrorCode.conflict: HTTP_409_CONFLICT,
    ErrorCode.invalid_batch: HTTP_400_BAD_REQUEST,
    ErrorCode.batch_too_large: HTTP_413_CONTENT_TOO_LARGE,
    ErrorCode.invalid_uuid: HTTP_400_BAD_REQUEST,
    ErrorCode.invalid_time_range: HTTP_400_BAD_REQUEST,
    ErrorCode.invalid_cursor: HTTP_400_BAD_REQUEST,
    ErrorCode.validation_error: HTTP_422_UNPROCESSABLE_CONTENT,
    # 集成
    ErrorCode.integration_token_invalid: HTTP_401_UNAUTHORIZED,
    ErrorCode.link_code_invalid: HTTP_400_BAD_REQUEST,
    ErrorCode.link_code_expired: HTTP_400_BAD_REQUEST,
    ErrorCode.link_code_consumed: HTTP_409_CONFLICT,
    ErrorCode.telegram_already_bound: HTTP_409_CONFLICT,
    ErrorCode.telegram_not_bound: HTTP_404_NOT_FOUND,
    ErrorCode.binding_not_found: HTTP_404_NOT_FOUND,
    # 个人访问密钥
    ErrorCode.api_key_invalid: HTTP_401_UNAUTHORIZED,
    ErrorCode.api_key_revoked: HTTP_401_UNAUTHORIZED,
    ErrorCode.api_key_scope_denied: HTTP_403_FORBIDDEN,
    ErrorCode.api_key_not_found: HTTP_404_NOT_FOUND,
    # 网页会话：CSRF 失败用 403（已认证但不允许该来源的写操作）
    ErrorCode.csrf_token_invalid: HTTP_403_FORBIDDEN,
    ErrorCode.web_session_expired: HTTP_401_UNAUTHORIZED,
    # 应用目录
    ErrorCode.catalog_not_found: HTTP_404_NOT_FOUND,
    ErrorCode.catalog_duplicate: HTTP_409_CONFLICT,
    ErrorCode.alias_not_found: HTTP_404_NOT_FOUND,
    ErrorCode.alias_conflict: HTTP_409_CONFLICT,
    ErrorCode.internal_error: HTTP_500_INTERNAL_SERVER_ERROR,
}


class ApiError(Exception):
    """业务错误。服务层抛出它，由全局处理器转成统一错误体。"""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        status_code: int | None = None,
        detail: object | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code or DEFAULT_STATUS.get(code, HTTP_400_BAD_REQUEST)
        self.detail = detail


def _request_id(request: Request) -> str:
    return getattr(request.state, "request_id", "-")


def _payload(code: str, message: str, request_id: str, detail: object | None = None):
    body: dict[str, object] = {
        "code": code,
        "message": message,
        "request_id": request_id,
    }
    if detail is not None:
        body["detail"] = detail
    return {"error": body}


#: pydantic 校验错误类型 -> 我们对外暴露的稳定错误码
_VALIDATION_CODE_MAP: dict[str, str] = {
    "uuid_parsing": ErrorCode.invalid_uuid,
    "uuid_type": ErrorCode.invalid_uuid,
    "uuid_version": ErrorCode.invalid_uuid,
    "datetime_parsing": ErrorCode.invalid_time_range,
    "datetime_type": ErrorCode.invalid_time_range,
    "datetime_from_date_parsing": ErrorCode.invalid_time_range,
    "date_parsing": ErrorCode.invalid_time_range,
}


def _validation_error_code(raw_errors: list[dict]) -> str:
    """按第一条错误的类型给出更精确的错误码。

    全部错误都是同一类（例如全是 UUID 解析失败）时才提升为专用错误码，
    混合错误一律回退到通用的 ``validation_error``。
    """
    codes = {_VALIDATION_CODE_MAP.get(str(e.get("type"))) for e in raw_errors}
    codes.discard(None)
    if len(codes) == 1:
        return next(iter(codes))
    return ErrorCode.validation_error


def install_error_handlers(app: FastAPI) -> None:
    """把三类异常统一到同一响应结构。"""

    @app.exception_handler(ApiError)
    async def _api_error(request: Request, exc: ApiError) -> JSONResponse:
        # 4xx 记 warning（客户端问题），5xx 记 error（服务端问题）。
        log = logger.warning if exc.status_code < 500 else logger.error
        log("api error code=%s status=%s path=%s", exc.code, exc.status_code, request.url.path)
        return JSONResponse(
            status_code=exc.status_code,
            content=_payload(exc.code, exc.message, _request_id(request), exc.detail),
            headers={REQUEST_ID_HEADER: _request_id(request)},
        )

    @app.exception_handler(RequestValidationError)
    async def _validation_error(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        """校验失败：回字段路径与原因，**不回传原始输入值**（可能含密码/令牌）。

        UUID 与时间格式这类高频错误映射到更精确的错误码，方便客户端区分处理。
        """
        raw_errors = exc.errors()
        safe_errors = [
            {
                "loc": [str(part) for part in err.get("loc", ())],
                "type": err.get("type", "value_error"),
                "msg": err.get("msg", "invalid value"),
            }
            for err in raw_errors
        ]
        code = _validation_error_code(raw_errors)
        return JSONResponse(
            status_code=HTTP_422_UNPROCESSABLE_CONTENT,
            content=_payload(code, "请求参数校验失败", _request_id(request), safe_errors),
            headers={REQUEST_ID_HEADER: _request_id(request)},
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(
        request: Request, exc: StarletteHTTPException
    ) -> JSONResponse:
        code = {
            401: ErrorCode.unauthorized,
            403: ErrorCode.device_revoked,
            404: ErrorCode.not_found,
            405: ErrorCode.not_found,
        }.get(exc.status_code, "http_error")
        message = exc.detail if isinstance(exc.detail, str) else "请求失败"
        return JSONResponse(
            status_code=exc.status_code,
            content=_payload(code, message, _request_id(request)),
            headers={REQUEST_ID_HEADER: _request_id(request)},
        )

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
        # 未预期异常：细节只进日志，响应只给通用文案 + request_id。
        logger.exception(
            "unhandled error path=%s request_id=%s", request.url.path, _request_id(request)
        )
        return JSONResponse(
            status_code=HTTP_500_INTERNAL_SERVER_ERROR,
            content=_payload(
                ErrorCode.internal_error,
                "服务端内部错误，请稍后重试或联系管理员并提供 request_id",
                _request_id(request),
            ),
            headers={REQUEST_ID_HEADER: _request_id(request)},
        )
