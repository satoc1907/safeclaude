# base を Ubuntu 24.04 化して GB10/sm_121 torch を動作可能にした作業まとめ

- 日付: 2026-07-03
- ブランチ: `feature/rtk-linux-gpu-boltz`
- 対象: `Dockerfile`（イメージ `safeclaudediscord`）
- 実機: DGX Spark（GB10, sm_121, CUDA 13）

## 背景 / 問題

コンテナ base の `node:22-slim`（Debian 12 bookworm, **glibc 2.36**）が、GB10(sm_121) 向け
torch native wheel の要求（**glibc 2.38 / GLIBCXX_3.4.32**、Ubuntu 24.04向けビルド）を満たさず、
`import torch` が ABI エラーで失敗していた。さらに通常 PyPI の cu128 wheel は native SASS が
sm_120 止まりのため、GB10 では PTX JIT フォールバックでハングしていた（＝実運用 wheel での検証が必須）。

## 調査で判明したこと

- コミット `f1e3101` で一度 `debian:trixie-slim` 化されていたが、その後 rtk を musl 静的リンク化した際に
  base が `node:22-slim` に巻き戻され、glibc の後ろ盾も失われていた。
- Node.js は base の node イメージが供給しており、base を変えると入れ直しが必要。
  `f1e3101` の **node-donor 方式**（`COPY --from=node:22-slim /usr/local`）が実績のある確保手段。

## 変更内容（Dockerfile）

| # | 変更 | 理由 |
|---|---|---|
| 1 | `FROM node:22-slim` → `FROM ubuntu:24.04` | glibc 2.39 / GLIBCXX_3.4.32 を確保（wheel の Ubuntu 24.04 ABI に合わせる） |
| 2 | `node:22-slim` を `node-donor` ステージ化し `COPY /usr/local` | Ubuntu base に無い Node.js を移植（f1e3101 の方式を復活） |
| 3 | `userdel -r ubuntu` を追加 | Ubuntu 24.04 標準の uid1000 `ubuntu` と `claude`(uid1000) の衝突回避 |
| 4 | apt に `libopenblas0` `libnuma1` を追加 | sm_121 native wheel が非同梱で動的リンクするランタイム依存 |

- rtk(musl静的)・multi-stage・プラグイン焼き込み・claude(uid1000)・entrypoint 生成ロジックは **すべて不変**。
- CUDA runtime libs（`libcudart.so.13` 等）は base ではなく、`--boltz` の `/usr/local/cuda:ro` マウントで供給（CUDA 13 系必須）。

## トラブルシュートの経過（玉ねぎの皮を順に）

1. glibc 2.36 < 2.38 / GLIBCXX 不足 → base を ubuntu:24.04 に。→ ✅ 解消
2. `libcudart.so.13 not found` → `/usr/local/cuda:ro` をマウント。→ ✅ CUDA13 供給
3. `libopenblas.so.0 not found` → apt `libopenblas0`。→ ✅
4. `libnuma.so.1 not found` → apt `libnuma1`。→ ✅

## 検証結果（実機）

実運用 wheel `torch-2.12.0a0+gitb071fd7`（Qanatpharma sm_121, cp312/aarch64）を CUDA13 マウント下で:

```
ldd --version                 => Ubuntu GLIBC 2.39
strings libstdc++.so.6        => GLIBCXX_3.4.32 ヒット
torch.__version__             => 2.12.0a0+gitb071fd7
torch.cuda.is_available()     => True
torch.cuda.get_device_capability(0) => (12, 1)   # GB10=sm_121 認識
2048² matmul                  => matmul OK（GLIBC/GLIBCXX エラーなし・ハングなし）
```

→ ABI 問題も PTX JIT ハングも解消。完了条件を満たした。

## コミット

- `53f8bd2` base image を Ubuntu 24.04 へ変更（glibc 2.38 / GLIBCXX_3.4.32 要件対応）
- `b9435d8` sm_121 torch wheel のランタイム依存を base に追加（libopenblas0 / libnuma1）
- `8f7f12e` LD_LIBRARY_PATH を恒久化（--boltz で CUDA を素通し）

## LD_LIBRARY_PATH の恒久化（案A採用）

検証時は `export LD_LIBRARY_PATH=/usr/local/cuda/lib64` を手動で通していたが、
`--boltz` 実運用でこれが無いと `libcudart.so.13 not found` を踏むため、Dockerfile に
`ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"` を恒久化した。

- CUDA 未マウント（通常起動）時は存在しないパスとなるが、動的リンカが無視するため無害。
- 検証: `--gpus` + `/usr/local/cuda:ro` マウントで**手動 export なし**に
  `torch.cuda.is_available()=True` / `(12,1)` / `matmul OK`。通常起動も従来通り Claude Code が起動。

## 検証手順の再現（ホスト側）

```bash
docker build -t safeclaudediscord .

docker run --rm -it --gpus all \
  -v /usr/local/cuda:/usr/local/cuda:ro \
  --entrypoint bash safeclaudediscord

# コンテナ内
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
uv venv /tmp/t --python 3.12 && source /tmp/t/bin/activate
uv pip install "https://huggingface.co/Qanatpharma/pytorch-sm121-gb10/resolve/main/torch-2.12.0a0+gitb071fd7-cp312-cp312-linux_aarch64.whl"
uv pip install numpy packaging
python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_capability(0))"
python -c "import torch; x=torch.randn(2048,2048,device='cuda'); y=torch.mm(x,x); torch.cuda.synchronize(); print('matmul OK')"
```

## 未対応の follow-up

- push / master への PR 作成はコンテナ内に GitHub 認証が無いため未実施（設計どおり）。ホスト側で実行する。

## 参照

- 実運用 wheel の正確な URL・全手順の一次資料: `BOLTZ_GB10_SETUP_2026-07-03.md`（ホスト上）
