# The WhatsApp connector, built from the upstream lharries/whatsapp-mcp at a
# pinned commit. The builder fetches that commit, applies the patches in
# patches/, and compiles the Go bridge with CGO (whatsmeow's sqlite driver).
FROM golang:1.26.8-bookworm AS builder

ARG WA_COMMIT=7d6a06dcdce1f01dfb24f60e1030d5efba9f3b88

# Fetch only the pinned commit. The working tree stays a git repository so the
# patches can be checked and applied with `git apply`; an anchor that does not
# match the pinned source fails the build instead of fuzzing through.
RUN git init -q /src \
    && git -C /src remote add origin https://github.com/lharries/whatsapp-mcp.git \
    && git -C /src fetch -q --depth 1 origin "$WA_COMMIT" \
    && git -C /src checkout -q FETCH_HEAD

WORKDIR /src
COPY patches /patches
RUN for patch in /patches/*.patch; do \
        echo "applying $(basename "$patch")"; \
        git apply --check "$patch"; \
        git apply "$patch"; \
    done

WORKDIR /src/whatsapp-bridge
RUN CGO_ENABLED=1 GOTOOLCHAIN=local \
    go build -trimpath -ldflags='-s -w' -o /out/whatsapp-bridge .

# The runtime is Debian slim with the Python minor the upstream server asks for
# (>=3.11, .python-version 3.11). No Go toolchain or compiler is copied in.
FROM python:3.11-slim-bookworm AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# ca-certificates is needed for the bridge's TLS to WhatsApp; tini is PID 1.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 pwuser \
    && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/pwuser --shell /bin/bash pwuser

# The upstream Python server, unmodified, and a venv with its dependencies.
# The versions are the ones upstream's uv.lock resolved for the pyproject
# constraints; no uv is needed at run time. The pydantic pins matter: mcp 1.6.0
# imports an internal name that later pydantic releases removed.
COPY --from=builder /src/whatsapp-mcp-server /opt/whatsapp-mcp/whatsapp-mcp-server
RUN python3 -m venv /opt/whatsapp-mcp/.venv \
    && /opt/whatsapp-mcp/.venv/bin/pip install --no-cache-dir \
        'httpx==0.28.1' 'mcp[cli]==1.6.0' 'requests==2.32.3' \
        'anyio==4.9.0' 'certifi==2025.1.31' 'charset-normalizer==3.4.1' \
        'click==8.1.8' 'h11==0.14.0' 'httpcore==1.0.7' 'httpx-sse==0.4.0' \
        'idna==3.10' 'markdown-it-py==3.0.0' 'mdurl==0.1.2' \
        'pydantic==2.11.1' 'pydantic-core==2.33.0' 'pydantic-settings==2.8.1' \
        'pygments==2.19.1' 'python-dotenv==1.1.0' 'rich==13.9.4' \
        'shellingham==1.5.4' 'sniffio==1.3.1' 'sse-starlette==2.2.1' \
        'starlette==0.46.1' 'typer==0.15.2' 'typing-extensions==4.13.0' \
        'typing-inspection==0.4.0' 'urllib3==2.3.0' 'uvicorn==0.34.0'

# The MCP proxy environment, exactly as the other connectors use it.
RUN python3 -m venv /opt/bridge \
    && /opt/bridge/bin/pip install --no-cache-dir 'mcp-proxy==0.12.0' 'mcp==1.30.0'

# The compiled bridge. Its working directory at run time is the state path, so
# its relative store/ is the mounted volume. The Python server computes
# ../whatsapp-bridge/store from its own file, so that path is a symlink to the
# same directory.
COPY --from=builder /out/whatsapp-bridge /opt/whatsapp-mcp/whatsapp-bridge/whatsapp-bridge
# The MIT licence and attribution travel with the copy of the upstream server.
COPY LICENSE NOTICE /opt/whatsapp-mcp/
RUN mkdir -p /home/pwuser/.whatsapp-mcp/store \
    && ln -s /home/pwuser/.whatsapp-mcp/store /opt/whatsapp-mcp/whatsapp-bridge/store \
    && chown -R pwuser:pwuser /home/pwuser/.whatsapp-mcp

# The gate owns :3000, the bridge listens on loopback, and the liveness probe
# performs the MCP handshake through the proxy.
COPY --chmod=755 scripts/runner-gate.py /opt/cerase/runner-gate.py
COPY --chmod=755 scripts/healthcheck.py /opt/cerase/healthcheck.py
COPY --chmod=755 scripts/entrypoint.sh /opt/cerase/entrypoint.sh

USER pwuser
WORKDIR /home/pwuser

EXPOSE 3000

ENV CERASE_HEALTHCHECK_URL=http://127.0.0.1:3001/mcp

HEALTHCHECK --interval=5m --start-interval=5s --timeout=10s --start-period=60s --retries=2 \
    CMD python3 /opt/cerase/runner-gate.py --probe && python3 /opt/cerase/healthcheck.py || exit 1

ENTRYPOINT ["/opt/cerase/entrypoint.sh"]
