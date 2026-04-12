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

RUN useradd -m -s /bin/bash claude

#For DGX Spark(Linux) setting
#RUN userdel -r node 2>/dev/null; useradd -m -s /bin/bash -u 1000 claude

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

WORKDIR /workspace

# 変更後
#ENTRYPOINT ["claude", "--dangerously-skip-permissions", \
#     "--channels", "plugin:discord@claude-plugins-official"]
ENTRYPOINT ["script", "-c", "claude --dangerously-skip-permissions --channels plugin:discord@claude-plugins-official", "/dev/null"]