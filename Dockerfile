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

ARG CLAUDE_UID=501
RUN userdel -r node 2>/dev/null; useradd -m -s /bin/bash -u ${CLAUDE_UID} claude

# entrypoint スクリプトを直接生成
# - 起動時に永続化ディレクトリ (/home/claude/.claude-auth) から認証情報を復元
# - .claude.json からホスト固有の情報を除去
# - CLAUDE_CONTINUE=1 なら -c フラグを追加して前回セッションを再開
# - 終了時に trap で認証情報を永続化ディレクトリへ書き戻す（exec しない理由）
RUN printf '#!/bin/bash\n\
# 起動時: 永続化ディレクトリから認証情報と .claude.json を復元\n\
if [ -f /home/claude/.claude-auth/.credentials.json ]; then\n\
  cp /home/claude/.claude-auth/.credentials.json /home/claude/.claude/.credentials.json\n\
fi\n\
if [ -f /home/claude/.claude-auth/claude.json ]; then\n\
  cp /home/claude/.claude-auth/claude.json /home/claude/.claude.json\n\
elif [ -f /tmp/.claude.json.host ]; then\n\
  node -e "\n\
    const data = JSON.parse(require(\\\"fs\\\").readFileSync(\\\"/tmp/.claude.json.host\\\", \\\"utf8\\\"));\n\
    delete data.projects;\n\
    delete data.githubRepoPaths;\n\
    require(\\\"fs\\\").writeFileSync(\\\"/home/claude/.claude.json\\\", JSON.stringify(data, null, 2));\n\
  " 2>/dev/null || cp /tmp/.claude.json.host /home/claude/.claude.json\n\
fi\n\
\n\
# 終了時: 認証情報と .claude.json を永続化ディレクトリに保存\n\
persist_credentials() {\n\
  cp /home/claude/.claude/.credentials.json /home/claude/.claude-auth/.credentials.json 2>/dev/null\n\
  node -e "\n\
    const data = JSON.parse(require(\\\"fs\\\").readFileSync(\\\"/home/claude/.claude.json\\\", \\\"utf8\\\"));\n\
    delete data.projects;\n\
    delete data.githubRepoPaths;\n\
    require(\\\"fs\\\").writeFileSync(\\\"/home/claude/.claude-auth/claude.json\\\", JSON.stringify(data, null, 2));\n\
  " 2>/dev/null\n\
}\n\
trap persist_credentials EXIT INT TERM\n\
\n\
CONTINUE_FLAG=""\n\
if [ "${CLAUDE_CONTINUE:-}" = "1" ]; then\n\
  CONTINUE_FLAG="-c"\n\
fi\n\
\n\
# exec しない（trap を効かせるため）。claude 終了後に persist_credentials が実行される\n\
claude $CONTINUE_FLAG --dangerously-skip-permissions --channels plugin:discord@claude-plugins-official\n' \
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

# 変更後（v2.1.209対応スキーマ）
RUN echo '{"claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins-official"},"installLocation":"/home/claude/.claude/plugins/marketplaces/claude-plugins-official","lastUpdated":"2026-07-01T00:00:00.000Z"}}' \
    > /home/claude/.claude/plugins/known_marketplaces.json

RUN echo '{"version":2,"plugins":{"discord@claude-plugins-official":[{"scope":"user","installPath":"/home/claude/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/discord","version":"0.0.4","installedAt":"2026-01-01T00:00:00.000Z","lastUpdated":"2026-01-01T00:00:00.000Z"}]}}' \
    > /home/claude/.claude/plugins/installed_plugins.json

# installed_plugins.json だけではプラグインが disabled 扱いになるため、明示的に有効化する
RUN node -e "const f='/home/claude/.claude/settings.json',fs=require('fs'); \
    const d=fs.existsSync(f)?JSON.parse(fs.readFileSync(f,'utf8')):{}; \
    d.enabledPlugins={...(d.enabledPlugins||{}),'discord@claude-plugins-official':true}; \
    fs.writeFileSync(f,JSON.stringify(d,null,2))"

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
