"""跨端云端统计一致性诊断（Phase 4C-5.1B 补充修复）。

用途：直接对着**服务端数据库**回答排查清单里的第 2、3 条：

* 当前账户下的所有设备（服务端 UUID / device_local_id / 名称 / 平台 / 最近活动）；
* 指定某一天各设备实际保存的 segment 数量、总秒数、最早与最晚开始时间；
* 识别"同一物理设备分叉成多行"的迹象（同名同平台、但 id 不同）。

只读：脚本**不做任何写操作**，可以安全地在生产库上运行。

用法（在 `petlife/server` 目录下）：

    .python\\python.exe tools\\diagnose_cloud_consistency.py
    .python\\python.exe tools\\diagnose_cloud_consistency.py --date 2026-09-30
    .python\\python.exe tools\\diagnose_cloud_consistency.py --email me@example.com
    .python\\python.exe tools\\diagnose_cloud_consistency.py --database-url sqlite+pysqlite:///./petlife_server_dev.db

默认读取 `.env` 里的 `PETLIFE_DATABASE_URL`；默认日期是"本机今天"。
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parent.parent
if str(SERVER_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_ROOT))


def _load_database_url(explicit: str | None) -> str:
    if explicit:
        return explicit
    try:
        from app.core.config import get_settings  # noqa: PLC0415

        return get_settings().database_url
    except Exception:  # pragma: no cover - 仅在配置不可用时走这里
        env_path = SERVER_ROOT / ".env"
        if env_path.is_file():
            for line in env_path.read_text(encoding="utf-8").splitlines():
                if line.startswith("PETLIFE_DATABASE_URL="):
                    return line.split("=", 1)[1].strip()
        raise


def _resolve_sqlite_path(url: str) -> Path | None:
    prefix = "sqlite+pysqlite:///"
    if not url.startswith(prefix):
        return None
    raw = url[len(prefix) :]
    path = Path(raw)
    if not path.is_absolute():
        path = (SERVER_ROOT / path).resolve()
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description="PetLife 跨端云端统计一致性诊断（只读）")
    parser.add_argument("--database-url", default=None, help="覆盖 PETLIFE_DATABASE_URL")
    parser.add_argument("--email", default=None, help="只看某个账户（默认列出全部账户）")
    parser.add_argument("--date", default=None, help="按本地日期统计，格式 YYYY-MM-DD（默认今天）")
    parser.add_argument("--tz-offset-minutes", type=int, default=None, help="本地时区偏移（默认取系统）")
    args = parser.parse_args()

    url = _load_database_url(args.database_url)
    sqlite_path = _resolve_sqlite_path(url)
    if sqlite_path is not None:
        print(f"数据库：{url}")
        print(f"  文件：{sqlite_path}（{'存在' if sqlite_path.is_file() else '不存在'}）")
    else:
        print(f"数据库：{url}")
    print()

    os.environ["PETLIFE_DATABASE_URL"] = url

    from sqlalchemy import create_engine, func, select  # noqa: PLC0415
    from sqlalchemy.orm import Session  # noqa: PLC0415

    from app.models.activity import ActivitySegment  # noqa: PLC0415
    from app.models.device import Device  # noqa: PLC0415
    from app.models.user import User  # noqa: PLC0415

    engine = create_engine(url, future=True)

    offset = args.tz_offset_minutes
    if offset is None:
        now = datetime.now().astimezone()
        offset = int(now.utcoffset().total_seconds() // 60)
    tz = timezone(timedelta(minutes=offset))
    day = date.fromisoformat(args.date) if args.date else datetime.now(tz).date()
    from_utc = datetime(day.year, day.month, day.day, tzinfo=tz).astimezone(timezone.utc)
    to_utc = datetime(day.year, day.month, day.day, tzinfo=tz).astimezone(timezone.utc) + timedelta(
        days=1
    )
    print(f"统计日期：{day}（本地 UTC{offset:+03d}:00）→ 服务器窗口 [ {from_utc.isoformat()} , {to_utc.isoformat()} )")
    print()

    with Session(engine) as db:
        users_stmt = select(User).order_by(User.created_at)
        if args.email:
            users_stmt = users_stmt.where(User.email == args.email)
        users = list(db.scalars(users_stmt))
        if not users:
            print("没有匹配的账户。")
            return 1

        for user in users:
            print("=" * 92)
            print(f"账户 {user.email}  user_id={user.id}")
            print("=" * 92)

            devices = list(
                db.scalars(
                    select(Device).where(Device.user_id == user.id).order_by(Device.created_at)
                )
            )
            if not devices:
                print("  （没有设备）")
                print()
                continue

            print(f"  设备共 {len(devices)} 台：")
            header = (
                f"  {'服务端 device_id':38} {'device_local_id':38} "
                f"{'名称':14} {'platform':9} {'撤销':5} {'最近活动':20}"
            )
            print(header)
            print("  " + "-" * 88)
            for device in devices:
                print(
                    f"  {str(device.id):38} {device.device_local_id[:36]:38} "
                    f"{(device.device_name or '')[:12]:14} "
                    f"{(device.platform or '')[:7]:9} "
                    f"{('是' if device.revoked_at else '否'):5} "
                    f"{device.last_seen_at.isoformat()[:19]:20}"
                )
            print()

            # 同一物理设备分叉的迹象：同 platform + 同名称 / 同型号
            fingerprints: dict[tuple[str, str], list[Device]] = {}
            for device in devices:
                key = (device.platform or "", (device.model_name or device.device_name or "").strip())
                fingerprints.setdefault(key, []).append(device)
            for key, group in fingerprints.items():
                if len(group) > 1:
                    print(
                        f"  [分叉迹象] platform={key[0]} 名称/型号={key[1]!r} 有 {len(group)} 条设备记录："
                    )
                    for device in group:
                        print(
                            f"      id={device.id} local_id={device.device_local_id} "
                            f"created={device.created_at.isoformat()[:19]} "
                            f"revoked={device.revoked_at.isoformat()[:19] if device.revoked_at else '-'}"
                        )
                    print()

            print(f"  {day} 各设备实际保存的 segment：")
            rows = db.execute(
                select(
                    ActivitySegment.device_id,
                    func.count(ActivitySegment.id),
                    func.coalesce(func.sum(ActivitySegment.active_seconds), 0),
                    func.min(ActivitySegment.started_at),
                    func.max(ActivitySegment.started_at),
                )
                .where(
                    ActivitySegment.user_id == user.id,
                    ActivitySegment.started_at < to_utc,
                    (ActivitySegment.ended_at.is_(None)) | (ActivitySegment.ended_at > from_utc),
                )
                .group_by(ActivitySegment.device_id)
            ).all()
            if not rows:
                print("      （当天没有任何 segment）")
            device_by_id = {device.id: device for device in devices}
            for device_id, count, seconds, earliest, latest in rows:
                device = device_by_id.get(device_id)
                label = (
                    f"{device.device_name or ''} · {device.platform or ''}"
                    if device
                    else "<设备行已不存在>"
                )
                print(
                    f"      {device_id}  {label[:34]:34} "
                    f"段数={count:4}  总秒数={seconds:8}  "
                    f"最早={earliest.isoformat()[:19]}  最晚={latest.isoformat()[:19]}"
                )
            print()

            total = db.execute(
                select(
                    func.count(ActivitySegment.id),
                    func.coalesce(func.sum(ActivitySegment.active_seconds), 0),
                ).where(ActivitySegment.user_id == user.id)
            ).one()
            print(f"  该账户全部历史 segment：段数={total[0]}  总秒数={total[1]}")
            print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
