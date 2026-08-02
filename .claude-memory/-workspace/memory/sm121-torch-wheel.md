---
name: sm121-torch-wheel
description: GB10/sm_121 用 torch native wheel の正確な URL と一次資料の場所
metadata: 
  node_type: memory
  type: reference
  originSessionId: ae0586a7-93ca-4d43-94dd-ea171ce63423
---

DGX Spark(GB10, sm_121) 実運用で使う torch native wheel（Qanatpharma ビルド、cp312/aarch64）:

`https://huggingface.co/Qanatpharma/pytorch-sm121-gb10/resolve/main/torch-2.12.0a0+gitb071fd7-cp312-cp312-linux_aarch64.whl`

- Python 3.12 固定（cp312）。numpy / packaging は別途 `uv pip install` が必要（wheel は依存を持たない）。
- 正確な URL と全セットアップ手順の一次資料はホスト上の **BOLTZ_GB10_SETUP_2026-07-03.md**（リポジトリ内には未マウント）。実運用のインストールは常にこの文書を単一ソースにする。

関連: [[gb10-torch-docker-base]] [[no-cu128-wheel-for-gb10]]
