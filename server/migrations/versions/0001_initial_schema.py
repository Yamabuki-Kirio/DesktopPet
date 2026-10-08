"""initial schema: users / devices / refresh_tokens / activity_segments /
daily_usage / user_applications / sync_log

Revision ID: 0001_initial
Revises:
Create Date: 2026-09-27

说明
----
* 全部主键用客户端或服务端生成的 UUID，**没有自增业务 ID**，
  因此不存在"跨设备身份靠 SQLite rowid"的问题。
* ``sync_log.seq`` 是唯一自增列，只用于给增量同步提供单调游标。
* 隐私：这里**没有**窗口标题 / URL / 文档名 / 本地完整路径 / 截图等列，
  从物理结构上保证这些数据无法被写入。
* ``activity_segments`` 与 ``daily_usage`` 的主键都含 ``user_id``，
  因此"用户 A 覆盖用户 B 的数据"在结构层面就不可能发生。
"""

from __future__ import annotations

from typing import Sequence

import sqlalchemy as sa
from alembic import op

# 自定义 UTC 时间类型必须可导入，否则迁移脚本无法执行
import app.core.types  # noqa: F401

# 与 app/models/activity.py 保持一致的可移植类型
AutoIncrementBigInt = sa.BigInteger().with_variant(sa.Integer(), "sqlite")
UTCDateTime = app.core.types.UTCDateTime

revision: str = "0001_initial"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ---------------------------------------------------------------- users
    op.create_table(
        "users",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("email", sa.String(length=320), nullable=False),
        sa.Column("display_name", sa.String(length=64), nullable=False),
        sa.Column("password_hash", sa.String(length=255), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("created_at", UTCDateTime(), nullable=False),
        sa.Column("updated_at", UTCDateTime(), nullable=False),
        sa.Column("deleted_at", UTCDateTime(), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_users")),
    )
    op.create_index("ix_users_email_lower", "users", ["email"], unique=True)

    # -------------------------------------------------------------- devices
    op.create_table(
        "devices",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("device_local_id", sa.String(length=64), nullable=False),
        sa.Column("device_name", sa.String(length=128), nullable=False),
        sa.Column("platform", sa.String(length=32), nullable=False),
        sa.Column("architecture", sa.String(length=32), nullable=False),
        sa.Column("os_version", sa.String(length=128), nullable=True),
        sa.Column("app_version", sa.String(length=32), nullable=True),
        sa.Column("model_name", sa.String(length=128), nullable=True),
        sa.Column("last_seen_at", UTCDateTime(), nullable=False),
        sa.Column("created_at", UTCDateTime(), nullable=False),
        sa.Column("revoked_at", UTCDateTime(), nullable=True),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_devices_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_devices")),
        sa.UniqueConstraint(
            "user_id", "device_local_id", name="uq_devices_user_id_device_local_id"
        ),
    )
    op.create_index(
        "ix_devices_user_id_revoked_at", "devices", ["user_id", "revoked_at"]
    )

    # ------------------------------------------------------------- sync_log
    op.create_table(
        "sync_log",
        sa.Column("seq", AutoIncrementBigInt, autoincrement=True, nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("entity_type", sa.String(length=32), nullable=False),
        sa.Column("record_key", sa.String(length=256), nullable=False),
        sa.Column("op", sa.String(length=8), nullable=False),
        sa.Column("changed_at", UTCDateTime(), nullable=False),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_sync_log_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("seq", name=op.f("pk_sync_log")),
    )
    op.create_index("ix_sync_log_user_seq", "sync_log", ["user_id", "seq"])
    op.create_index("ix_sync_log_user_entity", "sync_log", ["user_id", "entity_type"])

    # ----------------------------------------------------- user_applications
    op.create_table(
        "user_applications",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("app_key", sa.String(length=128), nullable=False),
        sa.Column("display_name", sa.String(length=128), nullable=False),
        sa.Column("category", sa.String(length=32), nullable=False),
        sa.Column("user_overridden", sa.Boolean(), nullable=False),
        sa.Column("updated_at", UTCDateTime(), nullable=False),
        sa.Column("server_received_at", UTCDateTime(), nullable=False),
        sa.Column("change_seq", AutoIncrementBigInt, nullable=True),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_user_applications_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("user_id", "app_key", name=op.f("pk_user_applications")),
    )
    op.create_index(
        "ix_user_applications_user_change_seq", "user_applications", ["user_id", "change_seq"]
    )

    # ------------------------------------------------------ activity_segments
    op.create_table(
        "activity_segments",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("app_key", sa.String(length=128), nullable=False),
        sa.Column("category", sa.String(length=32), nullable=False),
        sa.Column("started_at", UTCDateTime(), nullable=False),
        sa.Column("ended_at", UTCDateTime(), nullable=True),
        sa.Column("active_seconds", sa.Integer(), nullable=False),
        sa.Column("end_reason", sa.String(length=32), nullable=True),
        sa.Column("created_at", UTCDateTime(), nullable=False),
        sa.Column("updated_at", UTCDateTime(), nullable=False),
        sa.Column("server_received_at", UTCDateTime(), nullable=False),
        sa.Column("change_seq", AutoIncrementBigInt, nullable=True),
        sa.ForeignKeyConstraint(
            ["device_id"], ["devices.id"],
            name=op.f("fk_activity_segments_device_id_devices"), ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"],
            name=op.f("fk_activity_segments_user_id_users"), ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("user_id", "id", name=op.f("pk_activity_segments")),
    )
    op.create_index(
        "ix_activity_segments_user_started", "activity_segments", ["user_id", "started_at"]
    )
    op.create_index(
        "ix_activity_segments_user_device", "activity_segments", ["user_id", "device_id"]
    )
    op.create_index(
        "ix_activity_segments_user_change_seq", "activity_segments", ["user_id", "change_seq"]
    )
    op.create_index(
        "ix_activity_segments_user_app_key", "activity_segments", ["user_id", "app_key"]
    )

    # ----------------------------------------------------------- daily_usage
    op.create_table(
        "daily_usage",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("local_day", sa.String(length=10), nullable=False),
        sa.Column("timezone_offset_minutes", sa.Integer(), nullable=False),
        sa.Column("session_seconds", sa.Integer(), nullable=False),
        sa.Column("active_seconds", sa.Integer(), nullable=False),
        sa.Column("idle_seconds", sa.Integer(), nullable=False),
        sa.Column("first_active_at", UTCDateTime(), nullable=True),
        sa.Column("last_active_at", UTCDateTime(), nullable=True),
        sa.Column("updated_at", UTCDateTime(), nullable=False),
        sa.Column("server_received_at", UTCDateTime(), nullable=False),
        sa.Column("change_seq", AutoIncrementBigInt, nullable=True),
        sa.ForeignKeyConstraint(
            ["device_id"], ["devices.id"],
            name=op.f("fk_daily_usage_device_id_devices"), ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"],
            name=op.f("fk_daily_usage_user_id_users"), ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint(
            "user_id", "device_id", "local_day", name=op.f("pk_daily_usage")
        ),
    )
    op.create_index(
        "ix_daily_usage_user_local_day", "daily_usage", ["user_id", "local_day"]
    )
    op.create_index(
        "ix_daily_usage_user_change_seq", "daily_usage", ["user_id", "change_seq"]
    )

    # -------------------------------------------------------- refresh_tokens
    op.create_table(
        "refresh_tokens",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("device_id", sa.Uuid(), nullable=True),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("issued_at", UTCDateTime(), nullable=False),
        sa.Column("expires_at", UTCDateTime(), nullable=False),
        sa.Column("revoked_at", UTCDateTime(), nullable=True),
        sa.Column("replaced_by_id", sa.Uuid(), nullable=True),
        sa.Column("reused_detected_at", UTCDateTime(), nullable=True),
        sa.ForeignKeyConstraint(
            ["device_id"], ["devices.id"],
            name=op.f("fk_refresh_tokens_device_id_devices"), ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"],
            name=op.f("fk_refresh_tokens_user_id_users"), ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_refresh_tokens")),
    )
    op.create_index(
        "ix_refresh_tokens_token_hash", "refresh_tokens", ["token_hash"], unique=True
    )
    op.create_index(
        "ix_refresh_tokens_user_id_revoked_at", "refresh_tokens", ["user_id", "revoked_at"]
    )
    op.create_index("ix_refresh_tokens_device_id", "refresh_tokens", ["device_id"])


def downgrade() -> None:
    op.drop_index("ix_refresh_tokens_device_id", table_name="refresh_tokens")
    op.drop_index("ix_refresh_tokens_user_id_revoked_at", table_name="refresh_tokens")
    op.drop_index("ix_refresh_tokens_token_hash", table_name="refresh_tokens")
    op.drop_table("refresh_tokens")

    op.drop_index("ix_daily_usage_user_change_seq", table_name="daily_usage")
    op.drop_index("ix_daily_usage_user_local_day", table_name="daily_usage")
    op.drop_table("daily_usage")

    op.drop_index("ix_activity_segments_user_app_key", table_name="activity_segments")
    op.drop_index("ix_activity_segments_user_change_seq", table_name="activity_segments")
    op.drop_index("ix_activity_segments_user_device", table_name="activity_segments")
    op.drop_index("ix_activity_segments_user_started", table_name="activity_segments")
    op.drop_table("activity_segments")

    op.drop_index("ix_user_applications_user_change_seq", table_name="user_applications")
    op.drop_table("user_applications")

    op.drop_index("ix_sync_log_user_entity", table_name="sync_log")
    op.drop_index("ix_sync_log_user_seq", table_name="sync_log")
    op.drop_table("sync_log")

    op.drop_index("ix_devices_user_id_revoked_at", table_name="devices")
    op.drop_table("devices")

    op.drop_index("ix_users_email_lower", table_name="users")
    op.drop_table("users")
