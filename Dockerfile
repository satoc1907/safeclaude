# ---- ステージ1: rtkをAlpine(musl)で静的リンクビルド ----
FROM rust:alpine AS rtk-builder
RUN apk add --no-cache musl-dev
RUN cargo install --git https://github.com/rtk-ai/rtk

# ---- Node供給用 donor ステージ ----
FROM node:22-slim AS node-donor

# ---- ステージ2: 本体 (Ubuntu 24.04 = glibc 2.39 / GLIBCXX_3.4.32) ----
# torch sm_121 wheel は Ubuntu 24.04 向けビルドのため base を揃え、ABI不一致を避ける
FROM ubuntu:24.04

# Node.js を node 公式イメージから移植（Ubuntu base には Node が無いため）
# node 公式バイナリは旧glibc向けビルドで、glibc 2.39 上でも前方互換で動作する
COPY --from=node-donor /usr/local /usr/local

RUN apt-get update && apt-get install -y \
    git curl vim ripgrep unzip ca-certificates \
    build-essential cmake \
    libopenblas0 libnuma1 \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
ENV PATH="/root/.bun/bin:$PATH"

# uv をインストール
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    cp /root/.local/bin/uv /usr/local/bin/ && \
    cp /root/.local/bin/uvx /usr/local/bin/

#For DGX Spark(Linux) setting
# Ubuntu 24.04 は uid1000 の ubuntu ユーザーを標準搭載するため、先に削除して衝突を回避
RUN userdel -r ubuntu 2>/dev/null; userdel -r node 2>/dev/null; useradd -m -s /bin/bash -u 1000 claude
#For Mac setting
#RUN userdel -r node 2>/dev/null; useradd -m -s /bin/bash -u 501 claude

# entrypoint スクリプトを直接生成
# - .claude.json からホスト固有の情報を除去
# - CLAUDE_CONTINUE=1 なら -c フラグを追加して前回セッションを再開
RUN printf '#!/bin/bash\n\
if [ -f /tmp/.claude.json.host ]; then\n\
  node -e "\n\
    const data = JSON.parse(require(\"fs\").readFileSync(\"/tmp/.claude.json.host\", \"utf8\"));\n\
    delete data.projects;\n\
    delete data.githubRepoPaths;\n\
    require(\"fs\").writeFileSync(\"/home/claude/.claude.json\", JSON.stringify(data, null, 2));\n\
  " 2>/dev/null || cp /tmp/.claude.json.host /home/claude/.claude.json\n\
fi\n\
CONTINUE_FLAG=""\n\
if [ "${CLAUDE_CONTINUE:-}" = "1" ]; then\n\
  CONTINUE_FLAG="-c"\n\
fi\n\
exec claude $CONTINUE_FLAG --dangerously-skip-permissions --channels plugin:discord@claude-plugins-official\n' \
    > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

# rtk テレメトリ無効化
ENV RTK_TELEMETRY_DISABLED=1

RUN mkdir -p /host /workspace && chown claude:claude /workspace

USER claude

# /home/claude/.bun/bin/bun -> /usr/local/bin/bun へのシンボリックリンクを作成
RUN mkdir -p /home/claude/.bun/bin && \
    ln -sf /usr/local/bin/bun /home/claude/.bun/bin/bun

ENV PATH="/home/claude/.bun/bin:$PATH"

# プラグインをイメージ内に焼き込む
RUN mkdir -p /home/claude/.claude/plugins/marketplaces && \
    git clone https://github.com/anthropics/claude-plugins-official.git \
    /home/claude/.claude/plugins/marketplaces/claude-plugins-official

RUN echo '{"claude-plugins-official":{"url":"https://github.com/anthropics/claude-plugins-official","installLocation":"/home/claude/.claude/plugins/marketplaces/claude-plugins-official"}}' \
    > /home/claude/.claude/plugins/known_marketplaces.json

RUN echo '{"version":2,"plugins":{"discord@claude-plugins-official":[{"scope":"user","installPath":"/home/claude/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/discord","version":"0.0.4","installedAt":"2026-01-01T00:00:00.000Z","lastUpdated":"2026-01-01T00:00:00.000Z"}]}}' \
    > /home/claude/.claude/plugins/installed_plugins.json

# rtk バイナリをビルドステージからコピー（musl静的リンク済み）
RUN mkdir -p /home/claude/.local/bin
COPY --from=rtk-builder /usr/local/cargo/bin/rtk /home/claude/.local/bin/rtk
ENV PATH="/home/claude/.local/bin:$PATH"
RUN rtk init -g --auto-patch

# --boltz で /usr/local/cuda:ro をマウントした際、sm_121 wheel が要求する
# libcudart.so.13 等を手動 export なしで解決できるよう恒久化。
# CUDA 未マウント（通常起動）時は存在しないパスとなるが、動的リンカは
# 存在しないディレクトリを単に無視するため無害。
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
