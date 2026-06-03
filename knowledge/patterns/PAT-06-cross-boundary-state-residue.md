# PAT-06: Cross-Boundary State Residue

---
id: PAT-06
domain: RTL / pipelined datapath
status: active
introduced_by: [SRCNN_4_2_1 / INV-002 / BUG-002]
related: [PAT-04 Pipeline Latency]
---

## Symptom

다회 라운드 (out_ch 루프, layer 루프, frame 루프) 를 도는 데이터패스에서 **첫 라운드는 통과, N≥2 라운드부터 깨끗한 +k 픽셀/샘플 시프트** 가 나온다. 시프트 양은 일정하고 데이터 자체는 비트 단위 정합 (단지 인덱스가 어긋남).

전형적 실증:
- ch0/oc0 등 *첫* 라운드: PASS.
- ch1/oc1 등 *다음* 라운드: 모든 출력이 정확히 +k 위치로 이동.
- got[k..N] = exp[0..N-k] (시프트 양이 라운드마다 일관됨).

## Root Cause Family

라운드 사이에 데이터패스의 **stateful 모듈 (FIFO, packer 카운터, ring buffer, prefetch counter)** 가 reset 되지 않아 이전 라운드의 잔류 데이터/포인터가 다음 라운드의 시작에 섞인다. 잔류 양 = 시프트 양.

흔한 발원:
- prefetch 정책이 매 라운드 시작에 1회 발사되지만, 직전 라운드 종료 시 *마지막 prefetch 가 OOB read* 등으로 잔류 N 픽셀을 남김.
- FIFO `srst` 가 전역 `~rstn` 만 받고 라운드 경계 펄스를 안 받음.
- packer / accumulator 의 fifo_cnt, ptr 등이 라운드 사이 캐리.

## Detection (다음 프로젝트 체크리스트)

라운드/루프가 있는 모든 데이터패스에 대해:

1. **모듈별 reset 출처 표** 작성. 각 stateful 모듈이 어느 신호로 어느 경계에서 reset 되는가 (전역 / 라운드 / out_ch / layer / frame).
2. **잔류 회계**: 각 라운드의 FIFO/buffer 의 (write 총량 - read 총량) 이 정확히 0 인가? 사이클 모델에서 가산.
3. **prefetch / 종료 정책의 OOB 검사**: 마지막 prefetch read 가 유효 영역 안인가? 아니면 라운드 종료 시 leftover N 픽셀 (잔류 양) 을 잔류 회계에 반영.
4. **사이클 모델은 최소 2 라운드 시뮬레이션**. 단일 라운드만 보면 본 패턴은 *원리적으로* 안 보인다.
5. **테스트 비대칭 관찰**: ch0 PASS / ch1 FAIL 같은 비대칭은 본 패턴의 1차 시그니처.

## Prevention

- **명시적 라운드-경계 reset 신호**: FSM 이 라운드 종료 시 1clk 펄스 (예: `o_dispatch_rst`) 발사 → 모든 stateful 데이터패스 모듈의 srst 에 OR 결합.
- **module_contract 에 "reset 도메인" 명시**: 각 모듈의 reset 입력이 어느 도메인 (전역 / 라운드 / frame) 에 속하는지를 계약으로.
- **prefetch / drain 대칭 점검**: 라운드 시작 시 N 픽셀 prefetch 한다면, 라운드 종료 시 N 픽셀 drain (또는 srst) 가 대칭으로 있어야 함.

## Seen In

- **SRCNN_4_2_1**: L2 oc0 → oc1 전환 시 FIFO 4픽셀 잔류 → +4 시프트. (BUG-002 / INV-002, fixed in `8b45917`).
  - prefetch (HANDOFF §3.3(a)) + OOB read 가 잔류 발원.
  - `o_dispatch_rst` 를 FIFO `srst` 에 OR 결합으로 해결.

## 환류 (다음 프로젝트 Part 1 인터뷰 항목 후보)

> "다회 라운드를 도는 데이터패스라면, 라운드 경계에서 어느 모듈이 어떻게 reset 되는가? 라운드 시작 prefetch 와 종료 drain 의 대칭성 검사를 verification_plan 에 박는가?"
