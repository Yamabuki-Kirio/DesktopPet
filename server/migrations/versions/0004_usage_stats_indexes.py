"""Phase 4B: usage statistics query indexes

Phase 4B 让手机端（以及 MCP）可以按**设备 + 日期**查询电脑的逐条使用会话。
统计查询的形状是：

* 某设备某一天的全部会话 → ``WHERE user_id AND device_id AND started_at < to AND (ended_at IS NULL OR ended_at > from)``
* 某设备某一天某个应用的全部会话 → 同上再加 ``app_key``

``activity_segments`` 原有的 4 条索引（``user_id`` 开头的单列/双列组合）都不能
同时覆盖 ``device_id`` 与 ``started_at``，因此这里补两条组合索引。

**刻意不做的事**（避免破坏已部署的数据）：

* 不新建"原始会话"表 —— 现有的 ``activity_segments`` 已经是逐条会话表，
  且 ``(user_id, id)``（``id`` 即客户端的稳定 ``local_record_id``）已经提供
  幂等 upsert 语义；再建一张表就等于第二套同步体系。
* 不加字段、不改主键、不动任何既有列 —— 因此本迁移对生产数据完全无损，
  ``downgrade`` 只删这两条索引。

Revision ID: 0004_usage_stats_indexes
Revises: 0003_api_keys
Create Date: 2026-09-29
"""

from __future__ import annotations

from typing import Sequence

from alembic import op

revision: str = "0004_usage_stats_indexes"
down_revision: str | None = "0003_api_keys"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

#: 与 ``app/models/activity.py`` 中 ActivitySegment.__table_args__ 必须逐字一致，
#: 否则 tests/test_migrations.py 的"索引与模型一致"断言会失败。
_DEVICE_STARTED = "ix_activity_segments_user_device_started"
_DEVICE_APP_STARTED = "ix_activity_segments_user_device_app_started"


def upgrade() -> None:
    op.create_index(
        _DEVICE_STARTED,
        "activity_segments",
        ["user_id", "device_id", "started_at"],
    )
    op.create_index(
        _DEVICE_APP_STARTED,
        "activity_segments",
        ["user_id", "device_id", "app_key", "started_at"],
    )


def downgrade() -> None:
    op.drop_index(_DEVICE_APP_STARTED, table_name="activity_segments")
    op.drop_index(_DEVICE_STARTED, table_name="activity_segments")
