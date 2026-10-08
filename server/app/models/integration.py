"""Phase 3 集成模型：Telegram 绑定与一次性绑定码。

设计要点
--------
* **绑定码只存哈希**：库里永远看不到明文码，日志也不打印；
* **"有效"用部分唯一索引表达**，而不是靠应用层"记得先查再插"：
  - ``telegram_bindings``：同一 ``telegram_user_id`` 在 ``revoked_at IS NULL``
    时只允许一行 → 一个 Telegram 账号只能绑定一个 PetLife 用户；
  - ``integration_link_codes``：同一 ``user_id`` 在 ``consumed_at IS NULL``
    时只允许一行 → 每账户同时最多一个未使用的绑定码。
  撤销/消费过的历史行不受约束，保留审计痕迹。
* ``telegram_user_id`` / ``telegram_chat_id`` 是 Telegram 侧的数字 ID，
  用 BigInteger（不是字符串），避免"把数字当字符串存"导致的大小写/前导零歧义。
* 这里**没有**任何令牌、密码或对话内容字段——AI 侧只能拿到汇总统计（见 docs/23）。
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import BigInteger, ForeignKey, Index, String, Uuid, text
from sqlalchemy.orm import Mapped, mapped_column

from ..core.timeutil import utcnow
from ..core.types import UTCDateTime
from ..database.base import Base


class IntegrationLinkCode(Base):
    """一次性 Telegram 绑定码。

    生命周期：生成 → （10 分钟内）被 ``/bind`` 消费 → ``consumed_at`` 置位。
    明文码只在生成响应里出现一次；库里只有 ``code_hash``（SHA-256）。
    """

    __tablename__ = "integration_link_codes"
    __table_args__ = (
        # 查码时按哈希查，必须唯一且带索引
        Index("ix_integration_link_codes_code_hash", "code_hash", unique=True),
        # 每个账户同时最多一个"未被消费"的码。部分唯一索引 = 数据库层面的保证。
        Index(
            "uq_integration_link_codes_active_user",
            "user_id",
            unique=True,
            sqlite_where=text("consumed_at IS NULL"),
            postgresql_where=text("consumed_at IS NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    #: SHA-256 hex（64 字符），**不是**明文码
    code_hash: Mapped[str] = mapped_column(String(64), nullable=False)

    expires_at: Mapped[datetime] = mapped_column(UTCDateTime, nullable=False)

    #: 被使用的时间；非空表示这个码已经作废
    consumed_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )

    def is_usable(self, now: datetime) -> bool:
        return self.consumed_at is None and self.expires_at > now

    def __repr__(self) -> str:  # pragma: no cover - 调试用
        return (
            f"<IntegrationLinkCode user={self.user_id} "
            f"consumed={'yes' if self.consumed_at else 'no'}>"
        )


class TelegramBinding(Base):
    """Telegram 账号 ↔ PetLife 用户的绑定关系。

    解绑**不删行**，只写 ``revoked_at``：这样"解绑后立即失权"与
    "该 Telegram 账号可以再绑定别的账户"两件事都由数据本身说清楚。
    """

    __tablename__ = "telegram_bindings"
    __table_args__ = (
        # 列出某账户的绑定
        Index("ix_telegram_bindings_user_id", "user_id"),
        # 一个有效（未解绑）的 Telegram 账号只能属于一个 PetLife 用户
        Index(
            "uq_telegram_bindings_active_telegram_user",
            "telegram_user_id",
            unique=True,
            sqlite_where=text("revoked_at IS NULL"),
            postgresql_where=text("revoked_at IS NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    #: Telegram 侧 user_id（数字）
    telegram_user_id: Mapped[int] = mapped_column(BigInteger, nullable=False)

    #: Telegram 会话 ID（私聊等于 user_id；群里是群 ID）
    telegram_chat_id: Mapped[int] = mapped_column(BigInteger, nullable=False)

    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )

    #: 解绑时间；非空表示该绑定已失效
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)

    @property
    def is_active(self) -> bool:
        return self.revoked_at is None

    def __repr__(self) -> str:  # pragma: no cover - 调试用
        return (
            f"<TelegramBinding user={self.user_id} "
            f"tg={self.telegram_user_id} active={self.is_active}>"
        )
