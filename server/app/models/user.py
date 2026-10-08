"""用户模型。"""

from __future__ import annotations

import uuid
from datetime import datetime
from enum import StrEnum

from sqlalchemy import Index, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column, validates

from ..core.types import UTCDateTime
from ..core.timeutil import utcnow
from ..database.base import Base


class UserStatus(StrEnum):
    """账户状态。

    用普通字符串 + CHECK 约束而不是 PostgreSQL 原生 ENUM：
    原生 ENUM 在 Alembic 里增删值很麻烦，而这里只有三个稳定取值。
    """

    active = "active"
    disabled = "disabled"
    deleted = "deleted"


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        Index("ix_users_email_lower", "email", unique=True),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)

    #: 唯一且**统一小写**（由 _normalize_email 保证）
    email: Mapped[str] = mapped_column(String(320), nullable=False)

    display_name: Mapped[str] = mapped_column(String(64), nullable=False)

    #: Argon2id 哈希，绝不存明文
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)

    status: Mapped[str] = mapped_column(
        String(16), nullable=False, default=UserStatus.active.value
    )

    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )
    updated_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow, onupdate=utcnow
    )
    deleted_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)

    @validates("email")
    def _normalize_email(self, _key: str, value: str) -> str:
        """邮箱统一转小写存储，避免 A@b.com 与 a@b.com 被当成两个账户。"""
        return value.strip().lower()

    @property
    def is_active(self) -> bool:
        return self.status == UserStatus.active.value

    def __repr__(self) -> str:  # pragma: no cover - 调试用
        return f"<User {self.email} status={self.status}>"
