"""应用配置。

安全约定
--------
* 所有机密（JWT 密钥、数据库口令）**只从环境变量或 .env 读取**，绝不写进代码库。
* `PETLIFE_JWT_SECRET` 没有默认值：缺失时应用直接启动失败，而不是退化成一个
  可预测的弱密钥（这是最常见的自酿事故）。
* `.env` 已在 `.gitignore` 中排除；仓库里只提供 `.env.example`。
"""

from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """从环境变量（前缀 ``PETLIFE_``）加载的运行时配置。"""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        env_prefix="PETLIFE_",
        extra="ignore",
    )

    # --- 基础 ---
    app_name: str = "PetLife API"
    environment: str = "development"

    # --- 数据库 ---
    # 开发默认用 SQLite，方便无 PostgreSQL 的环境；生产走 PostgreSQL。
    database_url: str = "sqlite+pysqlite:///./petlife_server_dev.db"
    database_echo: bool = False

    # --- JWT ---
    jwt_secret: str = Field(..., min_length=16)
    jwt_algorithm: str = "HS256"
    access_token_ttl_minutes: int = 15
    refresh_token_ttl_days: int = 30
    jwt_issuer: str = "petlife"

    # --- 密码哈希（Argon2id）---
    argon2_time_cost: int = 3
    argon2_memory_cost: int = 65536
    argon2_parallelism: int = 4

    # --- 同步 ---
    sync_max_batch_size: int = 200
    sync_pull_max_items: int = 500

    # --- Phase 3：集成（Telegram / MCP）---
    #: 集成服务令牌：MCP Server / AstrBot 用它调用集成接口。
    #: **不复用用户密码**，也永远不下发给 AI。
    #: 留空表示服务端未启用集成接口（调用一律 401），而不是"无鉴权放行"。
    integration_token: str = ""
    #: 一次性绑定码有效期（分钟）
    link_code_ttl_minutes: int = 10
    #: 集成接口的 MCP 侧单次返回条数上限
    integration_max_items: int = 50

    # --- Web Session（GameLog「生活足迹」网页专用，见 docs/43）---
    #: 网页会话 Cookie 是否带 ``Secure``。
    #: 生产（HTTPS）必须为 True；本地 / 自签环境用 http 调试时需显式设为 false，
    #: 否则浏览器（与 httpx 测试客户端）不会回传 Cookie，登录会"看起来成功但其实没生效"。
    web_session_cookie_secure: bool = True
    #: 网页会话的 Access Token 有效期（分钟）。与客户端令牌分开配置：
    #: 网页是长驻标签页，默认比客户端的 15 分钟长一些，减少静默刷新次数。
    web_session_access_ttl_minutes: int = 30
    #: 会话凭据 Cookie 的 ``Path``。
    #:
    #: 这是**部署事实**而不是代码常量：浏览器只回传路径匹配当前请求的 Cookie，
    #: 而生产上反向代理会把 ``/petlife-api/`` 剥掉后再转发给容器
    #: （Nginx ``proxy_pass http://127.0.0.1:8000/``）。后端发出的
    #: ``Set-Cookie`` 会被原样透传，因此这里的值必须与**浏览器看到的前缀**一致，
    #: 否则登录成功后所有后续请求都不带 Cookie（表现为"登录成功但一直未登录"）。
    #: 若把服务直接挂在域名根下，改成 ``/`` 即可。
    web_session_cookie_path: str = "/petlife-api/"

    @field_validator("web_session_cookie_path")
    @classmethod
    def _normalize_cookie_path(cls, value: str) -> str:
        """Cookie ``Path`` 必须以 ``/`` 开头；根路径之外的写法一律补上尾斜杠。

        写错的后果很隐蔽：``Path=/petlife-api``（没尾斜杠）在 RFC 6265 的
        路径匹配下**不会**匹配 ``/petlife-api/api/v1/...``，浏览器就不会回传 Cookie。
        在这里直接规范化，避免部署时踩这种坑。
        """
        path = value.strip() or "/"
        if not path.startswith("/"):
            path = "/" + path
        if path != "/" and not path.endswith("/"):
            path += "/"
        return path

    @field_validator("jwt_secret")
    @classmethod
    def _reject_placeholder_secret(cls, value: str) -> str:
        """拒绝示例文件里的占位密钥，避免把 .env.example 直接拿去部署。"""
        banned = {
            "change-me",
            "changeme",
            "secret",
            "please-change-this-secret",
            "your-secret-here",
        }
        if value.strip().lower() in banned:
            raise ValueError(
                "PETLIFE_JWT_SECRET 仍是占位值，请生成一个真实随机密钥："
                "python -c \"import secrets;print(secrets.token_urlsafe(48))\""
            )
        return value

    @property
    def is_production(self) -> bool:
        return self.environment.lower() in {"production", "prod"}

    @property
    def is_sqlite(self) -> bool:
        return self.database_url.startswith("sqlite")


@lru_cache
def get_settings() -> Settings:
    """进程内单例配置。

    用惰性函数而不是模块级常量，是为了让测试可以在导入应用之前设置环境变量，
    也避免「导入即读环境」导致的测试顺序耦合。
    """
    return Settings()  # type: ignore[call-arg]


def reset_settings_cache() -> None:
    """清空配置缓存（仅供测试使用）。"""
    get_settings.cache_clear()
