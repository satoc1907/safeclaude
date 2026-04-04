#!/bin/bash
set -euo pipefail

INSTALL_DIR="$HOME/.safeclaudediscord"                          # ① 変更
REPO_URL="https://github.com/satoc1907/safeclaude.git" # ② 変更

echo "=== SafeClaude Discord Installer ==="                     # ③ 変更

# Check dependencies
if ! command -v docker &>/dev/null; then
    echo "Error: docker が見つかりません。先にDockerをインストールしてください。" >&2
    exit 1
fi

if ! command -v git &>/dev/null; then
    echo "Error: git が見つかりません。" >&2
    exit 1
fi

# Clone or update
if [[ -d "$INSTALL_DIR" ]]; then
    echo "既存のインストールを更新中..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    echo "ダウンロード中..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

# Build Docker image
echo "Dockerイメージをビルド中..."
docker build -t safeclaudediscord "$INSTALL_DIR"               # ④ 変更

# Install command to PATH
LINK_PATH="/usr/local/bin/safeclaudediscord"                   # ⑤ 変更
if [[ -w /usr/local/bin ]]; then
    ln -sf "$INSTALL_DIR/safeclaudediscord.sh" "$LINK_PATH"    # ⑥ 変更
else
    echo "シンボリックリンクの作成に sudo が必要です..."
    sudo ln -sf "$INSTALL_DIR/safeclaudediscord.sh" "$LINK_PATH" # ⑦ 変更
fi

echo ""
echo "インストール完了!"
echo "使い方: safeclaudediscord [ワーキングディレクトリ]"        # ⑧ 変更
echo ""
echo "例:"
echo "  safeclaudediscord                    # カレントディレクトリで起動"
echo "  safeclaudediscord ~/projects/myapp   # 指定ディレクトリで起動"