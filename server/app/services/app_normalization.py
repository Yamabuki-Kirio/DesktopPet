"""应用身份归一化：把原始进程名 / 包名收敛成一个"统一应用"。

为什么需要它
------------
Android 的 `UsageStats` 会上报**带子进程后缀**的包名：

```
com.tencent.mm
com.tencent.mm:push
com.tencent.mm:tools
com.tencent.mm:appbrand0
```

Windows 侧则是可执行名（`WeChat.exe`）。它们本质是同一个应用，
但直接按 ``app_key`` 聚合会得到四个条目、四条进度条，界面无法使用。

归一顺序（严格按定稿第八节，**不可调换**）
----------------------------------------
1. **用户手动指定** —— ``user_applications.user_overridden`` 为真时以用户的命名为准；
2. **完整进程名精确匹配** —— 内置表的 key 与原始名完全一致；
3. **Android 主包名匹配** —— 去掉子进程后缀后命中内置表；
4. **去子进程后缀再匹配** —— ``:push`` / ``:tools`` / ``:service`` / ``:appbrand0`` 等；
   若仍有内层后缀（``a:b:c``）继续剥，直到无 ``:`` 或已命中；
5. **无法识别** —— 保留原始名称，并标记 ``recognized = False``，
   界面据此提示"有 N 个未识别进程，去整理"。

本模块是**纯函数 + 只读**：不写数据库、不建表。
用户可编辑的目录 / 别名（``application_catalog`` / ``application_aliases``）
属于下一个增量（见 docs/43 第五节），届时只需把 :func:`normalize` 的
第 1 步接到新表上，对外字段不用改——``raw_app_keys`` 与 ``recognized``
已经在本阶段的契约里了。
"""

from __future__ import annotations

from dataclasses import dataclass, field

#: Android 子进程分隔符
SUBPROCESS_SEPARATOR = ":"

#: 已知的子进程后缀（小写比较）。仅用于**展示时判断"这是个子进程"**，
#: 真正的剥离逻辑不依赖这张表——它按分隔符递归剥离，
#: 因此 `:some_new_thing` 也能被正确处理，不会因为内置表没收录而漏。
KNOWN_SUBPROCESS_SUFFIXES = frozenset(
    {
        "push",
        "tools",
        "service",
        "appbrand0",
        "appbrand1",
        "appbrand2",
        "remote",
        "worker",
        "sandbox",
        "background",
        "keepalive",
        "daemon",
        "private",
        "wxa",
        "miniapp",
        "player",
        "download",
        "cache",
        "widget",
        "leakcanary",
    }
)


@dataclass(frozen=True)
class AppIdentity:
    """内置身份表的一条：统一应用 + 分类 + 别名集合。"""

    key: str
    display_name: str
    category: str
    #: 除 ``key`` 之外的原始名（Windows 可执行名等）
    aliases: frozenset[str] = field(default_factory=frozenset)


def _build_builtin_table() -> dict[str, AppIdentity]:
    """内置精确映射表。

    键一律**小写**，值里的别名也小写；查询时统一转小写比较。
    这里只收录"高频且确实会产生多个进程名/可执行名"的应用——
    追求覆盖全部应用既不现实也没必要，未识别项由第 5 步兜底并可后续编辑。

    ⚠️ ``category`` **必须**取自 :data:`app.schemas.sync.APP_CATEGORIES`
    （``development`` / ``productivity`` / ``gaming`` / ``social`` /
    ``entertainment`` / ``browser`` / ``system`` / ``other``）。
    客户端同步应用库时该字段会被严格校验，写一个不在集合里的值
    （例如 ``work``）会让上传直接 422 —— 模块底部有断言兜住这一点。
    """
    rows: list[tuple[str, str, str, tuple[str, ...]]] = [
        # --- 腾讯系 ---
        ("com.tencent.mm", "微信", "social", ("wechat.exe", "weixin.exe")),
        ("com.tencent.wechat", "微信", "social", ()),
        ("com.tencent.mobileqq", "QQ", "social", ("qq.exe", "qqprotect.exe")),
        ("com.tencent.mobileqqi", "QQ国际版", "social", ()),
        ("com.tencent.tim", "TIM", "social", ()),
        ("com.tencent.wework", "企业微信", "social", ("wework.exe",)),
        ("com.tencent.qqmusic", "QQ音乐", "entertainment", ("qqmusic.exe",)),
        ("com.tencent.qqlive", "腾讯视频", "entertainment", ()),
        ("com.tencent.news", "腾讯新闻", "entertainment", ()),
        ("com.tencent.qqmail", "QQ邮箱", "productivity", ()),
        ("com.tencent.androidqqmail", "QQ邮箱", "productivity", ()),
        ("com.tencent.mtt", "QQ浏览器", "browser", ("qqbrowser.exe",)),
        ("com.tencent.wemeet", "腾讯会议", "productivity", ("wemeetapp.exe",)),
        ("com.tencent.wemeetapp", "腾讯会议", "productivity", ()),
        ("com.tencent.tmgp.sgame", "王者荣耀", "gaming", ()),
        ("com.tencent.tmgp.pubgmhd", "和平精英", "gaming", ()),
        ("com.tencent.lolm", "英雄联盟手游", "gaming", ()),
        ("com.tencent.gamehelper", "腾讯游戏助手", "gaming", ()),
        # --- 浏览器 ---
        ("com.android.chrome", "Chrome", "browser", ("chrome.exe",)),
        ("com.microsoft.emmx", "Microsoft Edge", "browser", ("msedge.exe",)),
        ("org.mozilla.firefox", "Firefox", "browser", ("firefox.exe",)),
        # --- Google ---
        ("com.google.android.apps.docs", "Google 云端硬盘", "productivity", ()),
        ("com.google.android.gm", "Gmail", "productivity", ()),
        ("com.google.android.youtube", "YouTube", "entertainment", ()),
        ("com.android.vending", "Google Play", "system", ()),
        # --- 微软办公 ---
        ("com.microsoft.office.word", "Word", "productivity", ("winword.exe",)),
        ("com.microsoft.office.excel", "Excel", "productivity", ("excel.exe",)),
        ("com.microsoft.office.powerpoint", "PowerPoint", "productivity", ("powerpnt.exe",)),
        ("com.microsoft.office.outlook", "Outlook", "productivity", ("outlook.exe",)),
        ("com.microsoft.teams", "Teams", "productivity", ("teams.exe",)),
        ("com.microsoft.rdc.android", "远程桌面", "productivity", ("mstsc.exe",)),
        ("com.microsoft.to-do", "Microsoft To Do", "productivity", ()),
        ("com.microsoft.onenote", "OneNote", "productivity", ("onenote.exe",)),
        # --- 影音娱乐 ---
        ("com.netease.cloudmusic", "网易云音乐", "entertainment", ("cloudmusic.exe",)),
        ("com.ximalaya.ting.android", "喜马拉雅", "entertainment", ()),
        ("tv.danmaku.bili", "哔哩哔哩", "entertainment", ()),
        ("com.ss.android.ugc.aweme", "抖音", "entertainment", ()),
        ("com.zhiliaoapp.musically", "TikTok", "entertainment", ()),
        ("com.ss.android.article.news", "今日头条", "entertainment", ()),
        ("com.spotify.music", "Spotify", "entertainment", ("spotify.exe",)),
        # --- 社交 ---
        ("com.sina.weibo", "微博", "social", ()),
        ("com.zhihu.android", "知乎", "social", ()),
        ("com.discord", "Discord", "social", ("discord.exe",)),
        ("org.telegram.messenger", "Telegram", "social", ("telegram.exe",)),
        ("org.telegram.plus", "Telegram", "social", ()),
        ("com.whatsapp", "WhatsApp", "social", ()),
        # --- 购物 / 支付（归到 other，因为分类枚举里没有 shopping / finance）---
        ("com.taobao.taobao", "淘宝", "other", ()),
        ("com.jingdong.app.mall", "京东", "other", ()),
        ("com.eg.android.AlipayGphone", "支付宝", "other", ()),
        # --- 游戏平台 ---
        ("com.valvesoftware.android.steam.community", "Steam", "gaming", ("steam.exe",)),
        ("com.epicgames.portal", "Epic Games", "gaming", ("epicgameslauncher.exe",)),
        # --- 开发 / 工具 ---
        ("com.microsoft.vscode", "Visual Studio Code", "development", ("code.exe",)),
        ("com.github.android", "GitHub", "development", ("githubdesktop.exe",)),
        ("com.openai.chatgpt", "ChatGPT", "productivity", ()),
        ("com.deepseek.chat", "DeepSeek", "productivity", ()),
        # --- 系统 ---
        ("com.google.android.apps.nbu.files", "文件", "system", ()),
        ("com.android.systemui", "系统界面", "system", ()),
        ("com.miui.home", "系统桌面", "system", ()),
        ("com.huawei.android.launcher", "系统桌面", "system", ()),
        ("com.oppo.launcher", "系统桌面", "system", ()),
        ("com.oplus.launcher", "系统桌面", "system", ()),
        ("com.android.settings", "系统设置", "system", ("systemsettings.exe",)),
        ("com.android.shell", "Shell", "system", ()),
        ("com.android.providers.downloads", "下载管理", "system", ()),
    ]

    table: dict[str, AppIdentity] = {}
    for key, display, category, aliases in rows:
        identity = AppIdentity(
            key=key,
            display_name=display,
            category=category,
            aliases=frozenset(a.lower() for a in aliases),
        )
        table[key.lower()] = identity
        # 可执行名 / 别名也要能直接命中（Windows 侧上传的就是它）
        for alias in identity.aliases:
            # 别名不覆盖已有键：主包名优先
            table.setdefault(alias, identity)
    return table


#: 模块级只读表（构建一次）
BUILTIN_TABLE: dict[str, AppIdentity] = _build_builtin_table()


def _assert_categories_are_valid() -> None:
    """护栏：内置表的 category 必须落在客户端的合法枚举内。

    写一个 ``work`` 这类不在集合里的值，后果不是"显示成灰色"那么轻——
    客户端同步 ``user_applications`` 时会被严格校验判 422，
    整个应用库上传失败。所以在导入时就炸掉，而不是等到线上。
    """
    from ..schemas.sync import APP_CATEGORIES

    allowed = set(APP_CATEGORIES)
    bad = {
        identity.category
        for identity in BUILTIN_TABLE.values()
        if identity.category not in allowed
    }
    if bad:
        raise ValueError(
            f"内置应用表的分类 {sorted(bad)} 不在合法枚举 {sorted(allowed)} 内"
        )


_assert_categories_are_valid()


def strip_subprocess_suffix(raw: str) -> str:
    """剥掉 Android 子进程后缀：``com.tencent.mm:tools`` → ``com.tencent.mm``。

    递归剥离（``a:b:c`` → ``a``），因此在 ``:`` 后加了新后缀也不会漏。
    只按分隔符判断，不依赖 :data:`KNOWN_SUBPROCESS_SUFFIXES` 白名单——
    白名单只用来解释"为什么被合并"，不做准入。
    """
    value = (raw or "").strip()
    if SUBPROCESS_SEPARATOR not in value:
        return value
    return value.split(SUBPROCESS_SEPARATOR, 1)[0].strip()


def subprocess_suffixes(raw: str) -> list[str]:
    """列出原始名里的子进程后缀（没有则为空列表）。"""
    value = (raw or "").strip()
    if SUBPROCESS_SEPARATOR not in value:
        return []
    return value.split(SUBPROCESS_SEPARATOR)[1:]


def lookup_builtin(raw: str) -> AppIdentity | None:
    """在内置表里按"精确 → 去后缀"找身份。"""
    value = (raw or "").strip()
    if not value:
        return None
    lowered = value.lower()
    found = BUILTIN_TABLE.get(lowered)
    if found is not None:
        return found
    main = strip_subprocess_suffix(lowered)
    if main and main != lowered:
        return BUILTIN_TABLE.get(main)
    return None


@dataclass(frozen=True)
class NormalizedApp:
    """归一化结果。

    ``raw_app_keys`` 是**可追溯性**的关键：界面点详情时展示
    "原始进程：com.tencent.mm / com.tencent.mm:tools"，
    保证"合并了但没丢失来源"。
    """

    key: str
    display_name: str
    category: str
    recognized: bool
    normalized: bool
    raw_app_keys: frozenset[str] = field(default_factory=frozenset)

    @property
    def merged_raw_count(self) -> int:
        return len(self.raw_app_keys)


def normalize(
    raw: str,
    *,
    override_name: str | None = None,
    override_category: str | None = None,
    override: bool = False,
) -> NormalizedApp:
    """把单个原始名归一化成 :class:`NormalizedApp`。

    :param override_name: ``user_applications.display_name``
    :param override_category: ``user_applications.category``
    :param override: ``user_applications.user_overridden`` 是否为真

    第 1 步（用户手动指定）只在 ``override`` 为真时生效——
    该字段的语义就是"用户改过，别用内置值覆盖"（见 ``UserApplication`` 注释）。
    """
    value = (raw or "").strip() or "unknown"
    builtin = lookup_builtin(value)

    if override and override_name:
        return NormalizedApp(
            key=value,
            display_name=override_name.strip(),
            category=(override_category or (builtin.category if builtin else "other")),
            recognized=True,
            normalized=bool(builtin) or strip_subprocess_suffix(value) != value,
            raw_app_keys=frozenset({value}),
        )

    if builtin is not None:
        return NormalizedApp(
            key=builtin.key,
            display_name=builtin.display_name,
            category=override_category or builtin.category,
            recognized=True,
            normalized=value.lower() != builtin.key.lower(),
            raw_app_keys=frozenset({value}),
        )

    # 未识别：保留原始名称，标记出来交给"去整理"
    return NormalizedApp(
        key=value,
        display_name=override_name.strip() if override_name else value,
        category=override_category or "other",
        recognized=False,
        normalized=False,
        raw_app_keys=frozenset({value}),
    )


def merge(entries: list[NormalizedApp]) -> NormalizedApp:
    """把同一个统一应用的多个结果合并成一条（收集全部原始名）。"""
    if not entries:
        raise ValueError("merge() 需要至少一个条目")
    head = entries[0]
    raws: set[str] = set()
    for item in entries:
        raws |= item.raw_app_keys
    return NormalizedApp(
        key=head.key,
        display_name=head.display_name,
        category=head.category,
        recognized=all(e.recognized for e in entries),
        normalized=any(e.normalized for e in entries),
        raw_app_keys=frozenset(raws),
    )


def explain(raw: str) -> dict[str, object]:
    """给出"为什么归到这个应用"的说明（界面上的可追溯信息）。

    这是"评分/结论必须能解释"的同一条原则在应用归一化上的应用：
    用户看到"微信 3 小时"时，应该能查到这 3 小时由哪几个进程名组成。
    """
    value = (raw or "").strip() or "unknown"
    suffixes = subprocess_suffixes(value)
    builtin = lookup_builtin(value)
    if builtin is None:
        return {
            "raw_app_key": value,
            "matched": False,
            "reason": "内置表未收录，保留原始名称",
            "subprocess_suffixes": suffixes,
        }
    if value.lower() == builtin.key.lower():
        reason = "主包名精确匹配"
    elif value.lower() in builtin.aliases:
        reason = "可执行名 / 别名精确匹配"
    else:
        reason = f"去除子进程后缀后匹配（{':'.join(suffixes)}）"
    return {
        "raw_app_key": value,
        "matched": True,
        "unified_key": builtin.key,
        "display_name": builtin.display_name,
        "category": builtin.category,
        "reason": reason,
        "subprocess_suffixes": suffixes,
    }


__all__ = [
    "BUILTIN_TABLE",
    "KNOWN_SUBPROCESS_SUFFIXES",
    "SUBPROCESS_SEPARATOR",
    "AppIdentity",
    "NormalizedApp",
    "explain",
    "lookup_builtin",
    "merge",
    "normalize",
    "strip_subprocess_suffix",
    "subprocess_suffixes",
]
