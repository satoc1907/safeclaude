# ---- ステージ1: rtkをAlpine(musl)で静的リンクビルド ----
FROM rust:alpine AS rtk-builder
RUN apk add --no-cache musl-dev
RUN cargo install --git https://github.com/rtk-ai/rtk

# ---- ステージ2: 本体 (node:22-slim = Bookwormのまま) ----
FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git curl vim ripgrep unzip \
    build-essential cmake \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
ENV PATH="/root/.bun/bin:$PATH"

# uv をインストール
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    cp /root/.local/bin/uv /usr/local/bin/ && \
    cp /root/.local/bin/uvx /usr/local/bin/

#For DGX Spark(Linux) setting
#RUN userdel -r node 2>/dev/null; useradd -m -s /bin/bash -u 1000 claude
#For Mac setting
RUN userdel -r node 2>/dev/null; useradd -m -s /bin/bash -u 501 claude

# entrypoint スクリプトを直接生成
RUN printf '#!/bin/bash\n\
if [ -f /tmp/.claude.json.host ]; then\n\
  node -e "\n\
    const data = JSON.parse(require(\"fs\").readFileSync(\"/tmp/.claude.json.host\", \"utf8\"));\n\
    delete data.projects;\n\
    delete data.githubRepoPaths;\n\
    require(\"fs\").writeFileSync(\"/home/claude/.claude.json\", JSON.stringify(data, null, 2));\n\
  " 2>/dev/null || cp /tmp/.claude.json.host /home/claude/.claude.json\n\
fi\n\
exec claude --dangerously-skip-permissions --channels plugin:discord@claude-plugins-official\n' \
    > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

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

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
