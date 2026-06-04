# Plan: SRCNN L2 PE-Group Unrolling — Latency Reduction (handoff to next chat)

> 본 문서는 다음 채팅 세션이 `/clear` 후에도 바로 이어갈 수 있도록 설계한 단일 진실 handoff 다. 새 세션은 `git pull` → 본 문서 읽기 → Phase 0 부터 진행.

---

## Context

`SRCNN_4_2_1` (1→4→2→1, 3×3 conv, padding=same) 의 end-to-end RTL 이 KV260 (XCZU5EV) 타깃으로 검증 완료 상태 (`branch claude/intelligent-mccarthy-f10mB`, PR #1, `tb_all_vivado.v` 가 conv-only + ReLU 양쪽 모두 `ALL PASS`).

조사 결과 현재 자원 사용량은 칩 대비 매우 낮다:

- **DSP**: 36 / 1248 = **2.9%**
- **URAM**: 추정 6 논리뱅크 ≈ 12–25% (정확치는 IP 합성 후 확인)
- **BRAM**: <1%
- **LUT/FF**: ~9–11% 추정

목표: **레이어 입출력 채널 구조 (1→4→2→1) 를 변경하지 않고**, PE-group 의 unrolling 만으로 L1→L2→L3 end-to-end **latency 를 줄인다**. 알고리즘 / 채널 수 / 커널 크기 / 레이어 수는 그대로.

사용자가 명시한 핵심 결정:

- L2 의 **out_ch 시분할 (oc0 → oc1 2 pass) 을 깨고 2 out_ch 동시 처리** — pe_group 8개 동시.
- 추가로 **L2 입력 픽셀 병렬 P=2 또는 P=4** 도 검토 (한 clk 에 P 픽셀 처리).
- BRAM/URAM/FIFO read width 확장 시 **zero padding 처리 방식** 두 안 중 선택 필요:
  - **(a)** 현행: 150×150 만 저장, FSM 이 경계에서 `o_is_pad_valid` 로 padding cycle 삽입.
  - **(b)** 입력단부터 152×152 (pre-padded) 저장, FSM 은 sequential 읽기만, 출력 packer 도 padded 형식 그대로 저장.

---

## Recommended approach

**Phase 1 에서 padding 전략 (b) 채택** 권장 — wide-read 와 가장 자연스럽게 합쳐지고, FSM/line_buffer 의 padding 분기가 단순화되어 P 가 커져도 결합 폭발이 없음. 저장 오버헤드는 152²/150² = 2.7% 로 무시.

그 위에 **Phase 2: L2 out_ch 병렬화 (시분할 제거)** → **Phase 3: L2 P=2 픽셀 병렬화** 순차 적용. Phase 4(P=4) 와 Phase 5(L1/L3 동일 패턴) 는 선택. 각 Phase 끝마다 `tb_all_vivado.v` 회귀 통과가 게이트.

---

## Decisions locked by the user (handoff 시 이미 확정)

| 결정 항목 | 값 | 비고 |
|---|---|---|
| 채널 토폴로지 | 1→4→2→1 | 절대 불변. |
| 스케일 축 | PE-group unrolling 만 | 알고리즘/커널/레이어 수 변경 없음. |
| 1차 타깃 | L2 | 시분할 out_ch 가 가장 큰 latency 원인. |
| ReLU 토글 | `USE_RELU` / `URELU` 파라미터 유지 | tb 의 `-Ptb_*.URELU=1` 인터페이스 보존. |
| 검증 기준 | `tb_all_vivado.v` ALL PASS + iverilog 회귀 | conv-only, ReLU 양쪽. |

---

## Open question to close in Phase 1 (ADR)

**Padding 저장 전략 (a) vs (b)**. 권장 (b). 대안 (a) 도 가능하지만 wide-read 시 line_buffer 입력 시점에 "P-wide word 중 일부가 real read, 일부가 pad" 인 케이스를 정확히 합쳐야 해서 복잡도↑.

권장안 (b) 의 영향:
- 입력 BRAM: 150² = 22500 워드 → 152² = 23104 워드 (+2.7%).
- 중간 URAM (`uram_L1`, `uram_L2`): 채널당 22500→23104 픽셀, 64bit 패킹이면 5625→5776 워드 (+2.7%).
- `gen_golden.py`: 입력은 152×152 로 padding 추가해 저장, golden_L1/L2 도 같은 152×152 포맷으로 저장 (test 비교 단순화).
- `FSM_pad_line_buff_improved.v`: 패딩 카운터 (`r_pad_row`, `r_pad_col`) + `w_pad_area` + `o_is_pad_valid` 경로 제거 가능 (단순 sequential read).
- `line_buffer_improved.v`: padding 입력 의식 불필요. 윈도우 valid 조건 `r_row≥2, r_col≥2` 그대로 유효.
- 출력 packer + URAM write: 22500 → 23104 픽셀 (5776 워드) 씀. 가장자리(row 0/151, col 0/151) 위치엔 0 을 packer 가 명시적으로 출력 — 새 FSM 가 경계 카운터 보고 write 시 0 강제.

---

## Phases

### Phase 0 — Durable handoff & branch (새 세션 첫 작업)

```bash
# 새 세션이 시작되면
git pull origin claude/intelligent-mccarthy-f10mB
cat srcnn/HANDOFF_SCALEUP.md       # ← 본 문서

# 베이스라인 회귀 확인 (1분)
cd srcnn/work && python3 gen_golden.py && \
  iverilog -g2012 -o tb_all.vvp ../verification/tb_all_vivado.v \
    ../verification/stubs.v ../rtl/*.v && \
  vvp tb_all.vvp | tail -10
# "ALL PASS" 확인.

# 작업 브랜치 분기
git checkout -b claude/scale-l2-pe-unroll
```

### Phase 1 — Padding ADR + gen_golden 갱신

산출물:
- `docs/adrs/ADR-PAD-001-pre-padded-storage.md` — (b) 안 선택 근거.
- `srcnn/verification/gen_golden.py` 수정 — 입력/골든을 152×152 padded 포맷으로 (옵션 `--padded` 또는 기본 전환).
- 새 골든으로 *현 RTL* 회귀 → FAIL 예상 (RTL 은 아직 150×150 가정). 곧장 Phase 2 RTL 수정으로 이어짐. 또는 ADR 통과 후 즉시 RTL 변경 시작.

### Phase 2 — L2 out_ch 병렬화 (pixel 병렬은 아직 P=1)

핵심 RTL 변경 패턴 (구체 라인 수는 Phase 2 진입 시 산정):

| 파일 | 변경 요지 |
|---|---|
| `srcnn/rtl/top_multilayer.v` | L2 용 pe_group 인스턴스 4 → 8 (= 4 in_ch × 2 out_ch). channel_accumulator 2 인스턴스 (oc0, oc1). pack_main 2 인스턴스. `uram_L2[0]`, `uram_L2[1]` 동시 write. `wr_pulse` 분기에서 L2 가 2개의 동시 펄스 처리. |
| `srcnn/rtl/weight_dispatch.v` | L2 워드 레이아웃을 1 워드 = 4 in_ch × 2 out_ch = 8 슬롯 (128bit) 으로 확장. 또는 64bit 유지하고 sub_max=2 (2 워드/주기) 로. → 폭 확장 권장. `MAX_GROUP=8`. |
| `srcnn/rtl/FSM_pad_line_buff_improved.v` | L2 LUT 값 변경: `lut_out_ch=1` (out_ch 루프 제거), `lut_w_words=9`, `lut_word_stride=1` (interleave 없음). 패딩 카운터 제거 (Phase 1 의 (b) 결정에 따라). |
| `srcnn/rtl/uram_bank.v` | L2 case 에서 `o_L2_we` 가 2'b11 (동시 write) 가 되도록. `o_L2_wr_addr` 는 동일. |
| `srcnn/rtl/fifo_add_to_uram.v` | 변경 없음 (per-out_ch 독립 인스턴스 2개로 통과). |
| Weight BRAM 데이터 | `weight.txt` 재패킹: 128bit/word 또는 동일 64bit 의 새 레이아웃. `gen_golden.py` 의 weight 패킹 함수 수정. |

검증: `tb_all_vivado.v` → ALL PASS. L2 latency = 약 1/2.

### Phase 3 — L2 pixel-parallel P=2

이전 Phase 가 안정된 후. Phase 1 (b) 채택 덕에 padding 분기 없음.

| 파일 | 변경 요지 |
|---|---|
| `srcnn/rtl/line_buffer_improved.v` | 입력 폭 16 → 32 (= 2 pix). `r_line0/1/2` 시프트 단위가 32bit. 1 clk 에 2 windows 출력 (combinational fan-out 2개) 또는 윈도우 폭 자체를 2 픽셀 연속체로. |
| `srcnn/rtl/pe_group.v` | per-window 인스턴스를 P 개 복제 OR pe_group 내부에 P 평행 path. L2 총 = 4 in_ch × 2 out_ch × P=2 = **16 pe_group**, DSP = 16 × 9 = **144** (`11.5% of 1248`). |
| `srcnn/rtl/channel_accumulator.v` | P 개 평행 accumulator. |
| `srcnn/rtl/fifo_add_to_uram.v` | 입력 폭 16 → P×16 = 32. fifo_cnt 도달 조건이 P 펄스마다 1 word. 또는 64bit URAM 포트 그대로 두고 2 cycle 에 1 word. |
| `fifo_generator_0` (Xilinx IP) | 출력 폭 16 → 32. 6 인스턴스 (L1×4 + L2×2) IP 재생성. |
| URAM read width | 64bit → 변경 불필요 (한 clk 에 64bit 출력 → P=2 면 2 사이클 분 데이터 가져옴, FIFO 깊이 조정으로 해결). 단 L2 → L3 시점에 URAM read rate 증가 필요. |
| `srcnn/rtl/FSM_pad_line_buff_improved.v` | `r_bram_addr` 증가 단위 = P. `uram_en_cnt` 사이클이 P 단위로 빨라짐 (= 1 word/clk 가 P pix 소비). |

검증: `tb_all_vivado.v` 의 캡처 로직이 `pack_main_we` 펄스마다 4 pix 캡처 하는데, P=2 적용 후 pack 펄스 빈도는 2배 → 캡처 카운트 동일. ALL PASS 가 그대로 통과해야 함.

L2 latency 추가 1/2 감소. 누적 약 1/4.

### Phase 4 (옵션) — L2 P=4 + L1/L3 동일 패턴

L2 가 충분히 빨라졌으면 latency 병목이 L1 또는 L3 로 이동. 같은 패턴 적용:
- L1: 1 in_ch × 4 out_ch × P = 4P pe_group, DSP = 4P × 9.
- L3: 2 in_ch × 1 out_ch × P = 2P pe_group, DSP = 2P × 9.

P=4 적용 시 L2 = 4 × 2 × 4 × 9 = 288 DSP (23% of 1248). 여전히 칩 여유.

### Phase 5 — Vivado 합성 + 자원/타이밍 클로저

- `tb_all_vivado.v` 시뮬레이션은 Phase 마다 끝났고, 합성 결과의 DSP/URAM/BRAM/LUT/FF 사용량 확인.
- 타이밍 클로저 실패 시 — pe_group adder tree 의 추가 파이프 스테이지, line_buffer SRL extract 점검.

---

## Verification (모든 Phase 공통)

```bash
cd srcnn/work
python3 gen_golden.py            # conv-only
# python3 gen_golden.py relu     # 또는 ReLU

iverilog -g2012 -o tb_all.vvp \
  ../verification/tb_all_vivado.v ../verification/stubs.v ../rtl/*.v
vvp tb_all.vvp | tail -10
# 기대:
#   === L1  : 0 / 90000 errors ...
#   === L2  : 0 / 45000 errors ...
#   === OUT : 0 / 22500 errors ...
#   ALL PASS

# ReLU:
iverilog -g2012 -Ptb_all_vivado.URELU=1 -o tb_all_relu.vvp <위와 동일 소스>
vvp tb_all_relu.vvp | tail -10
```

Vivado 합성/시뮬은 `srcnn/verification/VIVADO_SIM.md` 참조 (XSim 설정, `xelab -generic_top URELU=1` 등).

---

## Files the next session will modify (패턴, 전부 열거는 않음)

- `srcnn/rtl/{top_multilayer,FSM_pad_line_buff_improved,weight_dispatch,uram_bank,line_buffer_improved,pe_group,channel_accumulator,fifo_add_to_uram}.v`
- `srcnn/verification/gen_golden.py` (padding 포맷, weight 패킹)
- `srcnn/verification/tb_all_vivado.v` (캡처 버퍼 크기 — pre-padded 시 NPIX = 152² 로)
- `srcnn/data/weight.txt` (Phase 2 의 새 레이아웃)
- 새 문서: `docs/adrs/ADR-PAD-001-pre-padded-storage.md`
- 새 패턴: `knowledge/patterns/PAT-07-padded-storage-as-simplifier.md` (저장 오버헤드 vs 데이터패스 단순화 트레이드오프)

---

## GitHub

- **Repo**: `userpawbaw/claude-code`
- **Base branch (PASS 상태)**: `claude/intelligent-mccarthy-f10mB`
- **Open PR**: #1 — 이 브랜치에 계속 push 하면 PR 갱신됨
- **새 작업 브랜치 제안**: `claude/scale-l2-pe-unroll`
- 새 브랜치로 분기한 후엔 별도 PR 을 열거나, 기존 PR #1 을 유지하고 work-in-progress 로 계속 push. (사용자 선택)

검증 끝난 phase 마다 한 commit 권장 (Part 4 §5 "task=commit" 규율).

---

## 직전 세션 (= 본 문서 작성 세션) 의 산출물 — 새 세션이 즉시 활용 가능

### 검증 인프라
- `srcnn/verification/tb_all_vivado.v` — Vivado XSim 호환 통합 testbench (L1+L2+L3 end-to-end, URAM `mem` peek 없이 packer 신호 hier-ref 캡처).
- `srcnn/verification/{tb_L1,tb_L2,tb_out}.v` — 레이어별 iverilog용 testbench. `parameter URELU = 0` 노출.
- `srcnn/verification/stubs.v` — PE / BRAM / URAM / FIFO 거동 모델 (iverilog 검증용).
- `srcnn/verification/gen_golden.py` — 입력/weight/golden 생성 (`relu` 인자로 ReLU 모드).
- `srcnn/verification/VIVADO_SIM.md` — Vivado XSim 셋업 가이드.

### 본 세션에서 적용된 fix (= 새 세션의 베이스라인)
- C1 (commit `20e7845`): FSM `S_DONE` 완료 트리거를 `i_uram_we` → `i_adder_done` 으로. prefetch + `en_cnt==0` + `addr+1` 정책 (HANDOFF.md §3.3 spec).
- C2 (commit `8b45917`): top URAM `.rd_valid()` 와이어링 → FIFO `wr_en` (HANDOFF.md §5). FIFO `srst` 를 `o_dispatch_rst` 와 OR 결합 (out_ch 경계 leftover 차단).
- INV-001/002, BUG-001/002, REG-001/002/003: `srcnn/verification/{investigations,bugs,regressions}/`.
- PAT-01/04/06: `knowledge/patterns/`. PAT-06 (Cross-Boundary State Residue) 가 본 세션 직접 추출.

### 알려진 PENDING (HANDOFF.md §9 + 본 세션 도출)
- URAM stub `+1clk rd_valid` 전제 — 실 Xilinx URAM IP 와 대조 미수행.
- `fifo_generator_0` IP 6 인스턴스 동시 합성 가능 여부.
- 합성 결과의 실제 DSP / URAM / LUT / FF 수치 (Phase 5 에서 측정).

---

## Post-handoff first actions (= 본 문서 commit 후 새 세션이 할 일)

새 채팅에서:

1. `git pull origin claude/intelligent-mccarthy-f10mB`
2. `cat srcnn/HANDOFF_SCALEUP.md` (본 문서) + `cat srcnn/HANDOFF.md` (원본 인수인계).
3. Phase 0 의 베이스라인 회귀 (`tb_all_vivado.v` ALL PASS) 확인.
4. Phase 1 시작 — padding ADR 확정 후 RTL 작업.
