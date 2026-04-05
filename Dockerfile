FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git curl vim ripgrep unzip \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
ENV PATH="/root/.bun/bin:$PATH"

RUN useradd -m -s /bin/bash claude
RUN mkdir -p /host /workspace && chown claude:claude /workspace

USER claude
ENV PATH="/home/claude/.bun/bin:$PATH"

# プラグインをイメージ内に焼き込む
RUN mkdir -p /home/claude/.claude/plugins/marketplaces && \
    git clone https://github.com/anthropics/claude-plugins-official.git \
    /home/claude/.claude/plugins/marketplaces/claude-plugins-official

RUN echo '{"claude-plugins-official":{"url":"https://github.com/anthropics/claude-plugins-official","installLocation":"/home/claude/.claude/plugins/marketplaces/claude-plugins-official"}}' \
    > /home/claude/.claude/plugins/known_marketplaces.json

RUN echo '[{"name":"discord","marketplace":"claude-plugins-official","scope":"user","installLocation":"/home/claude/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/discord"}]' \
    > /home/claude/.claude/plugins/installed_plugins.json

WORKDIR /workspace

ENTRYPOINT ["claude", "--dangerously-skip-permissions", \
            "--channels", "plugin:discord@claude-plugins-official"]