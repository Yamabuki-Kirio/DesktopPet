# PetLife 服务端（Phase 2）

本目录是独立部署的云端组件，包含 FastAPI API、PostgreSQL/Alembic 迁移、同步服务和 MCP Server；客户端发布包不包含本目录。

账户 / 设备 / 使用数据同步服务。**只接收应用使用时长与分类**，
不接受窗口标题、URL、文档名、本地完整路径、截图或素材文件。

- 技术栈：Python 3.12 · FastAPI · SQLAlchemy 2 · Alembic · PostgreSQL 16（开发可用 SQLite）
- 认证：Argon2id 密码哈希 + JWT Access Token + 可轮换的不透明 Refresh Token
- 文档：`../docs/15-Phase2总体架构.md`、`16-服务端部署与配置.md`、`17-认证与设备协议.md`、`18-数据同步协议.md`、`19-隐私与安全说明.md`

---

## 1. 快速开始

### 1.1 Docker Compose（推荐，含 PostgreSQL）

```bash
cd server
cp .env.example .env
# 生成一个真实密钥并填进 .env 的 PETLIFE_JWT_SECRET
python -c "import secrets;print(secrets.token_urlsafe(48))"
# 同时设置 POSTGRES_PASSWORD（不设置 compose 会直接失败）

docker compose up --build          # 自动跑迁移 → 启动 API
curl http://127.0.0.1:8000/health
```

只跑迁移（不改动 API 容器）：

```bash
docker compose run --rm migrate
```

停止并保留数据：`docker compose down`
停止并**删除**数据卷：`docker compose down -v`（⚠️ 会清空所有使用数据）

### 1.2 无 Docker（SQLite，本地开发/跑测试）

```bash
cd server
python -m venv .venv && . .venv/bin/activate     # Windows: .venv\Scripts\activate
pip install -r requirements.txt -r requirements-dev.txt

cp .env.example .env        # 改掉 PETLIFE_JWT_SECRET
python -m alembic upgrade head
uvicorn app.main:app --reload
```

> Windows 上建议同时设置 `PYTHONUTF8=1`，否则中文日志在某些 locale 下会报编码错误。

---

## 2. 数据库迁移

```bash
python -m alembic upgrade head              # 升级到最新
python -m alembic downgrade -1              # 回退一步
python -m alembic current                   # 当前版本
python -m alembic history                   # 版本历史
python -m alembic revision --autogenerate -m "描述"   # 生成新迁移
```

数据库 URL 来自 `PETLIFE_DATABASE_URL`（`alembic.ini` 里刻意不写 URL，
避免"应用连的库"和"迁移改的库"不一致）。也可临时覆盖：

```bash
python -m alembic -x db_url=postgresql+psycopg2://u:p@host/db upgrade head
```

离线查看将要执行的 SQL（不需要连库）：

```bash
python -m alembic -x db_url=postgresql+psycopg2://u:p@localhost:5432/petlife upgrade head --sql
```

---

## 3. 运行测试

```bash
pip install -r requirements-dev.txt
python -m pytest -q
```

- 测试使用**临时 SQLite 库**，不依赖 PostgreSQL，也不访问公网。
- 其中 `test_migrations.py` 会真实执行 Alembic 迁移，并逐项比对
  「迁移建出的 schema」与「模型声明」是否一致（表 / 列 / 主键 / 外键 / 唯一约束 / 索引），
  同时**离线生成 PostgreSQL DDL** 校验方言（UUID、BIGSERIAL、复合主键）。

---

## 4. 环境变量

见 `.env.example`。要点：

| 变量 | 说明 |
|---|---|
| `PETLIFE_JWT_SECRET` | **必填**。占位值（`change-me` 等）会被拒绝，防止误部署 |
| `PETLIFE_DATABASE_URL` | `sqlite+pysqlite:///...` 或 `postgresql+psycopg2://...` |
| `PETLIFE_ENVIRONMENT` | `production` 时自动关闭 `/docs` 与 `/openapi.json` |
| `PETLIFE_ACCESS_TOKEN_TTL_MINUTES` | 默认 15 分钟 |
| `PETLIFE_REFRESH_TOKEN_TTL_DAYS` | 默认 30 天 |
| `PETLIFE_SYNC_MAX_BATCH_SIZE` | 单批上限，默认 200 |
| `POSTGRES_PASSWORD` | compose 用；未设置则 compose 直接失败 |

---

## 5. 接口清单

统一前缀 `/api/v1`，统一错误体 `{"error":{"code","message","request_id"}}`。

```
POST   /auth/register
POST   /auth/login
POST   /auth/refresh
POST   /auth/logout
POST   /auth/logout-all
GET    /me
PATCH  /me
POST   /me/password
DELETE /me

POST   /devices/register
GET    /devices
GET    /devices/{device_id}
PATCH  /devices/{device_id}
DELETE /devices/{device_id}

POST   /sync/push
GET    /sync/pull?cursor=&limit=&device_ids=

GET    /stats/summary?period=&tz_offset_minutes=
GET    /stats/apps?period=&tz_offset_minutes=
GET    /stats/categories?period=&tz_offset_minutes=
GET    /stats/devices?period=&tz_offset_minutes=

GET    /health      （不需要认证，同时探测数据库）
```

`period` ∈ `today | yesterday | 7d | 30d`；
`tz_offset_minutes` 由客户端提供，「今天」的边界一律按客户端时区计算。

启动后可访问 `http://127.0.0.1:8000/docs` 查看交互式文档（非生产环境）。

---

## 6. 生产部署（需要你自行完成，本仓库不会自动部署）

1. **HTTPS 与反向代理**：把 Caddy 或 Nginx 放在 API 前面终止 TLS。
   Caddy 最小配置：

   ```
   api.example.com {
       reverse_proxy 127.0.0.1:8000
   }
   ```

   并把 compose 里的 `API_BIND_ADDRESS` 保持为 `127.0.0.1`，
   只让反向代理能访问 API。**开发环境可以直接用 HTTP 访问 localhost；
   生产必须 HTTPS**（否则 Bearer 令牌会在链路上明文传输）。

2. **密钥管理**：`PETLIFE_JWT_SECRET` 用随机 48 字节；用密钥管理服务或
   受控的 `.env`（权限 600），不要写进镜像或代码库。

3. **密钥轮换**：轮换 `PETLIFE_JWT_SECRET` 会让所有 Access Token 立即失效
   （Refresh Token 存在数据库里，不受影响），用户会被静默刷新，体验无感。
   轮换步骤：改 `.env` → `docker compose up -d api`。

4. **备份**：

   ```bash
   docker compose exec db pg_dump -U petlife -Fc petlife > petlife_$(date +%F).dump
   # 恢复
   docker compose exec -T db pg_restore -U petlife -d petlife --clean < petlife_2026-09-27.dump
   ```

5. **口令轮换**：改 `.env` 里的 `POSTGRES_PASSWORD` 后需要同步改数据库口令：

   ```bash
   docker compose exec db psql -U petlife -c "ALTER USER petlife WITH PASSWORD '新口令';"
   ```

6. **不要在没有服务器地址与授权的情况下把本服务暴露到公网。**

---

## 7. 目录结构

```
server/
├── app/
│   ├── api/v1/          # 路由：auth / devices / sync / stats
│   ├── core/            # 配置、错误体、日志脱敏、时间、自定义列类型
│   ├── database/        # 引擎、会话、声明式基类
│   ├── models/          # ORM 模型（users/devices/refresh_tokens/同步数据）
│   ├── schemas/         # 请求与响应模型
│   ├── security/        # Argon2id、JWT、鉴权依赖
│   ├── services/        # 业务逻辑（认证/设备/同步/统计）
│   └── main.py          # 应用装配 + /health
├── migrations/          # Alembic 迁移（0001_initial_schema）
├── tests/               # pytest（100 项）
├── Dockerfile
├── docker-compose.yml
├── alembic.ini          # 注意：保持纯 ASCII（configparser 按 locale 读取）
├── requirements.txt
└── .env.example
```
