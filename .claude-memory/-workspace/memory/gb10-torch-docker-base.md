---
name: gb10-torch-docker-base
description: safeclaude の Docker base を GB10/sm_121 torch 対応にする要件（glibc・ランタイム依存・CUDA）
metadata: 
  node_type: memory
  type: project
  originSessionId: ae0586a7-93ca-4d43-94dd-ea171ce63423
---

safeclaude（github.com/satoc1907/safeclaude, Dockerイメージ safeclaudediscord）を DGX Spark(GB10, sm_121) で torch 実行可能にするための base 要件。2026-07-03 に feature/rtk-linux-gpu-boltz 上で対応。

- base は **ubuntu:24.04**（glibc 2.39 / GLIBCXX_3.4.32）。旧 node:22-slim(bookworm, glibc 2.36) では sm_121 native wheel の ABI 要件を満たせずハングした。
- Node.js は base に無いため **node:22-slim を node-donor ステージにして `COPY /usr/local`** で移植（f1e3101 の方式）。
- ubuntu:24.04 は標準で uid1000 の `ubuntu` ユーザーを持つので、`useradd -u 1000 claude` の前に `userdel -r ubuntu` が必要。
- sm_121 native wheel は CUDA/BLAS/numa を同梱しないため、base に **apt: libopenblas0, libnuma1** が必須。CUDA runtime libs (libcudart.so.13 等) は `--boltz` の `/usr/local/cuda:ro` マウントで供給（CUDA 13 系必須）。
- `--boltz` 実運用で `libcudart.so.13` を手動 export なしで解決できるよう、Dockerfile に `ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"` を恒久化済み（案A採用, 2026-07-03）。CUDA 未マウント時は存在しないパスとなるが動的リンカが無視するため無害。検証: マウント＋export なしで torch import が libcudart を解決し matmul OK。
- 検証済み: torch-2.12.0a0+gitb071fd7 で cuda True / capability (12,1) / 2048² matmul がハングなし完走。

関連: [[sm121-torch-wheel]] [[no-cu128-wheel-for-gb10]]
