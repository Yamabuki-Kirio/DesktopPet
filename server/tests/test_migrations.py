"""Alembic 迁移：真实执行 + 与模型声明的一致性校验。

为什么要有这个文件
------------------
其余用例都用 ``Base.metadata.create_all`` 建表（快）。如果只靠它，
"模型改了但迁移没跟上" 这类事故就会完全漏掉——而这种事故在生产上是致命的
（新库正常、老库升级后缺列）。因此这里**真的跑一遍 Alembic**，
并逐项比对迁移结果与模型声明。
"""

from __future__ import annotations

import io
from contextlib import redirect_stdout

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import inspect

from app.core.config import reset_settings_cache
from app.database.base import Base
from app.database.session import build_engine

from .conftest import SERVER_ROOT

EXPECTED_TABLES = {
    "users",
    "devices",
    "refresh_tokens",
    "activity_segments",
    "daily_usage",
    "user_applications",
    "sync_log",
    # Phase 3（Telegram / MCP 集成）
    "integration_link_codes",
    "telegram_bindings",
    # Phase 3（改版：个人访问密钥）
    "api_keys",
    # Phase 2（应用身份管理：统一应用目录 + 原始名别名）
    "application_catalog",
    "application_aliases",
}

#: 绝不允许出现在任何表里的隐私字段名（子串匹配）
BANNED_COLUMN_FRAGMENTS = (
    "window_title",
    "title",
    "url",
    "document_name",
    "doc_name",
    "file_path",
    "executable_path",
    "screenshot",
    "clipboard",
    "keystroke",
)


def _alembic_config() -> Config:
    cfg = Config(str(SERVER_ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(SERVER_ROOT / "migrations"))
    return cfg


def _upgrade(url: str, monkeypatch, *, revision: str = "head") -> None:
    monkeypatch.setenv("PETLIFE_DATABASE_URL", url)
    reset_settings_cache()
    command.upgrade(_alembic_config(), revision)


def _inspect_schema(url: str):
    engine = build_engine(url)
    try:
        return inspect(engine)
    finally:
        engine.dispose()


def test_upgrade_head_creates_exactly_the_model_tables(tmp_path, monkeypatch):
    url = f"sqlite+pysqlite:///{tmp_path / 'migrated.db'}"
    _upgrade(url, monkeypatch)

    inspector = _inspect_schema(url)
    migrated = set(inspector.get_table_names()) - {"alembic_version"}
    assert migrated == EXPECTED_TABLES
    assert migrated == set(Base.metadata.tables), "迁移与模型声明的表集合必须一致"


def test_migrated_columns_match_models(tmp_path, monkeypatch):
    url = f"sqlite+pysqlite:///{tmp_path / 'columns.db'}"
    _upgrade(url, monkeypatch)
    inspector = _inspect_schema(url)

    for name, table in Base.metadata.tables.items():
        migrated_columns = {c["name"] for c in inspector.get_columns(name)}
        assert migrated_columns == {c.name for c in table.columns}, (
            f"表 {name} 的列与模型不一致"
        )


def test_migrated_primary_keys_match_models(tmp_path, monkeypatch):
    url = f"sqlite+pysqlite:///{tmp_path / 'pk.db'}"
    _upgrade(url, monkeypatch)
    inspector = _inspect_schema(url)

    for name, table in Base.metadata.tables.items():
        migrated_pk = set(inspector.get_pk_constraint(name)["constrained_columns"] or [])
        assert migrated_pk == {c.name for c in table.primary_key.columns}, (
            f"表 {name} 的主键与模型不一致"
        )


def test_activity_and_daily_tables_include_user_id_in_primary_key(tmp_path, monkeypatch):
    """结构层面的隔离保证：主键必须含 user_id。"""
    url = f"sqlite+pysqlite:///{tmp_path / 'isolation.db'}"
    _upgrade(url, monkeypatch)
    inspector = _inspect_schema(url)

    activity_pk = set(inspector.get_pk_constraint("activity_segments")["constrained_columns"])
    assert {"user_id", "id"} <= activity_pk

    daily_pk = set(inspector.get_pk_constraint("daily_usage")["constrained_columns"])
    assert {"user_id", "device_id", "local_day"} <= daily_pk

    apps_pk = set(inspector.get_pk_constraint("user_applications")["constrained_columns"])
    assert {"user_id", "app_key"} <= apps_pk


def test_migrated_foreign_keys_match_models(tmp_path, monkeypatch):
    url = f"sqlite+pysqlite:///{tmp_path / 'fk.db'}"
    _upgrade(url, monkeypatch)
    inspector = _inspect_schema(url)

    for name, table in Base.metadata.tables.items():
        migrated = {
            (tuple(sorted(fk["constrained_columns"])), fk["referred_table"])
            for fk in inspector.get_foreign_keys(name)
        }
        declared = {
            (tuple(sorted(c.name for c in fk.columns)), fk.referred_table.name)
            for fk in table.foreign_key_constraints
        }
        assert migrated == declared, f"表 {name} 的外键与模型不一致"


def test_migrated_indexes_match_models(tmp_path, monkeypatch):
    url = f"sqlite+pysqlite:///{tmp_path / 'idx.db'}"
    _upgrade(url, monkeypatch)
    inspector = _inspect_schema(url)

    for name, table in Base.metadata.tables.items():
        migrated = {
            (tuple(idx["column_names"]), bool(idx["unique"]))
            for idx in inspector.get_indexes(name)
        }
        declared = {
            (tuple(c.name for c in idx.columns), bool(idx.unique)) for idx in table.indexes
        }
        assert migrated == declared, f"表 {name} 的索引与模型不一致"


def test_migrated_schema_contains_no_privacy_columns(tmp_path, monkeypatch):
    """迁移建出的表里不得出现标题 / URL / 本地路径之类字段。"""
    url = f"sqlite+pysqlite:///{tmp_path / 'privacy.db'}"
    _upgrade(url, monkeypatch)
    inspector = _inspect_schema(url)

    offenders: list[str] = []
    for table in EXPECTED_TABLES:
        for column in inspector.get_columns(table):
            lowered = column["name"].lower()
            for fragment in BANNED_COLUMN_FRAGMENTS:
                if fragment in lowered:
                    offenders.append(f"{table}.{column['name']} (~{fragment})")
    assert offenders == [], f"发现疑似隐私字段：{offenders}"


def test_downgrade_then_upgrade_round_trip(tmp_path, monkeypatch):
    """降级必须干净地删掉自己建的表，再升级能原样恢复。"""
    url = f"sqlite+pysqlite:///{tmp_path / 'roundtrip.db'}"
    cfg = _alembic_config()
    monkeypatch.setenv("PETLIFE_DATABASE_URL", url)
    reset_settings_cache()

    command.upgrade(cfg, "head")
    command.downgrade(cfg, "base")

    inspector = _inspect_schema(url)
    remaining = set(inspector.get_table_names()) - {"alembic_version"}
    assert remaining == set(), f"降级后仍残留表：{remaining}"

    command.upgrade(cfg, "head")
    inspector = _inspect_schema(url)
    assert set(inspector.get_table_names()) - {"alembic_version"} == EXPECTED_TABLES


def test_postgresql_ddl_is_generated_with_native_types(tmp_path, monkeypatch):
    """离线生成 PostgreSQL DDL 并检查关键类型。

    这里**不需要**真实 PostgreSQL：``--sql`` 离线模式只编译 DDL。
    它能真实验出「UUID 变成 TEXT」「自增主键没生成 BIGSERIAL」这类方言问题。
    """
    cfg = _alembic_config()

    class _Opts:
        x = ["db_url=postgresql+psycopg2://user:pw@localhost:5432/petlife"]

    cfg.cmd_opts = _Opts()  # type: ignore[assignment]

    buffer = io.StringIO()
    with redirect_stdout(buffer):
        command.upgrade(cfg, "head", sql=True)
    ddl = buffer.getvalue()

    assert "CREATE TABLE users" in ddl
    assert "UUID NOT NULL" in ddl, "UUID 列应映射为原生 UUID 类型"
    assert "BIGSERIAL" in ddl, "sync_log.seq 应为 BIGSERIAL 自增主键"
    assert "PRIMARY KEY (user_id, id)" in ddl, "活动段主键必须含 user_id"
    for table in EXPECTED_TABLES:
        assert f"CREATE TABLE {table}" in ddl, f"PG DDL 缺少表 {table}"


def test_alembic_ini_is_ascii_only():
    """alembic.ini 必须保持纯 ASCII。

    configparser 用 ``encoding="locale"`` 读它；在 zh-CN 机器上 locale 是 GBK，
    混入中文注释会让**所有** alembic 命令在建连之前就崩掉。
    """
    content = (SERVER_ROOT / "alembic.ini").read_bytes()
    non_ascii = [b for b in content if b > 127]
    assert non_ascii == [], f"alembic.ini 含 {len(non_ascii)} 个非 ASCII 字节"
