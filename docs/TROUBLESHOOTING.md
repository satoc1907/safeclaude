# safeclaudediscord トラブルシューティング記録

## 概要

safeclaudediscord（Docker内でClaude Code + Discord pluginを実行する環境）に対して、以下2つの課題に取り組んだ記録。

1. **RTK（Rust Token Killer）の導入** — LLMトークン消費を60-90%削減するCLIプロキシ
2. **Enterキーが効かなくなる問題の解決** — Docker起動時にBypass Permissions確認画面で入力がブロックされる

---

## Part 1: RTK導入

### RTKとは

- LLMのトークン消費を60-90%削減するCLIプロキシツール
- Rustで書かれたシングルバイナリ、依存関係ゼロ、オーバーヘッド <10ms
- シェルコマンド出力をフィルタリング・圧縮してからLLMコンテキストに渡す
- GitHub: https://github.com/rtk-ai/rtk (★19.5k)

### 前提条件

- safeclaudeはDocker内でClaude Codeを動かすため、**rtkもコンテナ内にインストールする必要がある**
- ベースイメージ: `node:22-slim`（Debian Bookworm, GLIBC 2.36）
- ホストマシン: Apple Silicon Mac (aarch64)

---

### 試行1: install.sh を使う ❌

```dockerfile
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
ENV PATH="/home/claude/.local/bin:$PATH"
RUN rtk init -g
```

**エラー:**
```
rtk: /lib/aarch64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by rtk)
```

**原因:** install.shがダウンロードするプリビルドバイナリ（`rtk-aarch64-unknown-linux-gnu`）はGLIBC 2.39を要求。`node:22-slim`（Bookworm）のGLIBCは2.36で不足。

---

### 試行2: musl版バイナリを直接ダウンロード ❌

```dockerfile
RUN curl -fsSL -o /tmp/rtk.tar.gz \
    https://github.com/rtk-ai/rtk/releases/latest/download/rtk-aarch64-unknown-linux-musl.tar.gz \
    && tar xzf /tmp/rtk.tar.gz -C /home/claude/.local/bin \
    && rm /tmp/rtk.tar.gz
```

**エラー:**
```
curl: (22) The requested URL returned error: 404
```

**原因:** RTKのリリースアセットにaarch64-musl版が存在しない。

| アセット | aarch64 | x86_64 |
|---------|---------|--------|
| gnu版   | ✅ あり（GLIBC 2.39必要） | ✅ あり |
| musl版  | ❌ なし | ✅ あり |

---

### 試行3: マルチステージビルド（rust:latest → node:22-slim） ❌

```dockerfile
FROM rust:latest AS rtk-builder
RUN cargo install --git https://github.com/rtk-ai/rtk

FROM node:22-slim
# ...
COPY --from=rtk-builder /usr/local/cargo/bin/rtk /home/claude/.local/bin/rtk
RUN rtk init -g
```

**エラー:**
```
rtk: /lib/aarch64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by rtk)
```

**原因:** `rust:latest`はDebian Trixie（GLIBC 2.40）ベース。そこでビルドされたバイナリはGLIBC 2.39+を動的リンクするため、コピー先の`node:22-slim`（Bookworm, GLIBC 2.36）では動かない。

---

### 試行4: ベースイメージをDebian Trixieに変更 ❌（ビルド成功するがTTY問題発生）

```dockerfile
FROM rust:latest AS rtk-builder
RUN cargo install --git https://github.com/rtk-ai/rtk

FROM node:22-slim AS node-donor
FROM debian:trixie-slim

COPY --from=node-donor /usr/local /usr/local
# ...
COPY --from=rtk-builder /usr/local/cargo/bin/rtk /home/claude/.local/bin/rtk
RUN rtk init -g
```

**結果:** ビルドは成功。しかしコンテナ起動後、Bypass Permissions確認画面でEnterキーが効かない。矢印キーで選択はできるが、確定できない。

**原因:** `debian:trixie-slim`のutil-linux（`script`コマンド）やターミナル関連パッケージの挙動が`node:22-slim`（Bookworm）と異なり、TTY入力処理が壊れた。

---

### 試行5: rust:alpine でmusl静的リンクビルド ✅

```dockerfile
# ---- ステージ1: rtkをAlpine(musl)で静的リンクビルド ----
FROM rust:alpine AS rtk-builder
RUN apk add --no-cache musl-dev
RUN cargo install --git https://github.com/rtk-ai/rtk

# ---- ステージ2: 本体 (node:22-slim = Bookwormのまま) ----
FROM node:22-slim
# ...（既存の構成そのまま）
RUN mkdir -p /home/claude/.local/bin
COPY --from=rtk-builder /usr/local/cargo/bin/rtk /home/claude/.local/bin/rtk
ENV PATH="/home/claude/.local/bin:$PATH"
RUN rtk init -g
```

**結果:** ✅ ビルド成功、rtkバイナリ動作確認OK

**ポイント:**
- `rust:alpine`はmusl libcをネイティブに使うため、`cargo install`するだけでGLIBC依存のない静的リンクバイナリが生成される
- ベースイメージを`node:22-slim`のまま維持できるので、TTY問題が発生しない
- 初回ビルドはRustコンパイルで5-10分かかるが、Dockerレイヤーキャッシュが効くので2回目以降は速い

### RTK導入の問題まとめ

| 問題 | 原因 |
|------|------|
| プリビルドバイナリが動かない | GLIBC 2.39要求 vs Bookworm の GLIBC 2.36 |
| musl版で回避できない | aarch64-musl版がリリースに存在しない |
| ソースビルドしても動かない | rust:latest(Trixie)でビルド → node:22-slim(Bookworm)で実行のGLIBC不整合 |
| ベースイメージ変更で動くがTTY壊れる | debian:trixie-slimのターミナル挙動の違い |
| **解決策** | **rust:alpineでmusl静的リンクビルドし、node:22-slimにコピー** |

---

## Part 2: Enterキーが効かない問題

RTK導入作業中に発生し、RTK有無に関わらず再現するようになった問題。

### 症状

- `safeclaudediscord`起動後、Bypass Permissions確認画面が表示される
- 矢印キーで選択肢の移動はできる
- Enterキーを押しても反応がなく、先に進めない

### 切り分け手順

#### 1. ENTRYPOINTの問題か？

```bash
# ENTRYPOINTを無視してbashで入る
docker run --rm -it --entrypoint bash safeclaudediscord

# コンテナ内で直接claudeを起動
claude --dangerously-skip-permissions --channels plugin:discord@claude-plugins-official
```

**結果:** Enterが効く。ログインも成功。→ ENTRYPOINT自体は問題なし

#### 2. PID 1の問題か？

ENTRYPOINTを以下の形式で試行：

```dockerfile
# scriptラッパー（元々の形式）
ENTRYPOINT ["script", "-c", "claude ...", "/dev/null"]

# 直接実行
ENTRYPOINT ["claude", "--dangerously-skip-permissions", ...]

# bash -lc経由
ENTRYPOINT ["/bin/bash", "-lc", "claude ..."]

# docker run --init追加
docker run --rm -it --init ...
```

**結果:** すべて ❌ → ENTRYPOINTの形式は関係なし

#### 3. ボリュームマウントの問題か？

```bash
# マウント無しで直接起動
docker run --rm -it safeclaudediscord
```

**結果:** ✅ Enterが効く → **ボリュームマウントのどれかが原因**

#### 4. どのマウントが原因か？（1つずつ追加）

| # | 追加したマウント | 結果 |
|---|-----------------|------|
| 1 | `-v "$(pwd):/workspace:rw"` | ✅ OK |
| 2 | `-v "$HOME/.claude/.credentials.json:..."` | ✅ OK |
| 3 | `-v "$HOME/.claude/settings.json:...:ro"` | ✅ OK |
| 4 | `-v "$HOME/.claude/config.json:...:ro"` | ✅ OK |
| 5 | `-v "$HOME/.claude/channels:..."` | ✅ OK |
| 6 | `-v "$HOME/.claude.json:/home/claude/.claude.json"` | ❌ **ここで止まる** |

**犯人: `~/.claude.json` のマウント**

#### 5. read-onlyにすれば解決するか？

```bash
CONFIG_MOUNTS+=(-v "$HOME/.claude.json:/home/claude/.claude.json:ro")
```

**結果:** ❌ まだ止まる → ファイルの中身自体が問題

### 根本原因

`~/.claude.json`にはホスト側の以下の情報が含まれている：

- `numStartups`（起動回数カウンタ — 書き込みが発生）
- `projects`（ホスト側のパス `/Users/satoc/...` が多数記録されている）
- `cachedGrowthBookFeatures`（大量のfeature flag）
- `oauthAccount`（認証アカウント情報）
- セッション履歴、メトリクス等

このファイルをコンテナ内にマウントすると、Claude Codeが起動時にホスト側パスの解決やファイル書き込みを試み、コンテナ環境との不整合でイベントループがブロックされる。

### 解決策

`safeclaudediscord.sh`で`.claude.json`のマウントをコメントアウト：

```bash
# .claude.json はコンテナ内にマウントしない
# ホスト側のパス情報やセッション履歴がコンテナ内のClaude Codeの起動をブロックする
#if [[ -f "$HOME/.claude.json" ]]; then
#    CONFIG_MOUNTS+=(-v "$HOME/.claude.json:/home/claude/.claude.json")
#fi
```

**認証情報は`.credentials.json`で別途マウント済みなので、`.claude.json`をマウントしなくても動作に問題はない。** コンテナ内では新規に`.claude.json`が自動生成される。

---

## 最終的なファイル構成

### Dockerfile（RTK版）

```dockerfile
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

# ... (bun, uv, ユーザー作成、プラグイン設定は省略) ...

# rtk バイナリをビルドステージからコピー（musl静的リンク済み）
RUN mkdir -p /home/claude/.local/bin
COPY --from=rtk-builder /usr/local/cargo/bin/rtk /home/claude/.local/bin/rtk
ENV PATH="/home/claude/.local/bin:$PATH"
RUN rtk init -g

WORKDIR /workspace

ENTRYPOINT ["script", "-c", "claude --dangerously-skip-permissions --channels plugin:discord@claude-plugins-official", "/dev/null"]
```

### safeclaudediscord.sh の変更点

```bash
# .claude.json はマウントしない（コンテナ起動をブロックするため）
#if [[ -f "$HOME/.claude.json" ]]; then
#    CONFIG_MOUNTS+=(-v "$HOME/.claude.json:/home/claude/.claude.json")
#fi
```

---

## ビルド・運用コマンド

```bash
# 通常ビルド
safeclaudediscord --build

# キャッシュなしビルド（問題発生時）
docker build --no-cache -t safeclaudediscord .

# 起動
safeclaudediscord
safeclaudediscord ~/projects/myapp

# デバッグ: コンテナ内にbashで入る
docker run --rm -it --entrypoint bash safeclaudediscord

# rtk動作確認（コンテナ内で実行）
rtk --version
rtk init --show
rtk gain
```

---

## 教訓

1. **GLIBC依存は`rust:alpine`でmusl静的リンクビルドすれば完全に回避できる**
2. **Dockerのベースイメージ変更はターミナル挙動に影響するため、安易に変えない**
3. **Docker起動の不具合は、ボリュームマウントを1つずつ追加して切り分けるのが確実**
4. **`~/.claude.json`はホスト固有の情報を多数含むため、Dockerコンテナにマウントしてはいけない**
5. **認証に必要なのは`.credentials.json`だけで、`.claude.json`は不要**
