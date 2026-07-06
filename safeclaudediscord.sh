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
  -c, --continue  前回のセッションを再開（claude -c 相当）
  -e, --env       環境変数をコンテナに渡す (複数指定可、形式: KEY=VALUE)
  -r, --ro-dir    追加の読み取り専用マウント (複数指定可)
  -g, --gpus      GPUをコンテナに渡す (docker run --gpus all / NVIDIA Container Toolkit必要)
      --boltz     Boltz-2実行環境を永続マウント (~/.boltz, ~/venvs/boltz2-spark, CUDA toolkit)
  -h, --help      このヘルプを表示

Examples:
  $(basename "$0")                          # カレントディレクトリで起動（新規セッション）
  $(basename "$0") -c                       # 前回のセッションを再開
  $(basename "$0") ~/projects/myapp         # 指定ディレクトリで起動
  $(basename "$0") -c ~/projects/myapp      # 指定ディレクトリで前回セッション再開
  $(basename "$0") -b ~/projects/myapp      # イメージ再ビルドして起動
  $(basename "$0") -e IBM_QUANTUM_TOKEN=xxx  # 環境変数を渡して起動

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
CONTINUE_SESSION=false
USE_GPU=false
MOUNT_BOLTZ=false
EXTRA_RO_MOUNTS=()
ENV_OPTS=()
WORKSPACE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--build)
            FORCE_BUILD=true
            shift
            ;;
        -c|--continue)
            CONTINUE_SESSION=true
            shift
            ;;
        -e|--env)
            ENV_OPTS+=(-e "$2")
            shift 2
            ;;
        -r|--ro-dir)
            EXTRA_RO_MOUNTS+=("$2")
            shift 2
            ;;
        -g|--gpus)
            USE_GPU=true
            shift
            ;;
        --boltz)
            MOUNT_BOLTZ=true
            shift
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
echo "  Memory (会話履歴): $WORKSPACE_DIR/.claude-memory"
if [[ "$CONTINUE_SESSION" == true ]]; then
    echo "  Mode: 前回セッション再開 (-c)"
fi
for envfile in "$HOME/.safeclaude.env" "$WORKSPACE_DIR/.env"; do
    if [[ -f "$envfile" ]]; then
        echo "  Env: $envfile"
    fi
done
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
# ENV_OPTS は引数パース前に定義済み（-e フラグで追記されるため再初期化しない）
#if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
#   ENV_OPTS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
#fi

# -c オプション: 前回セッション再開
if [[ "$CONTINUE_SESSION" == true ]]; then
    ENV_OPTS+=(-e "CLAUDE_CONTINUE=1")
fi

# .env ファイルから環境変数を自動読み込み
# ~/.safeclaude.env: マシン共通の秘密情報（APIトークン等）
# $WORKSPACE_DIR/.env: プロジェクト固有の環境変数
for envfile in "$HOME/.safeclaude.env" "$WORKSPACE_DIR/.env"; do
    if [[ -f "$envfile" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            ENV_OPTS+=(-e "$line")
        done < "$envfile"
    fi
done

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
# STATUS.md 更新規約をユーザーメモリとして注入（全セッション共通）
if [[ -f "$SCRIPT_DIR/claude-global.md" ]]; then
    CONFIG_MOUNTS+=(-v "$SCRIPT_DIR/claude-global.md:/home/claude/.claude/CLAUDE.md:ro")
fi

if [[ -d "$HOME/.claude/channels" ]]; then
    CONFIG_MOUNTS+=(-v "$HOME/.claude/channels:/home/claude/.claude/channels")
fi
# .claude.json は直接マウントするとホスト固有パス情報でClaude Codeの起動がブロックされるため、
# 一時パスにread-onlyでマウントし、entrypoint.sh がフィルタしてからコピーする
if [[ -f "$HOME/.claude.json" ]]; then
    CONFIG_MOUNTS+=(-v "$HOME/.claude.json:/tmp/.claude.json.host:ro")
fi
# 会話履歴の永続化（-c による再開に必要）
# ワークスペース直下の .claude-memory に保存し、別マシン（MacBook / DGX Spark など）で
# 同じワークスペースを開けば履歴を引き継げるようにする。
# Dropbox/git 等での同期を前提とし、両マシンの safeclaudediscord.sh を揃えること。
MEMORY_DIR="$WORKSPACE_DIR/.claude-memory"
mkdir -p "$MEMORY_DIR"
CONFIG_MOUNTS+=(-v "$MEMORY_DIR:/home/claude/.claude/projects")

# GPU pass-through (opt-in)。NVIDIA Container Toolkit がホストに必要。
GPU_OPTS=()
if [[ "$USE_GPU" == true ]]; then
    GPU_OPTS+=(--gpus all)
    echo "  GPU: 有効 (--gpus all)"
fi

# Boltz-2 実行環境の永続マウント (opt-in)
# venv はパス依存があるため、コンテナ内も同一パス /home/claude/venvs/boltz2-spark に合わせる。
BOLTZ_MOUNTS=()
if [[ "$MOUNT_BOLTZ" == true ]]; then
    # モデル重み（読むだけ・7.6GB）
    if [[ -d "$HOME/.boltz" ]]; then
        BOLTZ_MOUNTS+=(-v "$HOME/.boltz:/home/claude/.boltz:ro")
        echo "  Boltz重み: $HOME/.boltz (ro)"
    else
        echo "Warning: $HOME/.boltz が見つかりません（初回はコンテナ内でDL要）" >&2
    fi
    # venv（読み書き）。無ければスキップ（初回セットアップで作る想定）
    if [[ -d "$HOME/venvs/boltz2-spark" ]]; then
        BOLTZ_MOUNTS+=(-v "$HOME/venvs/boltz2-spark:/home/claude/venvs/boltz2-spark:rw")
        echo "  Boltz venv: $HOME/venvs/boltz2-spark (rw)"
    else
        echo "Note: $HOME/venvs/boltz2-spark が未作成。初回セットアップで作成してください。" >&2
        # 空でもマウントできるよう、ホスト側ディレクトリを用意しておく
        mkdir -p "$HOME/venvs/boltz2-spark"
        BOLTZ_MOUNTS+=(-v "$HOME/venvs/boltz2-spark:/home/claude/venvs/boltz2-spark:rw")
    fi
    # CUDA toolkit（ptxas 等）。sm_121 の PTX JIT に必須。--gpus はドライバは渡すが
    # /usr/local/cuda（toolkit本体）は渡さないため、明示的に read-only マウントする。
    if [[ -d "/usr/local/cuda" ]]; then
        BOLTZ_MOUNTS+=(-v "/usr/local/cuda:/usr/local/cuda:ro")
        echo "  CUDA toolkit: /usr/local/cuda (ro)"
    fi
fi

# Run container
exec docker run \
    --rm \
    -it \
    --name "$CONTAINER_NAME" \
    ${GPU_OPTS[@]:+"${GPU_OPTS[@]}"} \
    ${BOLTZ_MOUNTS[@]:+"${BOLTZ_MOUNTS[@]}"} \
    "${MOUNT_OPTS[@]}" \
    ${ENV_OPTS[@]:+"${ENV_OPTS[@]}"} \
    ${CONFIG_MOUNTS[@]:+"${CONFIG_MOUNTS[@]}"} \
    "$IMAGE_NAME"