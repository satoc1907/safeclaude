---
name: no-cu128-wheel-for-gb10
description: GB10/sm_121 では通常 PyPI の cu128 torch wheel を使わない（PTX JIT ハングの元凶）
metadata: 
  node_type: memory
  type: feedback
  originSessionId: ae0586a7-93ca-4d43-94dd-ea171ce63423
---

GB10(sm_121) の torch 検証・実運用で、通常 PyPI の `torch --index-url .../whl/cu128` を使ってはいけない。

**Why:** cu128 PyPI wheel は native SASS が sm_120 までしか無く、sm_121(GB10) では PTX JIT フォールバックになり実行がハングする。これが一連の問題の元凶。import が通っても検証にならず、本番で結局ハングする。

**How to apply:** 検証も本番も、必ず sm_121 native wheel（[[sm121-torch-wheel]]）で行う。「import が通る」だけでなく `get_device_capability(0)==(12,1)` と実 matmul がハングなし完走まで確認する。

関連: [[gb10-torch-docker-base]]
