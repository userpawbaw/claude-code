# PAT-04: Pipeline Latency

---
id: PAT-04
domain: RTL / pipelined datapath
status: active
introduced_by: [Part 5 §4.2 manual seed]
related: [PAT-01 Valid Timing, PAT-06 Cross-Boundary State Residue]
---

## Symptom

메모리 read latency + FIFO 도착 지연을 과소평가해 **소비측이 비는 순간 pop → underflow**, 또는 **데이터 정렬 어긋남** (첫 N 픽셀이 0 으로 미끄러짐).

## Root Cause Family

- read 요청 시점과 데이터 도착 시점의 clk 차이를 설계가 반영 안 함.
- prefetch 깊이가 1clk 부족.
- FIFO `wr_en` 이 rd_en 직결이라 din 이 1clk 늦음 (= 첫 word 가 stale 또는 0).

## Detection (다음 프로젝트 체크리스트)

- 모든 메모리 / FIFO 의 read → data 도착 latency 를 명시했는가?
- 소비측이 비는 최악 시점에 prefetch / buffer 가 충분한가?
- 사이클 모델로 `min_buffer ≥ 1`, `underflow = 0` 을 증명했는가?
- FIFO `wr_en` 이 데이터 안착 신호 (`rd_valid`) 와 같은 clk 인지 직결 (`rd_en`) 인지 명시?

## Prevention

- module_contracts 에 latency 를 계약으로 박는다.
- 폭/위상 조합을 격자 탐색 (prefetch ∈ {0,1,2} × read phase ∈ {0,1,2,3}) 으로 검증.
- 사이클 모델은 **최소 2 라운드** 시뮬 (PAT-06 과 연계).

## Seen In

- **SRCNN_4_2_1 / BUG-014 (HANDOFF.md 기록)**: URAM read +1clk, FIFO 도착 +2clk. prefetch=1 + read@en_cnt==0 + addr=(r_bram>>2)+1 + FIFO wr_en ← uram rd_valid 로 해결. (`20e7845`, `8b45917`)
- **SRCNN_4_2_1 / BUG-002**: 위 prefetch 정책이 라운드 종료 시 OOB read leftover 를 남기는 부작용 → PAT-06 으로 분리 등록.

## 환류

> "메모리/FIFO 의 read → 도착 latency 와 prefetch 깊이가 module_contract 에 박혀 있는가? 사이클 모델이 underflow=0 을 증명했는가, 그리고 그 모델이 라운드 경계까지 시뮬했는가?"
