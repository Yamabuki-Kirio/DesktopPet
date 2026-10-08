# PetLife API 服务端镜像
#
# 关键点：
# * 用 slim 基础镜像 + 固定 Python 3.12
# * PYTHONUTF8=1：Windows/容器里都可能出现 GBK 之类的 locale，
#   强制 UTF-8 才能让中文日志与源码注释一致工作
# * 不把 .env 打进镜像；配置一律运行期注入（compose env_file / 环境变量）
# * 以非 root 用户运行

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUTF8=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# 依赖单独一层，改代码不会导致重装依赖
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# 迁移脚本与应用代码
COPY alembic.ini ./
COPY migrations ./migrations
COPY app ./app

# 非 root 运行（uid 10001）
RUN useradd --create-home --uid 10001 petlife \
    && chown -R petlife:petlife /app
USER petlife

EXPOSE 8000

# 就绪探针：/health 会同时检查数据库连通性
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; \
sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4).status==200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
