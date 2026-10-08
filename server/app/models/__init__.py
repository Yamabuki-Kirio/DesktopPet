"""ORM 模型包。

这里显式导入全部模型，保证 ``Base.metadata`` 在使用前已经完整
（Alembic autogenerate 与 ``create_all`` 都依赖这一点）。
"""

from .activity import (
    ENTITY_ACTIVITY_SEGMENT,
    ENTITY_APPLICATION,
    ENTITY_DAILY_USAGE,
    ENTITY_TYPES,
    ActivitySegment,
    DailyUsage,
    SyncLog,
    UserApplication,
)
from .api_key import (
    ALLOWED_SCOPES,
    API_KEY_PREFIX,
    API_KEY_PREFIX_LENGTH,
    DEFAULT_SCOPES,
    SCOPES_SEPARATOR,
    SCOPE_STATS_READ,
    ApiKey,
)
# Phase 2：统一应用目录 + 原始名别名（见 docs/45）
from .application_catalog import (
    CATALOG_SOURCES,
    CATALOG_SOURCE_BUILTIN,
    CATALOG_SOURCE_USER,
    DEFAULT_ALIAS_PRIORITY,
    MATCH_TYPES,
    MATCH_TYPE_EXACT,
    MATCH_TYPE_MANUAL,
    MATCH_TYPE_SUBPROCESS,
    ApplicationAlias,
    ApplicationCatalog,
)
from .device import PLATFORM_ANDROID, PLATFORM_WINDOWS, Device
from .integration import IntegrationLinkCode, TelegramBinding
from .refresh_token import RefreshToken
from .user import User, UserStatus

__all__ = [
    "ALLOWED_SCOPES",
    "API_KEY_PREFIX",
    "API_KEY_PREFIX_LENGTH",
    "CATALOG_SOURCES",
    "CATALOG_SOURCE_BUILTIN",
    "CATALOG_SOURCE_USER",
    "DEFAULT_ALIAS_PRIORITY",
    "DEFAULT_SCOPES",
    "ENTITY_ACTIVITY_SEGMENT",
    "ENTITY_APPLICATION",
    "ENTITY_DAILY_USAGE",
    "ENTITY_TYPES",
    "MATCH_TYPES",
    "MATCH_TYPE_EXACT",
    "MATCH_TYPE_MANUAL",
    "MATCH_TYPE_SUBPROCESS",
    "PLATFORM_ANDROID",
    "PLATFORM_WINDOWS",
    "SCOPES_SEPARATOR",
    "SCOPE_STATS_READ",
    "ActivitySegment",
    "ApiKey",
    "ApplicationAlias",
    "ApplicationCatalog",
    "DailyUsage",
    "Device",
    "IntegrationLinkCode",
    "RefreshToken",
    "SyncLog",
    "TelegramBinding",
    "User",
    "UserApplication",
    "UserStatus",
]
