"""应用身份模型：统一应用目录 + 原始名别名。

背景（见 docs/45 第一节审计结论）
--------------------------------
手机上报的包名会带子进程后缀：

```
com.tencent.mm
com.tencent.mm:push
com.tencent.mm:tools
com.tencent.mm:appbrand0
```

Windows 侧则是可执行名（``WeChat.exe``）。它们本质是同一个应用，
但按原始 ``app_key`` 聚合会得到 4 条记录，界面无法使用。

为什么不复用 ``UserApplication``
-------------------------------
``user_applications`` 的主键是**原始 app_key**，天然表达不了
"一个统一应用对应多个原始名"，也没有 ``icon_key``。更关键的是：
它由**客户端同步推送**，冲突策略是"两边都是人工分类时按 updated_at 较新者胜"
（见 ``sync_service._push_application``）——如果网页把用户的合并结果写进去，
客户端之后推一条更新的记录就能把它覆盖掉。

因此这里另建两张表：网页的映射落在**客户端同步碰不到的地方**，
同步协议与旧客户端因此完全不受影响。

隐私
----
只存应用名/包名/可执行名与分类，**没有任何窗口标题、URL、文档名或本地路径**。
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import ForeignKey, Index, Integer, String, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..core.timeutil import utcnow
from ..core.types import UTCDateTime
from ..database.base import Base

#: 目录项来源：内置表推导出来的 / 用户手工新建的
CATALOG_SOURCE_BUILTIN = "builtin"
CATALOG_SOURCE_USER = "user"
CATALOG_SOURCES = (CATALOG_SOURCE_BUILTIN, CATALOG_SOURCE_USER)

#: 别名匹配方式
MATCH_TYPE_MANUAL = "manual"        # 用户手工指定（优先级最高）
MATCH_TYPE_SUBPROCESS = "subprocess"  # 去除子进程后缀后匹配
MATCH_TYPE_EXACT = "exact"          # 精确匹配
MATCH_TYPES = (MATCH_TYPE_MANUAL, MATCH_TYPE_SUBPROCESS, MATCH_TYPE_EXACT)

#: 手工映射的默认优先级（数字越小越优先）
DEFAULT_ALIAS_PRIORITY = 100


class ApplicationCatalog(Base):
    """一个"统一应用"：微信 / Visual Studio Code / ...

    ``(user_id, display_name)`` 唯一：同一账户下不允许出现两个同名统一应用，
    否则用户在整理界面里无法分辨该把进程合并到哪一个。
    """

    __tablename__ = "application_catalog"
    __table_args__ = (
        UniqueConstraint(
            "user_id", "display_name", name="uq_application_catalog_user_display_name"
        ),
        Index("ix_application_catalog_user_id", "user_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )

    display_name: Mapped[str] = mapped_column(String(128), nullable=False)
    #: 取值必须落在 app.schemas.sync.APP_CATEGORIES 内（服务层校验）
    category: Mapped[str] = mapped_column(String(32), nullable=False, default="other")
    #: 图标标识（如 ``wechat``）。**只存标识不存图片**，避免把二进制塞进数据库。
    icon_key: Mapped[str | None] = mapped_column(String(64), nullable=True)

    source: Mapped[str] = mapped_column(
        String(16), nullable=False, default=CATALOG_SOURCE_USER
    )

    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )
    updated_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )

    aliases: Mapped[list["ApplicationAlias"]] = relationship(
        back_populates="catalog",
        cascade="all, delete-orphan",
        order_by="ApplicationAlias.raw_app_key",
    )

    def __repr__(self) -> str:  # pragma: no cover
        return f"<ApplicationCatalog {self.display_name} user={self.user_id}>"


class ApplicationAlias(Base):
    """原始名 → 统一应用 的映射。

    ``(user_id, raw_app_key)`` 唯一 —— 一个原始名在同一账户下**只能**指向一个
    统一应用。这条约束让"合并到已有应用"的语义无歧义，也天然杜绝重复映射；
    同时它是**用户隔离**的结构保证：所有查询都带 ``user_id``。
    """

    __tablename__ = "application_aliases"
    __table_args__ = (
        UniqueConstraint(
            "user_id", "raw_app_key", name="uq_application_aliases_user_raw_key"
        ),
        Index("ix_application_aliases_user_raw_key", "user_id", "raw_app_key"),
        Index("ix_application_aliases_catalog_id", "catalog_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    catalog_id: Mapped[uuid.UUID] = mapped_column(
        Uuid,
        ForeignKey("application_catalog.id", ondelete="CASCADE"),
        nullable=False,
    )

    #: 原始进程名 / 包名，例如 ``com.tencent.mm:tools``、``WeChat.exe``
    raw_app_key: Mapped[str] = mapped_column(String(128), nullable=False)
    #: windows / android / NULL = 不限平台
    platform: Mapped[str | None] = mapped_column(String(32), nullable=True)

    match_type: Mapped[str] = mapped_column(
        String(16), nullable=False, default=MATCH_TYPE_MANUAL
    )
    priority: Mapped[int] = mapped_column(
        Integer, nullable=False, default=DEFAULT_ALIAS_PRIORITY
    )

    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )
    updated_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )

    catalog: Mapped[ApplicationCatalog] = relationship(back_populates="aliases")

    def __repr__(self) -> str:  # pragma: no cover
        return f"<ApplicationAlias {self.raw_app_key} -> {self.catalog_id}>"


__all__ = [
    "CATALOG_SOURCES",
    "CATALOG_SOURCE_BUILTIN",
    "CATALOG_SOURCE_USER",
    "DEFAULT_ALIAS_PRIORITY",
    "MATCH_TYPES",
    "MATCH_TYPE_EXACT",
    "MATCH_TYPE_MANUAL",
    "MATCH_TYPE_SUBPROCESS",
    "ApplicationAlias",
    "ApplicationCatalog",
]
