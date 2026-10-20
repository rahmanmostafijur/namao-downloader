# syntax=docker/dockerfile:1
#
# One image runs both the API and the worker (compose selects the command).
# Everything that affects YouTube extraction is pinned and verified at BUILD
# time; nothing is downloaded or installed when a container starts.

# ---- Deno: official release, pinned version, checksum-verified -------------
FROM debian:bookworm-slim AS deno
ARG TARGETARCH
ARG DENO_VERSION=2.9.7
ARG DENO_SHA256_AMD64=c6527f24f4b16031d3ae4fa9f658d5f11534c8d84ce7dc8502420280919c3490
ARG DENO_SHA256_ARM64=c832298b1ad4422481334855f6003e0f54145762c5a134f20a489511d2f65bbf
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) triple=x86_64-unknown-linux-gnu;  sha="${DENO_SHA256_AMD64}" ;; \
      arm64) triple=aarch64-unknown-linux-gnu; sha="${DENO_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/deno.zip \
      "https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-${triple}.zip"; \
    echo "${sha}  /tmp/deno.zip" | sha256sum -c -; \
    unzip -q /tmp/deno.zip -d /out; \
    chmod 0755 /out/deno

# ---- runtime ----------------------------------------------------------------
FROM python:3.12-slim-bookworm AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NAMAO_DATA_DIR=/data

# FFmpeg + FFprobe from Debian (real binaries; not the `ffmpeg` PyPI package), tini for signal handling.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg tini ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=deno /out/deno /usr/local/bin/deno

RUN useradd --system --uid 10001 --create-home --home-dir /home/namao namao \
    && mkdir -p /data /app \
    && chown namao:namao /data /app

WORKDIR /app
COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY namao ./namao
COPY static ./static
COPY main.py ./

# Prove the whole dependency chain works inside this image; fail the build otherwise.
RUN deno --version | head -1 \
    && ffmpeg -version | head -1 \
    && ffprobe -version | head -1 \
    && python -c "import yt_dlp, yt_dlp_ejs; from importlib.metadata import version; print('yt-dlp', yt_dlp.version.__version__, 'yt-dlp-ejs', version('yt-dlp-ejs'))"

USER namao
EXPOSE 8000
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health/live', timeout=4).status == 200 else 1)"

ENTRYPOINT ["tini", "--"]
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
