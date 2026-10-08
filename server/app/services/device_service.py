"""设备服务。

设计要点
--------
* 同一用户下 ``device_local_id`` 唯一；登录后「注册或更新」由这一个方法承担，
  客户端不需要区分"首次绑定"和"再次上线"。
* 撤销设备时：
  1. 标记 ``revoked_at``；
  2. 吊销该设备的全部 Refresh Token；
  3. 把 ``device_local_id`` 改名加上墓碑后缀，**释放原 ID**，
     这样用户在重装 / 重新登录后可以重新绑定同一台机器，
     而不是被历史撤销记录永久挡住。
* 隐私：只存客户端自报的元数据，**绝不采集硬件序列号 / MAC / 其他硬件指纹**。
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..core.errors import ApiError, ErrorCode
from ..core.logger import get_logger
from ..core.timeutil import utcnow
from ..models import Device, User
from . import auth_service

logger = get_logger(__name__)

REVOKED_SUFFIX_SEPARATOR = "#revoked:"


def _tombstone_local_id(local_id: str) -> str:
    """给被撤销的 device_local_id 加墓碑后缀，长度受 column(64) 限制。"""
    suffix = uuid.uuid4().hex[:8]
    keep = 64 - len(REVOKED_SUFFIX_SEPARATOR) - len(suffix)
    return f"{local_id[:keep]}{REVOKED_SUFFIX_SEPARATOR}{suffix}"


def register_or_update(
    db: Session,
    *,
    user: User,
    device_local_id: str,
    device_name: str,
    platform: str = "windows",
    architecture: str = "x64",
    os_version: str | None = None,
    app_version: str | None = None,
    model_name: str | None = None,
) -> Device:
    """登录后绑定设备（已存在则更新元数据与 last_seen_at）。"""
    now = utcnow()
    local_id = device_local_id.strip()

    device = db.scalar(
        select(Device).where(
            Device.user_id == user.id, Device.device_local_id == local_id
        )
    )
    if device is not None:
        device.device_name = device_name.strip()
        device.platform = platform
        device.architecture = architecture
        device.os_version = os_version
        device.app_version = app_version
        # model_name 由用户填写，客户端上报不得覆盖用户的备注：只在为空时填充
        if model_name is not None and not device.model_name:
            device.model_name = model_name
        device.last_seen_at = now
        db.commit()
        db.refresh(device)
        return device

    device = Device(
        user_id=user.id,
        device_local_id=local_id,
        device_name=device_name.strip(),
        platform=platform,
        architecture=architecture,
        os_version=os_version,
        app_version=app_version,
        model_name=model_name,
        last_seen_at=now,
        created_at=now,
    )
    db.add(device)
    try:
        db.commit()
    except IntegrityError as exc:
        # 并发注册同一台设备：唯一约束兜底，退化为更新
        db.rollback()
        existing = db.scalar(
            select(Device).where(
                Device.user_id == user.id, Device.device_local_id == local_id
            )
        )
        if existing is None:
            raise ApiError(ErrorCode.conflict, "设备注册冲突，请重试") from exc
        existing.last_seen_at = now
        db.commit()
        db.refresh(existing)
        return existing
    db.refresh(device)
    logger.info("设备已绑定 user_id=%s device=%s", user.id, device.id)
    return device


def list_devices(db: Session, *, user: User) -> list[Device]:
    """列出该用户的设备（含已撤销，按最近活跃倒序）。"""
    return list(
        db.scalars(
            select(Device)
            .where(Device.user_id == user.id)
            .order_by(Device.last_seen_at.desc())
        )
    )


def get_owned_device(db: Session, *, user: User, device_id: uuid.UUID) -> Device:
    device = db.scalar(
        select(Device).where(Device.id == device_id, Device.user_id == user.id)
    )
    if device is None:
        raise ApiError(ErrorCode.device_not_found, "设备不存在或不属于当前账户")
    return device


def update_device(
    db: Session,
    *,
    user: User,
    device_id: uuid.UUID,
    device_name: str | None = None,
    model_name: str | None = None,
) -> Device:
    """修改设备名称 / 型号备注。"""
    device = get_owned_device(db, user=user, device_id=device_id)
    if device.revoked_at is not None:
        raise ApiError(ErrorCode.device_revoked, "该设备已撤销，无法修改")

    if device_name is not None:
        device.device_name = device_name.strip()
    if model_name is not None:
        device.model_name = model_name.strip()
    db.commit()
    db.refresh(device)
    return device


def revoke_device(db: Session, *, user: User, device_id: uuid.UUID) -> tuple[Device, int]:
    """撤销设备：吊销其令牌、释放 device_local_id，返回 (设备, 吊销会话数)。"""
    device = get_owned_device(db, user=user, device_id=device_id)
    if device.revoked_at is not None:
        # 幂等：重复撤销不报错，也不重复计数
        return device, 0

    now = utcnow()
    revoked_count = auth_service.revoke_device_tokens(
        db, device_id=device.id, commit=False
    )
    device.revoked_at = now
    device.device_local_id = _tombstone_local_id(device.device_local_id)
    db.commit()
    db.refresh(device)
    logger.info(
        "设备已撤销 user_id=%s device=%s sessions=%s", user.id, device.id, revoked_count
    )
    return device, revoked_count
