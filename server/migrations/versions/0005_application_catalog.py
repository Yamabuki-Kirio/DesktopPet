"""Phase 2: application catalog and aliases

新增两张表，用于把 Android 的多进程包名与 Windows 的可执行名
归并成一个"统一应用"（见 docs/45）：

* ``application_catalog``：统一应用（显示名 / 分类 / 图标标识）
* ``application_aliases``：原始名 → 统一应用 的映射

**刻意不做的事**（避免动到已部署的数据）：

* 不修改 ``user_applications`` —— 它由客户端同步推送，协议保持不变，
  旧客户端与历史数据都不受影响；
* 不改动 ``activity_segments`` 任何一行 —— 归一化只发生在查询与展示层，
  原始活动片段永久保留、可追溯；
* 不给已有表加列。

因此本迁移对生产数据完全无损，``downgrade`` 只删这两张新表。

Revision ID: 0005_application_catalog
Revises: 0004_usage_stats_indexes
Create Date: 2026-10-06
"""

from __future__ import annotations

from typing import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0005_application_catalog"
down_revision: str | None = "0004_usage_stats_indexes"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "application_catalog",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("display_name", sa.String(length=128), nullable=False),
        sa.Column("category", sa.String(length=32), nullable=False),
        sa.Column("icon_key", sa.String(length=64), nullable=True),
        sa.Column("source", sa.String(length=16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        # 同一账户下不允许两个同名统一应用，否则整理界面无法分辨合并目标
        sa.UniqueConstraint(
            "user_id", "display_name", name="uq_application_catalog_user_display_name"
        ),
    )
    op.create_index(
        "ix_application_catalog_user_id", "application_catalog", ["user_id"]
    )

    op.create_table(
        "application_aliases",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("catalog_id", sa.Uuid(), nullable=False),
        sa.Column("raw_app_key", sa.String(length=128), nullable=False),
        sa.Column("platform", sa.String(length=32), nullable=True),
        sa.Column("match_type", sa.String(length=16), nullable=False),
        sa.Column("priority", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(
            ["catalog_id"], ["application_catalog.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
        # 一个原始名在同一账户下只能指向一个统一应用（用户隔离 + 语义唯一）
        sa.UniqueConstraint(
            "user_id", "raw_app_key", name="uq_application_aliases_user_raw_key"
        ),
    )
    op.create_index(
        "ix_application_aliases_user_raw_key",
        "application_aliases",
        ["user_id", "raw_app_key"],
    )
    op.create_index(
        "ix_application_aliases_catalog_id", "application_aliases", ["catalog_id"]
    )


def downgrade() -> None:
    op.drop_index("ix_application_aliases_catalog_id", table_name="application_aliases")
    op.drop_index(
        "ix_application_aliases_user_raw_key", table_name="application_aliases"
    )
    op.drop_table("application_aliases")
    op.drop_index("ix_application_catalog_user_id", table_name="application_catalog")
    op.drop_table("application_catalog")
