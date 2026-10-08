"""Phase 3（改版）: personal access keys

新增 ``api_keys`` 表，让 MCP / AI 用**一把密钥**代表一个 PetLife 用户，
从而彻底去掉"按请求注入 telegram_user_id"的依赖。

* 明文形如 ``plk_<43 字符>``，只在生成响应里出现一次；
* 库里只有 ``key_hash``（SHA-256）与 ``key_prefix``（前 12 字符，仅用于展示）；
* ``scopes`` 当前恒为 ``stats:read``；
* 撤销写 ``revoked_at``，不删行。

原有的 ``integration_link_codes`` / ``telegram_bindings`` **保留不动**：
它们已经部署过，数据不该因为这次改版被删；但 MCP 不再依赖它们。

Revision ID: 0003_api_keys
Revises: 0002_integrations
Create Date: 2026-09-28
"""

from __future__ import annotations

from typing import Sequence

import sqlalchemy as sa
from alembic import op

import app.core.types  # noqa: F401

UTCDateTime = app.core.types.UTCDateTime

revision: str = "0003_api_keys"
down_revision: str | None = "0002_integrations"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "api_keys",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("key_hash", sa.String(length=64), nullable=False),
        sa.Column("key_prefix", sa.String(length=16), nullable=False),
        sa.Column("name", sa.String(length=64), nullable=False),
        sa.Column("scopes", sa.String(length=128), nullable=False),
        sa.Column("created_at", UTCDateTime(), nullable=False),
        sa.Column("last_used_at", UTCDateTime(), nullable=True),
        sa.Column("revoked_at", UTCDateTime(), nullable=True),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"],
            name=op.f("fk_api_keys_user_id_users"), ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_api_keys")),
    )
    op.create_index("ix_api_keys_key_hash", "api_keys", ["key_hash"], unique=True)
    op.create_index(
        "ix_api_keys_user_id_revoked_at", "api_keys", ["user_id", "revoked_at"]
    )


def downgrade() -> None:
    op.drop_index("ix_api_keys_user_id_revoked_at", table_name="api_keys")
    op.drop_index("ix_api_keys_key_hash", table_name="api_keys")
    op.drop_table("api_keys")
