# HANDOFF — SRCNN 4_2 PU 디자인, 실 데이터 연결 준비

> 다음 세션이 `/clear` 후 바로 이어갈 수 있도록 정리. 새 세션은 `git pull` → 본 문서 읽기 → "Next session" 의 Phase 0 부터 진행.

## 1. 현재 상태 (commit `7c24a07`, branch `claude/zen-cannon-e9RTP`, PR #8)

- `srcnn/rtl_pu/` PU 기반 4_2 디자인 완성. iverilog 회귀 **ALL PASS**:
  - 3 images × (L1 270,000 + L2 135,000 + OUT 67,500) = 472,500 pixel, 0 errors
  - conv-only / ReLU 분기 없음 (ReLU 는 PU 별 hard-wired)
- weight / input / golden 은 모두 **랜덤 합성 데이터** (`gen_golden.py` 가 생성).
- 다음 세션 목표: **실 SRCNN 학습 weight + 실 Y-채널 이미지** 로 RTL 검증.

## 2. 아키텍처 (DESIGN.md 보강용 요약)

### Channel topology (preset 4_2, 변경 X)
- L1: 1 → 4 (3×3, ReLU)
- L2: 4 → 2 (3×3, ReLU, out_ch 시분할 — pe_group 은 4개 ic 병렬)
- L3: 2 → 1 (3×3, NO ReLU, Q7.8 refine)

### PU 인터페이스 (공통 패턴)
| 입력 | 출력 |
|---|---|
| `i_clk, i_rstn, i_IDLE_rst, i_dispatch_rst` | `o_pixel_valid, o_pixel_data, o_img_done` |
| `i_input_valid + i_pixel/ch_data` | (L1 만 64-bit packed = 4 oc 동시) |
| `i_w_rd_valid + i_w_word(64bit) + i_bias_en` | |
| `i_is_pad_valid` (L2/L3), `i_out_ch_cnt` (L2) | |

각 PU 는 자체적으로:
- weight tap 분배 (combinational `tap_en`, PE 의 `i_en_w` 와 BRAM dout 을 같은 clk 에 정렬)
- bias latch (`r_bias` regs, `i_bias_en` 펄스에 word slot 에서 latch)
- adder tree (L2: 4→2→1, L3: 2→1)
- bias add + (ReLU/clip) + Q7.8 refine

### 데이터 흐름
```
input BRAM (16b × 67500)
       │
       │  layer 0
       ▼
   L1_PU ──► 4 packers ──► URAM_L1[0..3] (64b × 5625)
                                   │
                                   │  layer 1
                                   ▼
                            4 FIFOs ──► L2_PU ──► 1 packer ──► URAM_L2[out_ch_cnt]
                                                                    │
                                                                    │  layer 2
                                                                    ▼
                                                              2 FIFOs ──► L3_PU ──► 1 packer ──► o_pixel_*
```

### Weight BRAM (35 word × 64-bit) — bias 는 각 layer 끝에
| Addr | Layer | 내용 |
|---|---|---|
| 0..8 | L1 | tap n: `[W1[oc0,0,n] W1[oc1,0,n] W1[oc2,0,n] W1[oc3,0,n]]` |
| **9** | **L1 bias** | `[b1_oc0 b1_oc1 b1_oc2 b1_oc3]` |
| 10..27 | L2 | oc-interleave stride=2. oc0=10,12,…,26; oc1=11,13,…,27. word=`[W2[oc,ic0,t] W2[oc,ic1,t] W2[oc,ic2,t] W2[oc,ic3,t]]` |
| **28** | **L2 bias** | `[b2_oc0 b2_oc1 0 0]` (oc0 pass 의 10번째 word) |
| 29..33 | L3 | 5 word, sub_max=2. word_k=`[W3[0,ic0,2k] W3[0,ic0,2k+1] W3[0,ic1,2k] W3[0,ic1,2k+1]]` (k=0..4) |
| **34** | **L3 bias** | `[b3 0 0 0]` |

### Input BRAM (16b × 67500)
- img i 의 픽셀 = addr `i*22500 + r*150 + c`
- 픽셀 값은 **Q8.8 signed** (16-bit). 실 이미지 0..255 → ?? (아래 §4 참조)

### FSM 진행
```
S_IDLE → S_W_READ(L1, 10 word) → S_I_STREAM(150² + pad) → S_DONE
       → S_W_READ(L2 oc0, 10 word) → S_I_STREAM → S_DONE
       → S_W_READ(L2 oc1, 9 word)  → S_I_STREAM → S_DONE
       → S_W_READ(L3, 6 word)      → S_I_STREAM → S_DONE
       → o_img_done pulse, img_cnt++
       → (img_cnt<3) loop / (img_cnt=3) o_all_done
```

### Q-format / PE 규칙 (전체 일관)
- PE 출력: `{w_output[31], w_output[22:8]}` (sign + Q7.8 15-bit, 16-bit total)
- 누적: 21~24-bit signed
- Refine: `{sign, [14:0]}` (low 15-bit 잘라내기, golden 의 `refine16` 과 동치)
- L1/L2 ReLU: sign 비트 1 이면 0
- L3: sign 보존 + low 15-bit (clipping 은 비활성, gen_golden 도 동일)

## 3. 검증 인프라

```
srcnn/rtl_pu/
├── DESIGN.md              ── 아키텍처 상세
├── HANDOFF.md             ── 본 문서
├── FSM_pad.v              ── 3-img FSM
├── L1_PU.v / L2_PU.v / L3_PU.v
├── pe_group.v             ── 3×3 PE + adder tree (partial sum 만)
├── line_buffer_improved.v ── 152-wide line buffer (padding 포함)
├── PE.v                   ── DSP macro 기반 PE (Vivado)
├── delay_shift.v
├── fifo_add_to_uram.v     ── 4-pixel 16b → 64b packer
├── stubs.v                ── iverilog 검증용 (PE / BRAM / URAM / FIFO 흉내)
├── top.v                  ── 통합 top
├── tb_top.v               ── 3-img 회귀 TB (pack_*_we 캡처)
└── gen_golden.py          ── 랜덤 weight/input/golden 생성
```

**iverilog 회귀 (현재 ALL PASS)**
```bash
cd srcnn/rtl_pu/work
python3 ../gen_golden.py
iverilog -g2012 -o tb_top.vvp ../tb_top.v ../stubs.v ../FSM_pad.v \
    ../L1_PU.v ../L2_PU.v ../L3_PU.v ../pe_group.v \
    ../line_buffer_improved.v ../delay_shift.v ../fifo_add_to_uram.v ../top.v
vvp tb_top.vvp | tail
# 기대: ALL PASS, ~1분 시뮬
```

## 4. 다음 세션 — 실 데이터 연결

### Phase 0 (회귀 베이스라인 재확인)
```bash
git pull origin claude/zen-cannon-e9RTP
cd srcnn/rtl_pu/work && python3 ../gen_golden.py
iverilog … ; vvp tb_top.vvp | tail   # ALL PASS 확인
```

### Phase 1 — 실 weight 변환 (가장 중요)

**입력**: SRCNN reference (`01_Reference_SW/`) 가 학습한 weight/bias 파일들
- preset **4_2** 의 weight 형식 (Readme):
  - W1: 4×1×3×3 (float), b1: 4
  - W2: 2×4×3×3, b2: 2
  - W3: 1×2×3×3, b3: 1

**필요 작업** — `srcnn/rtl_pu/pack_weights.py` (신규) 작성:
1. 사용자 weight/bias 파일 (float) 을 읽어들임.
2. Q8.8 정수로 변환: `int(round(x * 256))`, clipping `[-32768, 32767]`.
3. **수치 범위 사전 검증**: `gen_golden.py` 의 `gen_w()` 는 `[-32..32]` Q8.8 (= `[-0.125, 0.125]`) 으로 생성했음. 실 학습 weight 는 이보다 클 수 있음.
   - 만약 |L2 누적 → 15-bit refine 범위 초과| (overflow 가 잦음) → bit-width 확장 필요 or weight quantization 재조정. **TBD: 실 weight 분포 측정 먼저.**
4. 35-word `weight.txt` 으로 packing (§2 의 layout 그대로).
5. bias 도 같은 word 의 슬롯에 packing (위 표).

### Phase 2 — 실 이미지 변환

**입력**: `02_Provided_Data/input_Y_channel_only_hex/test_N_hex.txt` (4-digit hex, 22500 줄, Q8.8 = 픽셀값 × 256)

**필요 작업** — `srcnn/rtl_pu/pack_inputs.py` (신규) 또는 `gen_golden.py` 확장:
1. 3 개의 `test_*_hex.txt` 를 읽어 한 `input.txt` (67500 줄) 으로 concat.
2. **부호 확인**: 실 픽셀 0..255 는 Q8.8 = 0x0000..0xFF00. 그러나 PE 의 `i_input` 은 `signed [15:0]` 이라 0x8000 이상은 음수로 해석됨.
   - **현재 합성 데이터는 0..127 (0x0000..0x7F00) 으로 제한해서 통과**.
   - **실 이미지 픽셀 0..255 사용 시 → signed 해석 충돌**. 두 가지 방안:
     - (a) 입력단에서 -128 offset (centered): 픽셀 v → `(v - 128) * 256` = `[-32768, 32512]`, signed 16 안전. golden 도 동일 offset 적용.
     - (b) PE 입력을 unsigned 로 해석 변경 (RTL `i_input` 을 unsigned 로). 누산은 signed 유지. 곱셈 시 mixed-sign 처리 필요.
   - **(a) 권장**. SRCNN reference 의 입력 normalize 와 일치하는지 확인 필요.

### Phase 3 — Golden 재계산

옵션 두 가지:
- **A. C++ reference 그대로 사용**: `01_Reference_SW/fixed_point_SRCNN_inference --preset 4_2 --input N` → `save_4_2/layer1_output.txt`, `layer2_output.txt`, `output.txt` 생성. tb_top.v 가 이 파일들을 읽도록 path 수정.
  - 단, reference 의 산수가 본 RTL 과 동일한지 (Q16.16 누산 후 shift, bias add, ReLU 순서) 1-pixel 단위 비교 필요.
- **B. `gen_golden.py` 의 conv 모델을 그대로 사용**: 실 weight/input 만 끼우고, 본 디자인의 PE 규칙으로 시뮬레이션. RTL ↔ 모델 일치 보장 (현재 보장됨).
  - 다만 모델이 reference 와 다를 수 있음 (per-PE Q7.8 shift vs full Q16.16 누산 후 shift).

**권장**: **둘 다 생성** → A vs B mismatch 분석. RTL 은 일단 B 기준으로 통과시키고, A 와의 차이 (PSNR 등) 를 별도 측정.

### Phase 4 — Single-image regression

- `NUM_IMG=3` 을 `NUM_IMG=1` 로 임시 설정해서 첫 image 만 빠르게 검증.
- mismatch 발생 시:
  - 첫 mismatch 픽셀의 좌표 → 골든의 raw_sum, bias, refined 값 확인
  - 디자인의 wave dump (icarus 의 $dumpfile/$dumpvars) 추가 → 해당 픽셀 시점의 pe_partial / ca_sum / r_bias 신호 인스펙트
  - 가능성 높은 후보: overflow (15-bit refine 한계), bias 부호 해석, padding 영역 처리

### Phase 5 — Vivado 합성 + Real IP 검증
- `PE.v` 의 `o_output` 라인 한 줄 수정 (사용자 측 액션):
  - `{w_output[31], w_output[23:8]}` → **`{w_output[31], w_output[22:8]}`**
- BRAM / URAM / FIFO IP 의 read latency 확인 — stub 은 1-clk 가정.
  - URAM 의 output register 가 켜져 있으면 2-clk → 동작 깨짐. 끄거나, FSM 의 prefetch / FIFO wr_en 타이밍 조정 필요.
- 합성 자원 보고 (DSP / URAM / BRAM / LUT / FF) — `DESIGN.md` 의 빈 Phase 5 섹션에 채움.

## 5. 알려진 제약 / 주의사항

| 항목 | 상태 |
|---|---|
| Vivado 실 PE.v 의 `[23:8]` 비트 추출 | 사용자가 수정 필요 (`[22:8]`) |
| Q8.8 입력 부호 충돌 (픽셀 128+) | Phase 2 의 offset 해결 |
| L2 누적 overflow → 15-bit refine | weight 분포 따라 발생 가능, gen_golden 에 OVERFLOW 경고 있음 |
| Real Xilinx URAM 2-clk latency | Phase 5 에서 IP 설정 검증 |
| FIFO IP `srst` busy cycle | dispatch_rst 펄스 후 동작 확인 (현재 stub 은 즉시) |
| `top.v` 의 pe_done DELAY=6 | 합성 후 타이밍 마진 측정 — packer commit 보장 |
| line_buffer 의 `r_row` 1clk 후 img_done | PU 별 delay_shift 로 정렬됨 |

## 6. 직전 세션에서 해결한 버그 (참고)

1. **PE 비트 추출 mismatch** — golden(`[14:0]`) vs stub(`[14:0]`) vs PE.v(`[23:8]`) 셋이 달랐음. `[22:8]` 으로 통일.
2. **tap_en off-by-one** — registered tap_en 이 BRAM dout 다음 word 에 정렬됨. combinational gate 로 수정.
3. **i_pe_done 조기 도착** — FSM 의 layer 전환이 packer 의 마지막 commit 보다 빨라서 tail 미캡처. top 에 `delay_shift(6)` 추가.
4. **Inactive PU 의 pad-valid 수신** — L2/L3 의 `i_is_pad_valid` 가 모든 layer 의 pad 펄스를 받아서 packer fifo_cnt drift. layer_cnt 로 gating.
5. **FSM S_DONE 조기 IDLE** — `i_pe_done` 도착 전에 IDLE 로 빠짐. wait 조건 추가.

## 7. Post-handoff first actions

새 채팅에서:
1. `git pull origin claude/zen-cannon-e9RTP`
2. `cat srcnn/rtl_pu/HANDOFF.md` (본 문서) + `cat srcnn/rtl_pu/DESIGN.md`
3. Phase 0 의 베이스라인 회귀 확인
4. **실 weight/input 파일 위치 + 형식** 을 사용자에게 확인 (또는 `01_Reference_SW/`, `02_Provided_Data/` 경로 명시)
5. **입력 픽셀 부호 정책** (offset -128 vs unsigned 해석) 결정
6. Phase 1 부터 진행

---

**Repo**: `userpawbaw/claude-code`, **branch**: `claude/zen-cannon-e9RTP`, **PR**: #8.
새 세션의 작업은 같은 branch 에 commit/push → PR 갱신.
