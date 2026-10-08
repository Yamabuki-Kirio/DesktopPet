"""PetLife MCP Server（Phase 3）。

设计定位
--------
本包是**纯 HTTP 客户端**：它只持有**个人访问密钥**（``PETLIFE_API_KEY``），
通过 PetLife API 读数据，**不持有任何数据库连接信息**（没有
``PETLIFE_DATABASE_URL``、没有 PostgreSQL 口令），也不提供任何"执行 SQL"的工具。
这一点是需求「二、总体架构」明确要求的：
``Telegram AI → PostgreSQL`` 这条路必须不存在。

身份从哪里来
------------
身份 = **密钥本身**。密钥由用户在 Windows 客户端「AI 数据访问」里生成
（``plk_...``），服务端按 SHA-256 哈希查出它属于哪个账户。

因此：

* 工具参数里**没有** ``user_id`` / Telegram ID / API Key；
* HTTP 请求头与环境变量里**也没有**动态注入的身份
  （旧版的 ``X-PetLife-Telegram-User-Id`` / ``PETLIFE_TELEGRAM_USER_ID`` 已删除）；
* 模型既看不到、也改不了"查哪个用户"，撤销密钥即立刻断掉这条链路。
"""

from __future__ import annotations

__all__: list[str] = []
