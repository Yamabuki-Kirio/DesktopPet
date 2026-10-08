"""Refresh Token 模型。

设计要点（对应需求「二、账户系统」）：
* 服务端**只保存 Refresh Token 的哈希**（SHA-256），不保存明文；
* 支持**轮换**：每次刷新生成新 token，旧 token 立即标记 revoked 并记录 replaced_by；
* 复用检测：若已轮换过（或已注销）的 token 再次出现，视为泄露，
  立即吊销该用户的**全部** refresh token，强制重新登录；
* 修改密码 / 注销全部会话 / 撤销设备 / 删除账户都会批量吊销。
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import ForeignKey, Index, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from ..core.types import UTCDateTime
from ..core.timeutil import utcnow
from ..database.base import Base


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"
    __table_args__ = (
        Index("ix_refresh_tokens_user_id_revoked_at", "user_id", "revoked_at"),
        Index("ix_refresh_tokens_device_id", "device_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )

    device_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("devices.id", ondelete="CASCADE"), nullable=True
    )

    #: SHA-256(token) 的十六进制摘要；明文只在响应里出现一次
    token_hash: Mapped[str] = mapped_column(
        String(64), nullable=False, unique=True, index=True
    )

    issued_at: Mapped[datetime] = mapped_column(UTCDateTime, nullable=False, default=utcnow)
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime, nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)

    #: 轮换后指向新 token，用于复用检测与审计
    replaced_by_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)

    #: 检测到复用的时刻（非空即表示这条链已被判定为泄露）
    reused_detected_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)

    def is_usable(self, now: datetime) -> bool:
        return self.revoked_at is None and self.expires_at > now

    def __repr__(self) -> str:  # pragma: no cover
        return f"<RefreshToken user={self.user_id} revoked={self.revoked_at is not None}>"
