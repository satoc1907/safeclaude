#!/bin/bash
set -euo pipefail

# シンボリックリンクを解決して実際のスクリプトの場所を取得
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
IMAGE_NAME="safeclaudediscord"
CONTAINER_NAME="safeclaude-$$"

# Usage
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [WORKSPACE_DIR]

Docker上でClaude Codeを安全に実行します。
ホストのファイルは読み取り専用、指定ディレクトリのみ書き込み可能。

Arguments:
  WORKSPACE_DIR   書き込み可能なワーキングディレクトリ (デフォルト: カレントディレクトリ)

Options:
  -b, --build     Dockerイメージを強制的に再ビルド
  -r, --ro-dir    追加の読み取り専用マウント (複数指定可)
  -h, --help      このヘルプを表示

Examples:
  $(basename "$0")                          # カレントディレクトリで起動
  $(basename "$0") ~/projects/myapp         # 指定ディレクトリで起動
  $(basename "$0") -b ~/projects/myapp      # イメージ再ビルドして起動

Security:
  - ホスト全体はマウントしない (情報漏洩防止)
  - WORKSPACE_DIR のみ /workspace に読み書き可能でマウント
  - -r で指定したディレクトリのみ /readonly/* に読み取り専用でマウント
  - Claude Code は --dangerously-skip-permissions で起動
  - ネットワークは有効だが、送れる情報を最小限に制限
EOF
    exit 0
}

# Parse arguments
FORCE_BUILD=false
EXTRA_RO_MOUNTS=()
WORKSPACE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--build)
            FORCE_BUILD=true
            shift
            ;;
        -r|--ro-dir)
            EXTRA_RO_MOUNTS+=("$2")
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Error: Unknown option $1" >&2
            usage
            ;;
        *)
            WORKSPACE_DIR="$1"
            shift
            ;;
    esac
done

# Default workspace to current directory
if [[ -z "$WORKSPACE_DIR" ]]; then
    WORKSPACE_DIR="$(pwd)"
fi

# Resolve to absolute path
WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" 2>/dev/null && pwd)" || {
    echo "Error: ディレクトリが存在しません: $WORKSPACE_DIR" >&2
    exit 1
}

echo "=== SafeClaude ==="
echo "  Workspace (読み書き可): $WORKSPACE_DIR"
if [[ ${#EXTRA_RO_MOUNTS[@]} -gt 0 ]]; then
    for d in "${EXTRA_RO_MOUNTS[@]}"; do
        echo "  ReadOnly: $d"
    done
fi
echo ""

# Build image if needed
if [[ "$FORCE_BUILD" == true ]] || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Dockerイメージをビルド中..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    echo ""
fi

# Construct mount options
MOUNT_OPTS=(
    # Workspace: read-write
    -v "$WORKSPACE_DIR:/workspace:rw"
)

# Add read-only mounts (only explicitly specified directories)
for ro_dir in "${EXTRA_RO_MOUNTS[@]:-}"; do
    abs_ro="$(cd "$ro_dir" 2>/dev/null && pwd)" || {
        echo "Warning: 読み取り専用ディレクトリが見つかりません: $ro_dir" >&2
        continue
    }
    mount_point="/readonly/$(basename "$abs_ro")"
    MOUNT_OPTS+=(-v "$abs_ro:$mount_point:ro")
done

# Pass through API key
ENV_OPTS=()
#if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
#   ENV_OPTS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
#fi

# .credentials.json がなければ空ファイルを作成（コンテナ内のログイン結果を永続化するため）
if [[ ! -f "$HOME/.claude/.credentials.json" ]]; then
    touch "$HOME/.claude/.credentials.json"
fi

# Pass through Claude config if it exists
# pluginsはコンテナ内で管理するためマウントから除外
CONFIG_MOUNTS=()
# 認証情報のみ明示的にマウント
if [[ -f "$HOME/.claude/.credentials.json" ]]; then
    CONFIG_MOUNTS+=(-v "$HOME/.claude/.credentials.json:/home/claude/.claude/.credentials.json")
fi
if [[ -f "$HOME/.claude/config.json" ]]; then
    CONFIG_MOUNTS+=(-v "$HOME/.claude/config.json:/home/claude/.claude/config.json:ro")
fi
if [[ -f "$HOME/.claude/settings.json" ]]; then
    CONFIG_MOUNTS+=(-v "$HOME/.claude/settings.json:/home/claude/.claude/settings.json:ro")
fi
if [[ -d "$HOME/.claude/channels" ]]; then
    CONFIG_MOUNTS+=(-v "$HOME/.claude/channels:/home/claude/.claude/channels")
fi
# .claude.json は直接マウントするとホスト固有パス情報でClaude Codeの起動がブロックされるため、
# 一時パスにread-onlyでマウントし、entrypoint.sh がフィルタしてからコピーする
if [[ -f "$HOME/.claude.json" ]]; then
    CONFIG_MOUNTS+=(-v "$HOME/.claude.json:/tmp/.claude.json.host:ro")
fi

# Run container
exec docker run \
    --rm \
    -it \
    --name "$CONTAINER_NAME" \
    "${MOUNT_OPTS[@]}" \
    ${ENV_OPTS[@]:+"${ENV_OPTS[@]}"} \
    ${CONFIG_MOUNTS[@]:+"${CONFIG_MOUNTS[@]}"} \
    "$IMAGE_NAME"
