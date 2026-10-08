"""应用身份解析：把原始进程名/包名收敛成"统一应用"（Phase 2 核心）。

为什么单独一个模块
------------------
审计发现统计聚合发生在**两层**（见 docs/45 第 1.3 节）：

* ``stats_service``（`/stats/*` 与 MCP 的 `/integrations/stats/*`）
* ``statistics_service``（`/statistics/*`，网页与 App 云端统计）

两层各自聚合、互不复用。如果只给其中一层加归一化，就会出现
"网页显示 1 条微信、MCP 显示 4 条"——这正是 Phase 2 验收项
「MCP 与网页显示相同应用名称」要排除的情况。

因此把解析逻辑集中到本模块，**两层共用同一个实现**，从结构上杜绝再次漂移。

解析优先级（与 docs/45 第三节冻结的规则一致）
--------------------------------------------
1. **用户手动指定的精确映射** —— ``application_aliases``（网页写入，优先级最高）
2. **内置精确映射** —— ``app_normalization`` 的主包名 / 可执行名精确命中
3. **Android 主包名匹配** —— 命中项本身就是主包名
4. **去子进程后缀后匹配** —— 递归剥 ``:push`` / ``:tools`` / ``:service`` …
5. **无法识别** —— 保留原始名，``recognized=False``

``user_applications.display_name`` 始终参与**显示名回退**：
用户在客户端里改过的名字不会被丢弃。

归一化键（``key``）的构成 —— 用**代表性原始键**，不加前缀
--------------------------------------------------------
这是刻意的取舍。``key`` 会作为 ``app_id`` / ``app_key`` 返回给调用方，
而调用方会把它**传回来**做过滤（"查看某应用的会话明细"）：

* 别名命中 → ``str(catalog_id)``（稳定、不与原始名混淆）
* 内置命中 → 内置主包名（如 ``com.tencent.mm``）——
  它同时也是一条**真实存在**的原始名，因此旧调用方直接拿它过滤仍然有效
* 都不中 → 原始名本身（与 Phase 1 完全一致）

若改用 ``builtin:xxx`` 这类前缀，旧调用方（以及我们自己的会话过滤）
会因为"库里没有这个 app_key"而查不到任何记录 —— 这是实测踩到的回归。
另外提供 :meth:`AppIdentityIndex.matching_raw_keys`，
把统一键展开成它包含的全部原始名，供服务端做 ``IN (...)`` 过滤。

**原始记录一行都不改**：本模块纯只读，归一化只影响查询与展示。
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models import ActivitySegment, ApplicationAlias, ApplicationCatalog, UserApplication
from . import app_normalization
from .app_normalization import NormalizedApp

#: 归一化键不再加前缀（见模块文档的说明）：
#: 它必须是"一个真实存在的原始名"，旧调用方才能拿它继续过滤。
#: 下面这些常量只用于**判断**一个键是不是统一应用 id。
CATALOG_PREFIX = "catalog:"
BUILTIN_PREFIX = "builtin:"
RAW_PREFIX = "raw:"


@dataclass(frozen=True)
class ResolvedApp:
    """一个原始名的解析结果。"""

    raw_app_key: str
    #: 归一化分组键（见模块文档）
    key: str
    #: 统一后的显示名
    display_name: str
    category: str
    icon_key: str | None
    #: 命中的统一应用 id；仅当来自用户别名时非空
    catalog_id: uuid.UUID | None
    #: 是否被识别（内置表命中或用户别名命中）
    recognized: bool
    #: 是否发生了归一（子进程后缀被剥离 / 别名命中 / 可执行名映射到包名）
    normalized: bool
    #: 匹配方式：``alias`` / ``builtin`` / ``subprocess`` / ``none``
    matched_by: str

    @property
    def raw_app_keys(self) -> frozenset[str]:
        return frozenset({self.raw_app_key})


@dataclass
class _Group:
    """同一归一化键下累积出的统一应用。"""

    key: str
    display_name: str
    category: str
    icon_key: str | None
    catalog_id: uuid.UUID | None
    recognized: bool
    normalized: bool
    raws: set[str] = field(default_factory=set)
    total_seconds: int = 0
    segment_count: int = 0
    platforms: set[str] = field(default_factory=set)

    def absorb(
        self,
        item: ResolvedApp,
        *,
        seconds: int = 0,
        segments: int = 0,
        platform: str | None = None,
    ) -> None:
        self.raws.add(item.raw_app_key)
        self.total_seconds += seconds
        self.segment_count += segments
        # 只要有一个原始名"看起来就是它自己"，整组就算已经识别
        self.recognized = self.recognized or item.recognized
        if item.normalized:
            self.normalized = True
        if platform:
            self.platforms.add(platform)


class AppIdentityIndex:
    """一次请求内的应用身份索引（带缓存）。

    构造时把该用户的 ``application_aliases`` / ``application_catalog`` /
    ``user_applications`` 一次性读进内存（数据量很小：几十到几百行），
    之后解析纯内存操作。

    **刻意不缓存跨请求**：用户刚在整理界面保存映射，下一次请求就必须生效
    （定稿要求"保存后立即使用统一名称"）。为此每次请求重建索引，
    代价是 3 条小查询，换来"改完即生效"的确定性。
    """

    __slots__ = ("_aliases", "_catalog", "_user_apps")

    def __init__(
        self,
        *,
        aliases: dict[str, ApplicationAlias],
        catalog: dict[uuid.UUID, ApplicationCatalog],
        user_apps: dict[str, UserApplication],
    ) -> None:
        self._aliases = aliases
        self._catalog = catalog
        self._user_apps = user_apps

    # --- 构造 ---

    @classmethod
    def load(cls, db: Session, *, user_id: uuid.UUID) -> "AppIdentityIndex":
        alias_rows = list(
            db.scalars(
                select(ApplicationAlias).where(ApplicationAlias.user_id == user_id)
            )
        )
        catalog_rows = list(
            db.scalars(
                select(ApplicationCatalog).where(ApplicationCatalog.user_id == user_id)
            )
        )
        app_rows = list(
            db.scalars(
                select(UserApplication).where(UserApplication.user_id == user_id)
            )
        )
        return cls(
            # 别名键统一小写比较：Android 包名大小写敏感，但 Windows 可执行名不是，
            # 用户手输时也不该要求大小写完全一致
            aliases={row.raw_app_key.strip().lower(): row for row in alias_rows},
            catalog={row.id: row for row in catalog_rows},
            user_apps={row.app_key: row for row in app_rows},
        )

    # --- 解析 ---

    def resolve(self, raw_app_key: str) -> ResolvedApp:
        raw = (raw_app_key or "").strip() or "unknown"
        lowered = raw.lower()

        builtin_identity = app_normalization.lookup_builtin(raw)
        user_app = self._user_apps.get(raw)

        # ① 用户手动指定的精确映射（最高优先级）
        alias = self._aliases.get(lowered)
        alias_via_family = False

        # ①b 别名也可能建在"内置主包名"上。这一步不能省：
        #     用户把 ``com.tencent.mm`` 归到某个目录后，同一族的
        #     ``com.tencent.mm:tools`` / ``:push`` 必须**一起跟随**，
        #     否则"微信"会被拆成两条（实测踩到过）。
        if alias is None and builtin_identity is not None:
            alias = self._aliases.get(builtin_identity.key.lower())
            alias_via_family = alias is not None

        if alias is not None:
            entry = self._catalog.get(alias.catalog_id)
            if entry is not None:
                return ResolvedApp(
                    raw_app_key=raw,
                    # 用 catalog_id 作统一键：稳定、且不会与任何原始名撞车
                    key=str(entry.id),
                    display_name=entry.display_name,
                    category=entry.category,
                    icon_key=entry.icon_key,
                    catalog_id=entry.id,
                    recognized=True,
                    # 用户显式建立过映射 → 一定属于"被整理过"的应用，
                    # 哪怕原始名与显示名恰好相同
                    normalized=True,
                    matched_by="alias",
                )
            # 目录项被删但别名残留（外键级联应已清理）——降级走内置匹配，
            # 而不是把整条数据丢掉

        if builtin_identity is not None:
            # ②/③/④：内置表命中（含"去子进程后缀后命中"）
            stripped = app_normalization.strip_subprocess_suffix(lowered)
            hit_by_suffix = stripped != lowered and stripped == builtin_identity.key.lower()
            return ResolvedApp(
                raw_app_key=raw,
                # 键取内置主包名：它本身也是一条真实原始名
                key=builtin_identity.key,
                # 显示名优先用该账户应用库里的命名，其次是内置名
                display_name=(
                    user_app.display_name if user_app is not None else builtin_identity.display_name
                ),
                category=(
                    user_app.category if user_app is not None else builtin_identity.category
                ),
                icon_key=_builtin_icon_key(builtin_identity.key),
                catalog_id=None,
                recognized=True,
                normalized=(
                    alias_via_family
                    or hit_by_suffix
                    or lowered != builtin_identity.key.lower()
                ),
                matched_by="subprocess" if hit_by_suffix else "builtin",
            )

        if user_app is not None:
            # 应用库里有记录（客户端认识这个应用，只是不在内置表里）：
            # 沿用客户端的命名与分类，并视为"已识别"—— 与 Phase 1 语义一致，
            # 否则每个应用都会涌进"未识别进程"列表，那个列表就没用了
            return ResolvedApp(
                raw_app_key=raw,
                key=raw,
                display_name=user_app.display_name,
                category=user_app.category,
                icon_key=None,
                catalog_id=None,
                recognized=True,
                normalized=False,
                matched_by="user_library",
            )

        # ⑤ 未识别：保留原始名
        return ResolvedApp(
            raw_app_key=raw,
            key=raw,
            display_name=raw,
            category="other",
            icon_key=None,
            catalog_id=None,
            recognized=False,
            normalized=False,
            matched_by="none",
        )

    # --- 便于复用的辅助 ---

    def resolve_many(self, raw_app_keys) -> dict[str, ResolvedApp]:
        return {raw: self.resolve(raw) for raw in raw_app_keys}

    def matching_raw_keys(self, app_id: str, distinct_raw_keys) -> list[str]:
        """把一个统一键展开成它包含的**全部原始名**。

        用途：前端点「查看会话明细」时传回的是统一键（如 ``com.tencent.mm``），
        但库里存的是原始名（``com.tencent.mm`` / ``com.tencent.mm:tools`` …），
        因此过滤必须用 ``IN (...)`` 而不是等值匹配。

        末尾**总是**把 ``app_id`` 自己也放进结果：这样旧调用方直接传一个原始名
        （哪怕它不是该组的代表键）也仍然能查到记录，保持向后兼容。
        """
        target = (app_id or "").strip()
        if not target:
            return []
        members = [raw for raw in distinct_raw_keys if self.resolve(raw).key == target]
        if target not in members:
            members.append(target)
        return members

    def alias_rows(self) -> list[ApplicationAlias]:
        return list(self._aliases.values())

    def catalog_rows(self) -> list[ApplicationCatalog]:
        return list(self._catalog.values())

    def get_alias(self, raw_app_key: str) -> ApplicationAlias | None:
        return self._aliases.get((raw_app_key or "").strip().lower())

    def get_catalog(self, catalog_id: uuid.UUID) -> ApplicationCatalog | None:
        return self._catalog.get(catalog_id)

    def get_catalog_for_key(self, key: str) -> ApplicationCatalog | None:
        """把一个统一键解析成目录行（没有则返回 None）。

        两种情形：

        * 键就是 ``str(catalog_id)``（用户建过目录行）；
        * 键是内置推导的统一键（如 ``com.tencent.mm``），
          但恰好已经有一条别名把它指向某个目录行 —— 也要认出来，
          否则会重复建一条同名目录。
        """
        parsed = catalog_id_from_key(key, known_ids=set(self._catalog))
        if parsed is not None:
            return self._catalog.get(parsed)
        identity = self.resolve(key)
        if identity.catalog_id is not None:
            return self._catalog.get(identity.catalog_id)
        return None


def _builtin_icon_key(builtin_key: str) -> str:
    """从主包名推导一个稳定的图标标识。

    只给"标识"不给图片：前端把它映射到自己的图标集。
    取主包名的最后一段更有辨识度（``com.tencent.mm`` → ``mm``），
    但对已知的常见应用用更可读的短名。
    """
    special = {
        "com.tencent.mm": "wechat",
        "com.tencent.mobileqq": "qq",
        "com.microsoft.vscode": "vscode",
        "com.android.chrome": "chrome",
        "com.microsoft.emmx": "edge",
        "org.mozilla.firefox": "firefox",
        "com.netease.cloudmusic": "netease-music",
        "com.tencent.qqmusic": "qqmusic",
        "tv.danmaku.bili": "bilibili",
        "com.valvesoftware.android.steam.community": "steam",
        "com.spotify.music": "spotify",
        "com.discord": "discord",
        "org.telegram.messenger": "telegram",
    }
    if builtin_key in special:
        return special[builtin_key]
    tail = builtin_key.rsplit(".", 1)[-1]
    return tail[:32].lower() or "app"


def catalog_id_from_key(key: str, *, known_ids=None) -> uuid.UUID | None:
    """从统一键解析 catalog_id。

    统一键现在就是 ``str(catalog_id)``。``known_ids`` 可选：
    传进来时用它做一次确认，避免把恰好长成 UUID 的原始名误认成目录 id。
    """
    if not key:
        return None
    try:
        parsed = uuid.UUID(key)
    except (ValueError, AttributeError, TypeError):
        return None
    if known_ids is not None and parsed not in known_ids:
        return None
    return parsed


def distinct_raw_app_keys(db: Session, *, user_id: uuid.UUID) -> list[str]:
    """该账户出现过的全部原始 app_key（去重）。

    用于"把统一键展开成原始名"——数据量是"应用个数"级别（几十到几百），
    且有 ``ix_activity_segments_user_app_key`` 覆盖，代价很低。
    """
    rows = db.scalars(
        select(ActivitySegment.app_key)
        .where(ActivitySegment.user_id == user_id)
        .distinct()
    )
    return [row for row in rows if row]


__all__ = [
    "BUILTIN_PREFIX",
    "CATALOG_PREFIX",
    "RAW_PREFIX",
    "AppIdentityIndex",
    "ResolvedApp",
    "catalog_id_from_key",
    "distinct_raw_app_keys",
    "grouping_key_is_catalog",
]
