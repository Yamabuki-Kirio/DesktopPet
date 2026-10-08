"""Phase 3（改版）：个人访问密钥（Personal Access Key）。

为什么改成密钥
--------------
原设计让 MCP 依赖 `telegram_user_id` + 动态请求头来确定"这是谁"，
这要求接入方（AstrBot）必须能按用户注入请求头——现实中不保证做得到，
而且一旦会话被复用就会串号。

现在改为：**密钥本身标识用户**。

* 明文形如 ``plk_<43 字符>``，**只在生成时返回一次**；
* 库里只存 SHA-256 哈希（复用 ``security.tokens.hash_token``）；
* ``key_prefix`` 存明文前 12 个字符（``plk_`` + 8 位），仅用于列表里区分是哪把钥匙，
  不足以还原密钥；
* 权限固定为 ``stats:read``（只读统计），写入侧不接受调用方自定义 scope；
* 撤销写 ``revoked_at``，不删行（保留审计痕迹，且撤销后立即可检测）。
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import ForeignKey, Index, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from ..core.timeutil import utcnow
from ..core.types import UTCDateTime
from ..database.base import Base

#: 密钥前缀。生成时明文一定以它开头，便于人眼识别与日志脱敏规则匹配。
API_KEY_PREFIX = "plk_"

#: 前缀在库里保留多少字符（``plk_`` + 8 位随机）
API_KEY_PREFIX_LENGTH = len(API_KEY_PREFIX) + 8

#: 只读统计权限。当前是唯一允许的权限。
SCOPE_STATS_READ = "stats:read"

#: 允许写入 ``scopes`` 的全部取值。请求里出现集合外的值一律拒绝。
ALLOWED_SCOPES: frozenset[str] = frozenset({SCOPE_STATS_READ})

#: 新密钥默认权限
DEFAULT_SCOPES: tuple[str, ...] = (SCOPE_STATS_READ,)

SCOPES_SEPARATOR = " "


class ApiKey(Base):
    """一把个人访问密钥。"""

    __tablename__ = "api_keys"
    __table_args__ = (
        # 鉴权就是按哈希查一行，必须唯一且有索引
        Index("ix_api_keys_key_hash", "key_hash", unique=True),
        # 列出某用户的密钥 / 判断是否已撤销
        Index("ix_api_keys_user_id_revoked_at", "user_id", "revoked_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    #: SHA-256 hex（64 字符），**不是**明文
    key_hash: Mapped[str] = mapped_column(String(64), nullable=False)

    #: 明文前 12 字符，仅用于展示与区分
    key_prefix: Mapped[str] = mapped_column(String(16), nullable=False)

    name: Mapped[str] = mapped_column(String(64), nullable=False)

    #: 空格分隔的权限集合，当前恒为 "stats:read"
    scopes: Mapped[str] = mapped_column(
        String(128), nullable=False, default=SCOPE_STATS_READ
    )

    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )

    #: 最近一次被用于鉴权的时间（每次成功鉴权都会刷新）
    last_used_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)

    #: 撤销时间；非空表示这把钥匙再也用不了
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)

    @property
    def is_active(self) -> bool:
        return self.revoked_at is None

    @property
    def scope_set(self) -> frozenset[str]:
        return frozenset(part for part in self.scopes.split(SCOPES_SEPARATOR) if part)

    def __repr__(self) -> str:  # pragma: no cover - 调试用
        # 只出现前缀与状态，永不出现哈希或明文
        return (
            f"<ApiKey {self.key_prefix}… user={self.user_id} "
            f"active={self.is_active}>"
        )
