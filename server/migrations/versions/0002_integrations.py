"""Phase 3: telegram integrations

新增两张表，支撑「Telegram AI 只读查询用户自己的使用统计」：

* ``integration_link_codes``：一次性绑定码（**只存哈希**，10 分钟过期，用一次即废）；
* ``telegram_bindings``：Telegram 账号 ↔ PetLife 用户的绑定关系（解绑写 ``revoked_at``）。

约束说明
--------
"有效"这件事用**部分唯一索引**表达，而不是靠应用层自觉：

* 同一 ``telegram_user_id`` 在 ``revoked_at IS NULL`` 时只能有一行
  → 一个 Telegram 账号不能同时绑定两个 PetLife 用户；
* 同一 ``user_id`` 在 ``consumed_at IS NULL`` 时只能有一行
  → 每个账户同时最多一个未使用的绑定码。

SQLite 与 PostgreSQL 都支持部分索引，但写法不同，因此两个 ``*_where`` 都要给。

Revision ID: 0002_integrations
Revises: 0001_initial
Create Date: 2026-09-28
"""

from __future__ import annotations

from typing import Sequence

import sqlalchemy as sa
from alembic import op

# 自定义 UTC 时间类型必须可导入，否则迁移脚本无法执行
import app.core.types  # noqa: F401

UTCDateTime = app.core.types.UTCDateTime

revision: str = "0002_integrations"
down_revision: str | None = "0001_initial"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ------------------------------------------------- integration_link_codes
    op.create_table(
        "integration_link_codes",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("code_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", UTCDateTime(), nullable=False),
        sa.Column("consumed_at", UTCDateTime(), nullable=True),
        sa.Column("created_at", UTCDateTime(), nullable=False),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"],
            name=op.f("fk_integration_link_codes_user_id_users"), ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_integration_link_codes")),
    )
    op.create_index(
        "ix_integration_link_codes_code_hash",
        "integration_link_codes",
        ["code_hash"],
        unique=True,
    )
    op.create_index(
        "uq_integration_link_codes_active_user",
        "integration_link_codes",
        ["user_id"],
        unique=True,
        sqlite_where=sa.text("consumed_at IS NULL"),
        postgresql_where=sa.text("consumed_at IS NULL"),
    )

    # ------------------------------------------------------ telegram_bindings
    op.create_table(
        "telegram_bindings",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("telegram_user_id", sa.BigInteger(), nullable=False),
        sa.Column("telegram_chat_id", sa.BigInteger(), nullable=False),
        sa.Column("created_at", UTCDateTime(), nullable=False),
        sa.Column("revoked_at", UTCDateTime(), nullable=True),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"],
            name=op.f("fk_telegram_bindings_user_id_users"), ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_telegram_bindings")),
    )
    op.create_index(
        "ix_telegram_bindings_user_id", "telegram_bindings", ["user_id"]
    )
    op.create_index(
        "uq_telegram_bindings_active_telegram_user",
        "telegram_bindings",
        ["telegram_user_id"],
        unique=True,
        sqlite_where=sa.text("revoked_at IS NULL"),
        postgresql_where=sa.text("revoked_at IS NULL"),
    )


def downgrade() -> None:
    op.drop_index(
        "uq_telegram_bindings_active_telegram_user", table_name="telegram_bindings"
    )
    op.drop_index("ix_telegram_bindings_user_id", table_name="telegram_bindings")
    op.drop_table("telegram_bindings")

    op.drop_index(
        "uq_integration_link_codes_active_user", table_name="integration_link_codes"
    )
    op.drop_index(
        "ix_integration_link_codes_code_hash", table_name="integration_link_codes"
    )
    op.drop_table("integration_link_codes")
