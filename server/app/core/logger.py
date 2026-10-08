"""日志获取入口（所有日志都经过 ``RedactingFilter`` 脱敏）。"""

from __future__ import annotations

import logging

PREFIX = "petlife"


def get_logger(name: str) -> logging.Logger:
    """返回带统一前缀的 logger。

    ``app.services.auth_service`` → ``petlife.app.services.auth_service``
    """
    short = name.split(".")[-1] if name.startswith("app.") else name
    return logging.getLogger(f"{PREFIX}.{short}")
