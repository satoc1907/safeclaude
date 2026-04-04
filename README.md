# SafeClaude Discord (fork)

> This is a fork of [shi3z/safeclaude](https://github.com/shi3z/safeclaude),
> adding Discord Channels support via `--channels plugin:discord@claude-plugins-official`.
> Runs as `safeclaudediscord` so it can coexist with the original `safeclaude`.

## Discord の事前設定（初回のみ・ホスト側で実施）

通常の Claude Code セッション上で以下を実行します。
```bash
/plugin install discord@claude-plugins-official
/discord:configure YOUR_BOT_TOKEN
/discord:access policy allowlist
```

設定後は `safeclaudediscord` を起動するだけで Discord Bot が自動でオンラインになります。

---


# SafeClaude

> [!CAUTION]
> This software is provided "as is", without warranty of any kind. The authors assume no responsibility for any damage, data loss, or security incidents caused by the use of this tool. Use entirely at your own risk.

Run Claude Code safely inside Docker. Restrict host access to a minimum — only the designated workspace directory is writable.

## Install
```bash
curl -fsSL https://raw.githubusercontent.com/satoc1907/safeclaude/feature/discord-channels/install.sh | bash
```

## Requirements

- Docker
- `ANTHROPIC_API_KEY` environment variable

## Usage
```bash
# Start in current directory
safeclaudediscord

# Start in a specific project directory
safeclaudediscord ~/projects/myapp

# Add read-only directories
safeclaudediscord ~/projects/myapp -r ~/projects/shared-lib -r ~/data
```

## Security Model

| Target | Container Path | Permission |
|---|---|---|
| Workspace directory | `/workspace` | Read-Write |
| Directories specified with `-r` | `/readonly/<name>` | Read-Only |
| All other host files | Not mounted | No access |

- Host filesystem is **not** mounted by default, minimizing data leakage risk
- Network is enabled (needed for pip install, npm install, etc.) but accessible data is restricted
- Claude Code runs with `--dangerously-skip-permissions` inside the container

## Options

```
-b, --build     Force rebuild Docker image
-r, --ro-dir    Add read-only directory (can be specified multiple times)
-h, --help      Show help
```

## License

MIT
