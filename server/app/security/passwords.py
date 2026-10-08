"""Argon2id 密码哈希。

需求指定 Argon2id。参数从配置读取，便于按机器性能调整；
默认值（time=3, memory=64MiB, parallelism=4）是 OWASP 推荐档位附近的值。

约定：
* 哈希字符串自带算法与参数（argon2 编码），因此将来调参不会让旧密码失效；
* 明文密码**绝不进日志**（``redact`` 是兜底，业务代码里也不主动记录）。
"""

from __future__ import annotations

from argon2 import PasswordHasher
from argon2 import exceptions as argon2_errors
from argon2.low_level import Type

_hasher: PasswordHasher | None = None


def configure(
    *,
    time_cost: int = 3,
    memory_cost: int = 65536,
    parallelism: int = 4,
) -> PasswordHasher:
    """初始化（或重建）哈希器。"""
    global _hasher
    _hasher = PasswordHasher(
        time_cost=time_cost,
        memory_cost=memory_cost,
        parallelism=parallelism,
        hash_len=32,
        salt_len=16,
        type=Type.ID,  # Argon2id
    )
    return _hasher


def get_hasher() -> PasswordHasher:
    if _hasher is None:
        return configure()
    return _hasher


def hash_password(password: str) -> str:
    return get_hasher().hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    """校验密码；任何异常都当作"不匹配"，绝不向上抛。"""
    try:
        return get_hasher().verify(password_hash, password)
    except (argon2_errors.VerifyMismatchError, argon2_errors.VerificationError):
        return False
    except Exception:
        return False


def needs_rehash(password_hash: str) -> bool:
    """参数已升级时提示调用方重新哈希（登录成功后顺带升级）。"""
    try:
        return get_hasher().check_needs_rehash(password_hash)
    except Exception:
        return False
