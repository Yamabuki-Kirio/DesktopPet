"""日志配置与脱敏。

需求明确要求：**日志不得输出 Access Token、Refresh Token、Authorization 请求头或密码。**

实现分两层：
1. :class:`RedactingFilter` 挂在 root logger 上，对**任何**日志记录做正则兜底脱敏
   （包括第三方库自己打的日志）；
2. 请求日志中间件只记录方法 / 路径 / 状态码 / 耗时 / request_id，
   **从不记录请求体与请求头**，因此登录接口的密码不会进入日志。

正则兜底是"最后一道防线"：即使某个开发者不小心把 token 拼进了日志，
落盘前也会被替换成 ``<redacted>``。
"""

from __future__ import annotations

import logging
import re
import sys
import time
import uuid

from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.requests import Request
from starlette.responses import Response

from .errors import REQUEST_ID_HEADER

REDACTED = "<redacted>"

#: 需要脱敏的键名（大小写不敏感）。命中后把「值」替换掉。
_SENSITIVE_KEY = (
    r"(?:access[_-]?token|refresh[_-]?token|id[_-]?token|token|password|passwd|"
    r"secret|authorization|api[_-]?key|credential)"
)

_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    # 顺序很重要：先处理 "Bearer xxx" / "Basic xxx" 这类**带空格的**值，
    # 否则后面的 key=value 规则只会吃掉 "Basic"，把 base64 凭证留在日志里。
    (re.compile(r"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{6,}", re.IGNORECASE), rf"\1 {REDACTED}"),
    # 三段式 JWT（裸 token，没有键名）
    (
        re.compile(r"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{4,}\b"),
        REDACTED,
    ),
    # JSON / form 风格： "password": "xxx"  或  password=xxx
    (
        re.compile(
            rf'(["\']?{_SENSITIVE_KEY}["\']?\s*[:=]\s*)(["\']?)([^\s,;"\'\}}\)]+)(\2)',
            re.IGNORECASE,
        ),
        rf"\1\2{REDACTED}\4",
    ),
)


def redact(text: str) -> str:
    """对任意文本做脱敏（供日志过滤器与测试直接使用）。"""
    result = text
    for pattern, replacement in _PATTERNS:
        result = pattern.sub(replacement, result)
    return result


class RedactingFilter(logging.Filter):
    """在格式化之前把记录里的敏感内容替换掉。"""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:  # pragma: no cover - 格式化失败不应中断日志
            return True
        cleaned = redact(message)
        if cleaned != message:
            record.msg = cleaned
            record.args = ()
        # 异常文本同样可能带 token
        if record.exc_text:
            record.exc_text = redact(record.exc_text)
        return True


def setup_logging(level: int = logging.INFO) -> None:
    """初始化 root logger（幂等）。"""
    root = logging.getLogger()
    if any(isinstance(f, RedactingFilter) for f in root.filters):
        return
    root.addFilter(RedactingFilter())
    if not root.handlers:
        handler = logging.StreamHandler(stream=sys.stdout)
        handler.setFormatter(
            logging.Formatter(
                '{"ts":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s",'
                '"msg":"%(message)s"}'
            )
        )
        handler.addFilter(RedactingFilter())
        root.addHandler(handler)
    root.setLevel(level)
    # uvicorn / sqlalchemy 的访问日志同样过一遍过滤器（它们在 root 之下）。
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access", "sqlalchemy.engine"):
        logging.getLogger(name).addFilter(RedactingFilter())


class RequestContextMiddleware(BaseHTTPMiddleware):
    """给每个请求分配 request_id，并输出一条不含敏感信息的访问日志。"""

    def __init__(self, app, logger_name: str = "petlife.api.access") -> None:
        super().__init__(app)
        self._logger = logging.getLogger(logger_name)

    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        incoming = request.headers.get(REQUEST_ID_HEADER, "").strip()
        request_id = incoming[:64] if incoming else uuid.uuid4().hex
        request.state.request_id = request_id

        started = time.perf_counter()
        response = await call_next(request)
        elapsed_ms = (time.perf_counter() - started) * 1000

        response.headers[REQUEST_ID_HEADER] = request_id
        # 刻意只记录「元数据」：方法、路径、状态码、耗时。
        # 不记录 query（可能是 cursor 等）、不记录 body、不记录 headers。
        self._logger.info(
            "request_id=%s method=%s path=%s status=%s elapsed_ms=%.1f",
            request_id,
            request.method,
            request.url.path,
            response.status_code,
            elapsed_ms,
        )
        return response
