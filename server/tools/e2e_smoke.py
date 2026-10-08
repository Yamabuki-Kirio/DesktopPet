"""端到端冒烟测试：启动真实 uvicorn 服务，用 HTTP 跑完整业务流程。

与 pytest 的区别
----------------
pytest 用 ``TestClient`` 在进程内直接调用 ASGI 应用（快、隔离好）。
本脚本**真的起一个 HTTP 服务**，用真实网络栈访问，覆盖
「进程启动 → 迁移 → 监听 → 认证 → 同步 → 统计」这一整条链路，
用来验证「服务端确实能被客户端连上」，而不是只在进程内自洽。

用法（在 server 目录下）::

    .python/python.exe tools/e2e_smoke.py

退出码 0 = 全部通过。不会访问公网，只连 127.0.0.1。
"""

from __future__ import annotations

import os
import secrets
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER_ROOT))

HOST = "127.0.0.1"
PORT = 8123
BASE = f"http://{HOST}:{PORT}"
API = f"{BASE}/api/v1"

PASSWORD = "E2e-smoke-password-1"


def _fail(message: str) -> None:
    print(f"FAIL: {message}")
    raise SystemExit(1)


def _check(condition: bool, message: str) -> None:
    if not condition:
        _fail(message)
    print(f"  ok  {message}")


def _wait_health(client, timeout: float = 40.0) -> dict:
    deadline = time.time() + timeout
    last: Exception | None = None
    while time.time() < deadline:
        try:
            response = client.get(f"{BASE}/health", timeout=3)
            if response.status_code == 200:
                return response.json()
        except Exception as exc:  # 服务还没起来
            last = exc
        time.sleep(0.5)
    _fail(f"服务在 {timeout}s 内没有就绪（最后错误：{last}）")
    raise AssertionError  # pragma: no cover


def main() -> int:
    try:
        import httpx
    except ImportError:
        print("需要 httpx：pip install -r requirements-dev.txt")
        return 2

    workdir = Path(tempfile.mkdtemp(prefix="petlife_e2e_"))
    db_path = workdir / "e2e.db"
    env = {
        **os.environ,
        "PYTHONUTF8": "1",
        "PETLIFE_JWT_SECRET": secrets.token_urlsafe(48),
        "PETLIFE_ENVIRONMENT": "development",
        "PETLIFE_DATABASE_URL": f"sqlite+pysqlite:///{db_path}",
    }

    print("=== 1. 迁移（空库 → head）===")
    result = subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=SERVER_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        _fail(f"迁移失败：\n{result.stdout}\n{result.stderr}")
    _check("alembic upgrade head 成功", True)

    print("=== 2. 启动 uvicorn ===")
    # 注意：不要把 stdout 接到 subprocess.PIPE —— 没人读取的话管道缓冲区写满后
    # 服务进程会阻塞在写日志上，表现为客户端 read timeout。写到文件即可。
    server_log_path = workdir / "uvicorn.log"
    server_log = server_log_path.open("w", encoding="utf-8")
    server = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "app.main:app",
            "--host",
            HOST,
            "--port",
            str(PORT),
            "--log-level",
            "warning",
        ],
        cwd=SERVER_ROOT,
        env=env,
        stdout=server_log,
        stderr=subprocess.STDOUT,
        text=True,
    )

    def _dump_server_log() -> None:
        server_log.flush()
        tail = server_log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-40:]
        if tail:
            print("--- uvicorn 日志（末尾 40 行）---")
            print("\n".join(tail))

    try:
        with httpx.Client(timeout=20.0) as client:
            health = _wait_health(client)
            _check(health["status"] == "ok", f"/health 返回 ok（database={health['database']}）")

            email = f"e2e-{uuid.uuid4().hex[:8]}@example.com"
            device_local_id = str(uuid.uuid4())

            print("=== 3. 注册（带设备信息）===")
            response = client.post(
                f"{API}/auth/register",
                json={
                    "email": email,
                    "password": PASSWORD,
                    "display_name": "E2E 用户",
                    "device": {
                        "device_local_id": device_local_id,
                        "device_name": "E2E 设备",
                        "platform": "windows",
                        "architecture": "x64",
                        "os_version": "Windows 11",
                        "app_version": "0.2.0",
                    },
                },
            )
            _check(response.status_code == 201, f"注册 201（实际 {response.status_code}）")
            tokens = response.json()
            access = tokens["access_token"]
            refresh = tokens["refresh_token"]
            device_id = tokens["device_id"]
            _check(bool(device_id), "注册响应带 device_id（令牌已绑定设备）")

            auth = {"Authorization": f"Bearer {access}", "X-Device-Id": device_id}

            print("=== 4. 登录（同一 device_local_id 不产生第二台设备）===")
            response = client.post(
                f"{API}/auth/login",
                json={
                    "email": email,
                    "password": PASSWORD,
                    "device": {
                        "device_local_id": device_local_id,
                        "device_name": "E2E 设备",
                    },
                },
            )
            _check(response.status_code == 200, "登录 200")
            access = response.json()["access_token"]
            auth = {"Authorization": f"Bearer {access}", "X-Device-Id": device_id}

            devices = client.get(f"{API}/devices", headers=auth).json()
            _check(len(devices) == 1, "设备列表只有 1 台")

            print("=== 5. 同步上传（活动段 + 每日用量 + 应用）===")
            now = datetime.now(timezone.utc)
            tz_offset = 480
            local_day = (now + timedelta(minutes=tz_offset)).date().isoformat()
            segments = [
                {
                    "id": str(uuid.uuid4()),
                    "device_id": device_id,
                    "app_key": app_key,
                    "category": category,
                    "started_at": (now - timedelta(hours=3 - i)).isoformat(),
                    "ended_at": (now - timedelta(hours=3 - i) + timedelta(minutes=30)).isoformat(),
                    "active_seconds": 1800,
                    "end_reason": "foreground_changed",
                    "created_at": (now - timedelta(hours=3 - i)).isoformat(),
                    "updated_at": (now - timedelta(hours=3 - i) + timedelta(minutes=30)).isoformat(),
                }
                for i, (app_key, category) in enumerate(
                    [("code", "development"), ("chrome", "browser"), ("wechat", "social")]
                )
            ]
            daily = [
                {
                    "device_id": device_id,
                    "local_day": local_day,
                    "timezone_offset_minutes": tz_offset,
                    "session_seconds": 5 * 3600,
                    "active_seconds": 4 * 3600,
                    "idle_seconds": 3600,
                    "updated_at": now.isoformat(),
                }
            ]
            apps = [
                {
                    "app_key": "code",
                    "display_name": "Visual Studio Code",
                    "category": "development",
                    "user_overridden": False,
                    "updated_at": now.isoformat(),
                }
            ]
            payload = {
                "batch_id": str(uuid.uuid4()),
                "activity_segments": segments,
                "daily_usage": daily,
                "applications": apps,
            }

            response = client.post(f"{API}/sync/push", headers=auth, json=payload)
            _check(response.status_code == 200, f"push 200（实际 {response.status_code}）")
            pushed = response.json()
            _check(pushed["accepted_total"] == 5, f"接受 5 条（实际 {pushed['accepted_total']}）")
            _check(pushed["rejected"] == [], "没有被拒绝的记录")
            _check(pushed["cursor"] > 0, f"返回游标 {pushed['cursor']}")

            print("=== 6. 重复提交同一批次（幂等）===")
            response = client.post(f"{API}/sync/push", headers=auth, json=payload)
            _check(response.status_code == 200, "重复 push 200")
            _check(
                response.json()["accepted_total"] == 5,
                "重复提交仍接受 5 条（无重复行）",
            )

            pulled = client.get(f"{API}/sync/pull", headers=auth, params={"cursor": 0}).json()
            _check(
                len(pulled["activity_segments"]) == 3,
                f"下拉仍只有 3 条活动段（实际 {len(pulled['activity_segments'])}）",
            )
            _check(len(pulled["daily_usage"]) == 1, "下拉仍只有 1 条每日用量")
            _check(len(pulled["applications"]) == 1, "下拉仍只有 1 条应用记录")

            print("=== 7. 服务端统计 ===")
            summary = client.get(
                f"{API}/stats/summary",
                headers=auth,
                params={"period": "today", "tz_offset_minutes": tz_offset},
            ).json()
            _check(summary["active_seconds"] == 4 * 3600, "今日活跃时间 = 4 小时")
            _check(summary["idle_seconds"] == 3600, "今日空闲时间 = 1 小时")
            _check(
                summary["session_seconds"] == 5 * 3600,
                "屏幕会话时间 = 活跃 + 空闲 = 5 小时",
            )
            _check(summary["device_count"] == 1, "设备数为 1")

            apps_stats = client.get(
                f"{API}/stats/apps",
                headers=auth,
                params={"period": "today", "tz_offset_minutes": tz_offset},
            ).json()
            _check(
                apps_stats["total_app_active_seconds"] == 5400,
                f"应用使用时间合计 5400s（实际 {apps_stats['total_app_active_seconds']}）",
            )
            by_key = {item["app_key"]: item for item in apps_stats["items"]}
            _check(by_key["code"]["display_name"] == "Visual Studio Code", "应用显示名来自应用库")

            categories = client.get(
                f"{API}/stats/categories",
                headers=auth,
                params={"period": "today", "tz_offset_minutes": tz_offset},
            ).json()
            category_names = {item["category"] for item in categories["items"]}
            _check(
                {"development", "browser", "social"} <= category_names,
                f"分类统计包含三个分类（实际 {sorted(category_names)}）",
            )

            devices_stats = client.get(
                f"{API}/stats/devices",
                headers=auth,
                params={"period": "today", "tz_offset_minutes": tz_offset},
            ).json()
            _check(devices_stats["total_active_seconds"] == 4 * 3600, "设备合计活跃 = 4 小时")
            _check("重叠" in devices_stats["overlap_warning"], "多设备合计带重叠提示")

            print("=== 8. 账户隔离（第二个账户看不到第一个账户的数据）===")
            other_email = f"e2e-other-{uuid.uuid4().hex[:8]}@example.com"
            response = client.post(
                f"{API}/auth/register",
                json={
                    "email": other_email,
                    "password": PASSWORD,
                    "display_name": "另一个用户",
                    "device": {
                        "device_local_id": str(uuid.uuid4()),
                        "device_name": "别人的设备",
                    },
                },
            )
            other = response.json()
            other_auth = {
                "Authorization": f"Bearer {other['access_token']}",
                "X-Device-Id": other["device_id"],
            }
            other_pull = client.get(
                f"{API}/sync/pull", headers=other_auth, params={"cursor": 0}
            ).json()
            _check(other_pull["activity_segments"] == [], "新账户下拉不到别人的活动段")

            # ------------------------------------------------------------------
            # Phase 4B：跨设备云端统计
            #
            # 与上面 /stats/* 的区别：这里走的是「逐条会话」的上传与查询，
            # 覆盖多设备合计、单设备过滤、应用排行、逐条会话、时间线、
            # 重复上传不重复累计、未来日期、跨账户隔离。
            # ------------------------------------------------------------------
            print("=== 8b. Phase 4B 云端统计（多设备 → 查询 → 幂等 → 隔离）===")
            # 同一账户再登录一台 Android 设备 —— 与真实"手机登录同一账户"一致。
            phone_local_id = str(uuid.uuid4())
            phone_login = client.post(
                f"{API}/auth/login",
                json={
                    "email": email,
                    "password": PASSWORD,
                    "device": {
                        "device_local_id": phone_local_id,
                        "device_name": "E2E 手机",
                        "platform": "android",
                        "architecture": "arm64",
                    },
                },
            )
            _check(phone_login.status_code == 200, "手机端登录 200")
            phone_id = phone_login.json()["device_id"]
            _check(bool(phone_id) and phone_id != device_id, "手机是同一账户下的第二台设备")
            phone_auth = {
                "Authorization": f"Bearer {phone_login.json()['access_token']}",
                "X-Device-Id": phone_id,
            }

            day_local = (now + timedelta(minutes=tz_offset)).date() - timedelta(days=1)
            #: Phase 4B 查询用的日期字符串（放在前一天，避免与第 5 步的数据混在一起）
            day_key = day_local.isoformat()
            local_tz = timezone(timedelta(minutes=tz_offset))

            def at(hour: int, minute: int) -> str:
                """当地时间 → UTC ISO（统计按当地日期划分，因此必须显式换算）。"""
                return (
                    datetime(
                        day_local.year,
                        day_local.month,
                        day_local.day,
                        hour,
                        minute,
                        tzinfo=local_tz,
                    )
                    .astimezone(timezone.utc)
                    .isoformat()
                )

            def b4_segment(
                device: str,
                app_key: str,
                category: str,
                start: tuple[int, int],
                end: tuple[int, int],
                seconds: int,
            ) -> dict:
                return {
                    "id": str(uuid.uuid4()),
                    "device_id": device,
                    "app_key": app_key,
                    "category": category,
                    "started_at": at(*start),
                    "ended_at": at(*end),
                    "active_seconds": seconds,
                    "end_reason": "foreground_changed",
                    "created_at": at(*start),
                    "updated_at": at(*end),
                }

            # 电脑：Edge 两段；手机：微信一段。
            pc_segments = [
                b4_segment(device_id, "msedge", "browser", (9, 12), (9, 35), 1380),
                b4_segment(device_id, "msedge", "browser", (10, 6), (10, 41), 2100),
            ]
            phone_segments = [
                b4_segment(phone_id, "wechat", "social", (11, 0), (11, 20), 1200),
            ]
            b4_apps = [
                {
                    "app_key": "msedge",
                    "display_name": "Microsoft Edge",
                    "category": "browser",
                    "user_overridden": False,
                    "updated_at": now.isoformat(),
                },
                {
                    "app_key": "wechat",
                    "display_name": "微信",
                    "category": "social",
                    "user_overridden": False,
                    "updated_at": now.isoformat(),
                },
            ]

            response = client.post(
                f"{API}/sync/push",
                headers=auth,
                json={
                    "batch_id": str(uuid.uuid4()),
                    "activity_segments": pc_segments,
                    "daily_usage": [],
                    "applications": b4_apps,
                },
            )
            _check(response.status_code == 200, "电脑端会话上传 200")
            response = client.post(
                f"{API}/sync/push",
                headers=phone_auth,
                json={
                    "batch_id": str(uuid.uuid4()),
                    "activity_segments": phone_segments,
                    "daily_usage": [],
                    "applications": [],
                },
            )
            _check(response.status_code == 200, "手机端会话上传 200")

            def statistics(path: str, headers: dict, **params):
                return client.get(
                    f"{API}/statistics/{path}",
                    headers=headers,
                    params={k: v for k, v in params.items() if v is not None},
                )

            # --- 全部设备 ---
            body = statistics("summary", auth, date=day_key, timezone="Asia/Shanghai").json()
            _check(body["date"] == day_key, "汇总日期 = 查询的当地日期")
            _check(
                body["total_duration_seconds"] == 1380 + 2100 + 1200,
                f"全部设备累计 {1380 + 2100 + 1200}s（实际 {body['total_duration_seconds']}）"
                f"｜date={body['date']} session_count={body['session_count']} "
                f"app_count={body['app_count']} "
                f"apps={[(a['app_id'], a['duration_seconds']) for a in body['apps']]}",
            )
            _check(body["session_count"] == 3, "全部设备 3 段会话")
            _check(body["app_count"] == 2, "全部设备 2 个应用")
            _check(body["overlap_warning"] is not None, "全部设备带重叠说明")
            _check(body["last_synced_at"] is not None, "带最近同步时间")
            ranked = [item["app_id"] for item in body["apps"]]
            _check(ranked == ["msedge", "wechat"], f"应用按时长降序（实际 {ranked}）")
            _check(body["apps"][0]["app_name"] == "Microsoft Edge", "应用名取自应用库")
            _check(body["apps"][0]["duration_seconds"] == 3480, "Edge 合计 3480s")

            # --- 单设备过滤 ---
            pc_only = statistics(
                "summary", auth, date=day_key, device_id=device_id, timezone="Asia/Shanghai"
            ).json()
            _check(
                pc_only["total_duration_seconds"] == 3480,
                f"只看 Windows 设备 = 3480s（实际 {pc_only['total_duration_seconds']}）",
            )
            _check(pc_only["app_count"] == 1, "只看 Windows 设备只有 1 个应用")
            _check(pc_only["overlap_warning"] is None, "单设备不显示重叠说明")

            # --- 逐条会话（展开某个应用的时间段）---
            page = statistics(
                "sessions",
                auth,
                date=day_key,
                device_id=device_id,
                app_id="msedge",
                timezone="Asia/Shanghai",
            ).json()
            _check(len(page["items"]) == 2, f"Edge 展开 2 段（实际 {len(page['items'])}）")
            starts = [item["started_at"] for item in page["items"]]
            _check(starts == sorted(starts), "逐条会话按开始时间升序")
            _check(
                all(str(item["device_id"]) == device_id for item in page["items"]),
                "每段会话都带正确的来源设备",
            )
            _check(page["next_cursor"] is None, "两段一页装得下，没有下一页游标")

            # --- 时间线（全部设备，按开始时间升序）---
            timeline = statistics(
                "timeline", auth, date=day_key, timezone="Asia/Shanghai"
            ).json()
            _check(len(timeline["items"]) == 3, f"时间线 3 条（实际 {len(timeline['items'])}）")
            tl_starts = [item["started_at"] for item in timeline["items"]]
            _check(tl_starts == sorted(tl_starts), "时间线按开始时间升序")
            _check(
                {item["device_name"] for item in timeline["items"]}
                == {"E2E 设备", "E2E 手机"},
                "时间线每条带来源设备名",
            )
            _check(
                timeline["total_duration_seconds"] == 4680,
                "时间线合计与汇总一致（服务端只算一次，客户端不重复累计）",
            )

            # --- 重复上传不重复累计 ---
            client.post(
                f"{API}/sync/push",
                headers=auth,
                json={
                    "batch_id": str(uuid.uuid4()),
                    "activity_segments": pc_segments,
                    "daily_usage": [],
                    "applications": b4_apps,
                },
            )
            again = statistics("summary", auth, date=day_key, timezone="Asia/Shanghai").json()
            _check(
                again["total_duration_seconds"] == 4680,
                f"重复上传后累计不变（实际 {again['total_duration_seconds']}）",
            )

            # --- 未来日期：空数据而不是错误 ---
            tomorrow = (
                (now + timedelta(minutes=tz_offset)).date() + timedelta(days=1)
            ).isoformat()
            future = statistics("summary", auth, date=tomorrow, timezone="Asia/Shanghai")
            _check(
                future.status_code == 200 and future.json()["total_duration_seconds"] == 0,
                "未来日期返回空数据（200 且累计 0）",
            )

            # --- 跨账户隔离 ---
            other_summary = statistics(
                "summary", other_auth, date=day_key, timezone="Asia/Shanghai"
            )
            _check(
                other_summary.status_code == 200
                and other_summary.json()["total_duration_seconds"] == 0,
                "第二个账户查不到第一个账户的统计",
            )
            foreign = statistics(
                "summary",
                other_auth,
                date=day_key,
                device_id=device_id,
                timezone="Asia/Shanghai",
            )
            _check(
                foreign.status_code == 404,
                f"指定别人的设备返回 404（实际 {foreign.status_code}）",
            )

            print("=== 9. Token 刷新与吊销 ===")
            response = client.post(
                f"{API}/auth/refresh", json={"refresh_token": refresh}
            )
            _check(response.status_code == 200, "refresh 200")
            rotated = response.json()["refresh_token"]
            _check(rotated != refresh, "Refresh Token 已轮换")

            reuse = client.post(f"{API}/auth/refresh", json={"refresh_token": refresh})
            _check(
                reuse.status_code == 401
                and reuse.json()["error"]["code"] == "refresh_token_reused",
                "复用旧 Refresh Token 被判定为泄露",
            )

            print("=== 10. 撤销设备后同步被拒 ===")
            fresh_login = client.post(
                f"{API}/auth/login",
                json={
                    "email": email,
                    "password": PASSWORD,
                    "device": {
                        "device_local_id": device_local_id,
                        "device_name": "E2E 设备",
                    },
                },
            ).json()
            fresh_auth = {
                "Authorization": f"Bearer {fresh_login['access_token']}",
                "X-Device-Id": device_id,
            }
            revoke = client.delete(f"{API}/devices/{device_id}", headers=fresh_auth)
            _check(revoke.status_code == 200, "撤销设备 200")

            blocked = client.post(
                f"{API}/sync/push",
                headers=fresh_auth,
                json={"activity_segments": [], "daily_usage": [], "applications": []},
            )
            _check(
                blocked.status_code == 403
                and blocked.json()["error"]["code"] == "device_revoked",
                "撤销后同步返回 device_revoked",
            )

            print("=== 11. 服务端日志脱敏抽查 ===")
            server_log.flush()
            server_output = server_log_path.read_text(encoding="utf-8", errors="replace")
            _check(PASSWORD not in server_output, "日志中不含用户密码")
            _check(tokens["refresh_token"] not in server_output, "日志中不含 Refresh Token")
            _check(tokens["access_token"] not in server_output, "日志中不含 Access Token")
            _check(
                "Bearer " not in server_output or "<redacted>" in server_output,
                "Authorization 头未以明文写入日志",
            )

        print()
        print("E2E SMOKE PASSED")
        return 0
    except SystemExit:
        _dump_server_log()
        raise
    except Exception as exc:
        print(f"FAIL: 未预期的异常 {type(exc).__name__}: {exc}")
        _dump_server_log()
        return 1
    finally:
        server_log.close()
        server.terminate()
        try:
            server.wait(timeout=15)
        except subprocess.TimeoutExpired:  # pragma: no cover
            server.kill()
        # 清理本次运行的临时库
        for pattern in ("*.db", "*.db-wal", "*.db-shm"):
            for leftover in workdir.glob(pattern):
                leftover.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
