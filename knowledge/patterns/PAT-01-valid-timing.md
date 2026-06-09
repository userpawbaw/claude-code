# PAT-01: Valid Timing

---
id: PAT-01
domain: RTL / pipelined datapath
status: active
introduced_by: [Part 5 §4.2 manual seed]
related: [PAT-04 Pipeline Latency, PAT-06 Cross-Boundary State Residue]
---

## Symptom

valid / done / completion 신호의 파이프라인 지연 단수가 데이터 지연 단수와 어긋나서, **데이터는 옳은데 그 데이터에 따라붙는 trigger 가 한 박자 빠르거나 늦어** 다운스트림이 잘못된 시점에 캡처/전환/판정한다.

전형적 실증:
- 마지막 출력 일부가 0 또는 누락 (`done` 이 너무 빨라 후속 write 가 라우팅 마스킹).
- 모듈 분리/리팩터 후 비트는 동일하나 1clk 어긋남.

## Root Cause Family

- `o_valid` / `o_done` 의 지연 단수가 `o_data` 와 다름.
- 종료 판정 (state machine 의 `done`) 이 *첫* 펄스를 잡는 구조라 마지막까지 기다리지 못함.
- 분리된 모듈 인터페이스에서 valid 가 데이터보다 늦거나 빠르게 도착.

## Detection (다음 프로젝트 체크리스트)

1. 모든 `o_valid` / `o_data` 페어의 **지연 단수를 module_contract 에 명시** (예: pe_group: `o_valid = i_line_valid + 3clk`).
2. 종료 trigger 가 *첫* 펄스인지 *마지막* 펄스인지 명시. 마지막이라면 어떤 신호가 그것을 보장하는가 (예: `pe_done = img_done + 3clk`, 그 뒤로 +2clk 추가 지연이 packer 마지막 출력 보다 늦음을 사이클 모델로 확인).
3. 모듈 분리 시 valid 타이밍 동치 회귀를 *비트 단위* 로 먼저 확인.

## Prevention

- module_contract 에 latency 박기 (계약).
- 종료 trigger 는 "최종 데이터 안착 후" 조건으로 (counter 도달 / drain done / pipeline flush 완료).
- 분리 직후 회귀 테스트를 통과 게이트로.

## Seen In

- **SRCNN_4_2_1 / BUG-001**: FSM S_DONE 이 `i_uram_we` 첫 펄스에서 exit → 마지막 2 pack write 가 layer_cnt 전환 후 라우팅 마스킹으로 손실. `i_adder_done` (= pe_done + 2clk) 으로 교체로 해결. (`20e7845`)
- **SRCNN_4_2_1 / pe_group 분리**: `pe_group` 모듈화 시 `o_valid` 3단, `o_pe_done = img_done + 3clk` 으로 타이밍 계약 정렬 (HANDOFF §3.2).

## 환류

> "데이터 신호의 latency 와 valid/done 신호의 latency 가 module_contract 에 같이 박혀 있는가? 종료 판정이 *첫* 펄스인지 *마지막* 펄스인지 명시했는가?"
