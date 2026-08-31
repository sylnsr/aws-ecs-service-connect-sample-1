# ECS image. Serves every route except loyalty.
#
# Two stages so the build toolchain used to compile wheels never reaches the
# runtime image. Slim rather than alpine: musl forces source builds of
# pydantic-core and uvloop, which makes the image slower to build and no
# smaller once the compilers are gone.

FROM python:3.12-slim AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt


FROM python:3.12-slim AS runtime

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_MODE=ecs \
    WORKLOAD=ecs \
    STORE=dynamodb \
    PORT=8080

# Non-root. ECS will not stop you running as root, but a container that never
# needs to write outside its own data directory has no reason to.
RUN useradd --create-home --uid 10001 awuca

COPY --from=build /opt/venv /opt/venv

WORKDIR /app
COPY --chown=awuca:awuca awuca/ ./awuca/
COPY --chown=awuca:awuca main_ecs.py ./

# Only used when STORE=yaml. Created here so a local `docker run` with the YAML
# store does not fail on a read-only parent directory.
RUN mkdir -p /app/data && chown awuca:awuca /app/data

USER awuca
EXPOSE 8080

# No HEALTHCHECK instruction: the ALB target group health check is the one that
# decides whether this task receives traffic, and a second, disagreeing check
# inside the container only adds a way for the two to conflict.

CMD ["uvicorn", "main_ecs:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
