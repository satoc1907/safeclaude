# RTK (Rust Token Killer) を safeclaude に導入する手順

## RTKとは

- LLMのトークン消費を60〜90%削減するCLIプロキシツール
- Rustで書かれたシングルバイナリ、依存関係ゼロ、オーバーヘッド <10ms
- シェルコマンドの出力をフィルタリング・圧縮してからLLMのコンテキストに渡す
- GitHub: https://github.com/rtk-ai/rtk (★19.5k)

## safeclaude の構成

- Docker内でClaude Codeを実行する環境（shi3z/safeclaude のfork）
- Discord Channels プラグイン対応版（safeclaudediscord）
- ベースイメージ: `node:22-slim`（Debian Bookworm, GLIBC 2.36）

## 導入の試行錯誤

### 試行1: install.sh を使う

```dockerfile
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
ENV PATH="/home/claude/.local/bin:$PATH"
RUN rtk init -g
```

**結果: ❌ 失敗**

```
rtk: /lib/aarch64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by rtk)
```

**原因:** install.sh がダウンロードするプリビルドバイナリ（`rtk-aarch64-unknown-linux-gnu`）は GLIBC 2.39 を要求するが、`node:22-slim`（Debian Bookworm）の GLIBC は 2.36。

---

### 試行2: musl 版バイナリを直接ダウンロード

```dockerfile
RUN curl -fsSL -o /tmp/rtk.tar.gz \
    https://github.com/rtk-ai/rtk/releases/latest/download/rtk-aarch64-unknown-linux-musl.tar.gz \
    && tar xzf /tmp/rtk.tar.gz -C /home/claude/.local/bin \
    && rm /tmp/rtk.tar.gz
ENV PATH="/home/claude/.local/bin:$PATH"
RUN rtk init -g
```

**結果: ❌ 失敗（404エラー）**

```
curl: (22) The requested URL returned error: 404
```

**原因:** RTKのリリースアセットには `aarch64-unknown-linux-musl` 版が存在しない。musl版は `x86_64-unknown-linux-musl` のみ提供されている。

利用可能なLinuxバイナリ:
- `rtk-x86_64-unknown-linux-musl.tar.gz` ← x86_64のみmusl版あり
- `rtk-aarch64-unknown-linux-gnu.tar.gz` ← aarch64はgnu版のみ（GLIBC 2.39必要）

---

### 試行3: マルチステージビルドでソースからコンパイル

```dockerfile
FROM rust:latest AS rtk-builder
RUN cargo install --git https://github.com/rtk-ai/rtk

FROM node:22-slim
# ...
COPY --from=rtk-builder /usr/local/cargo/bin/rtk /home/claude/.local/bin/rtk
ENV PATH="/home/claude/.local/bin:$PATH"
RUN rtk init -g
```

**結果: ❌ 失敗**

```
rtk: /lib/aarch64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by rtk)
```

**原因:** `rust:latest` は Debian Trixie ベース（GLIBC 2.40）でビルドされるため、生成されたバイナリは GLIBC 2.39+ を要求する。コピー先の `node:22-slim`（Bookworm, GLIBC 2.36）では動かない。

---

### 試行4: ベースイメージを Debian Trixie に変更 ✅

**解決策:** ランタイム側のベースイメージを `debian:trixie-slim`（GLIBC 2.40）に変更し、Node.js は `node:22-slim` からバイナリコピーする。

```dockerfile
# ---- ステージ1: rtkをソースからビルド ----
FROM rust:latest AS rtk-builder
RUN cargo install --git https://github.com/rtk-ai/rtk

# ---- ステージ2: 本体 (Debian Trixie = GLIBC 2.40) ----
FROM node:22-slim AS node-donor
FROM debian:trixie-slim

# Node.js をnode公式イメージからコピー
COPY --from=node-donor /usr/local /usr/local

RUN apt-get update && apt-get install -y \
    git curl vim ripgrep unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
ENV PATH="/root/.bun/bin:$PATH"

RUN useradd -m -s /bin/bash claude
RUN mkdir -p /host /workspace && chown claude:claude /workspace

USER claude

RUN mkdir -p /home/claude/.bun/bin && \
    ln -sf /usr/local/bin/bun /home/claude/.bun/bin/bun
ENV PATH="/home/claude/.bun/bin:$PATH"

# プラグインをイメージ内に焼き込む
RUN mkdir -p /home/claude/.claude/plugins/marketplaces && \
    git clone https://github.com/anthropics/claude-plugins-official.git \
    /home/claude/.claude/plugins/marketplaces/claude-plugins-official

RUN echo '{"claude-plugins-official":{"url":"...","installLocation":"..."}}' \
    > /home/claude/.claude/plugins/known_marketplaces.json

RUN echo '{"version":2,"plugins":{"discord@claude-plugins-official":[...]}}' \
    > /home/claude/.claude/plugins/installed_plugins.json

# rtk バイナリをビルドステージからコピー
RUN mkdir -p /home/claude/.local/bin
COPY --from=rtk-builder /usr/local/cargo/bin/rtk /home/claude/.local/bin/rtk
ENV PATH="/home/claude/.local/bin:$PATH"
RUN rtk init -g

WORKDIR /workspace

ENTRYPOINT ["script", "-c", "claude --dangerously-skip-permissions --channels plugin:discord@claude-plugins-official", "/dev/null"]
```

**結果: ✅ ビルド成功**

---

## 問題の根本原因まとめ

| 問題 | 原因 |
|------|------|
| プリビルドバイナリが動かない | GLIBC 2.39要求 vs Bookworm の GLIBC 2.36 |
| musl版で回避できない | aarch64-musl版がリリースに存在しない |
| ソースビルドしても動かない | rust:latest(Trixie)でビルド → node:22-slim(Bookworm)で実行のGLIBC不整合 |
| **解決策** | **ランタイムもTrixieベースにしてGLIBCを統一** |

## ビルド時の注意

- 初回ビルドはRustコンパイルで5〜10分程度かかる
- ステージ1（rtk-builder）はDockerのレイヤーキャッシュが効くので2回目以降は速い
- `safeclaudediscord --build` で再ビルド

## 動作確認

コンテナ内で以下を確認:

```bash
rtk --version      # バージョン表示
rtk init --show    # hookが正しく設定されているか確認
rtk gain           # トークン節約統計
```

Claude Codeが `git status` 等を実行すると、自動的に `rtk git status` にリライトされ、圧縮された出力がコンテキストに渡される。
