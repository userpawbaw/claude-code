# HANDOFF — srcnn/rtl_pu_88 (preset 8_8)

`srcnn/rtl_pu` (4_2) 의 recursive PU 구조를 그대로 확장한 8_8 버전.
구조는 동일, channel 수만 1→8→8→1. 실제 trained weight / Y-channel 이미지 연결은
다음 phase 에서 진행.

## 현재 상태
- iverilog 회귀 **ALL PASS** (3 img × L1 540K + L2 540K + OUT 67.5K pixels, 0 errors).
- 가짜 random weight + random pixel (0..127, Q8.8 positive) 로 검증 완료.

## 파일 목록
| 파일 | 역할 |
|---|---|
| `PU.v` | recursive 단일 PU (8 line_buffer + 8 pe_group + 8 bias) |
| `top.v` | PU 인스턴스 + URAM 16 bank + FIFO 16 개 + 8 packer |
| `FSM_pad.v` | 3-img × L1/L2(8 oc)/L3 시퀀스 + per-(layer,oc) weight base LUT |
| `pe_group.v` | 9 PE + 2-stage adder tree (3 clk pipeline) |
| `PE.v` | dsp_macro_0 wrapper (Vivado IP) |
| `line_buffer_improved.v` | 152-wide 3×3 window line buffer |
| `fifo_add_to_uram.v` | 4 픽셀 → 64bit packer |
| `delay_shift.v` | 파이프라인 지연 매크로 |
| `stubs.v` | iverilog 용 PE/BRAM/URAM/FIFO stub |
| `gen_golden.py` | 3-img + 93-word weight + bias-tail layout golden 생성 |
| `tb_top.v` | 3-img 회귀 testbench |
| `DESIGN.md` | 구조/타이밍/메모리 레이아웃 문서 |

## 다음 phase (실데이터 brink-up) 가이드
4_2 의 HANDOFF.md 와 같은 순서로 진행. 차이점만 강조.

### Phase 0 : baseline 재현
```
cd srcnn/rtl_pu_88/work
python3 ../gen_golden.py
iverilog -g2012 -o tb.vvp ../tb_top.v ../top.v ../PU.v ../FSM_pad.v \
  ../pe_group.v ../line_buffer_improved.v ../fifo_add_to_uram.v \
  ../delay_shift.v ../stubs.v
vvp tb.vvp
# expect: ALL PASS
```

### Phase 1 : `pack_weights.py`
trained Q8.8 weight (.npy 또는 ckpt) → 128-bit × 93 word weight.txt.

**slot 규칙** (DESIGN.md 참조):
- L1 tap n (addr n) : slot s(0..7) = W1[oc=s, ic=0, n]
- L1 bias (addr 9) : slot s = B1[s]
- L2 oc=k tap n (addr 10+k*9+n) : slot s = W2[oc=k, ic=s, n]
- L2 bias (addr 82) : slot s = B2[s]
- L3 tap n (addr 83+n) : slot s = W3[oc=0, ic=s, n]
- L3 bias (addr 92) : slot 0 = B3[0], 나머지 0

hex line = 32 hex chars (slot0 first / MSB).

### Phase 2 : `pack_inputs.py`
Y-channel 이미지 → 3 × 150×150, Q8.8 signed. unsigned 0..255 픽셀은 -128 offset 후
Q8.8 캐스팅 권장 (오버플로 위험 회피, signed -128..127 → -0x8000..0x7F00 → signed 16
범위 내).

### Phase 3 : C++ reference cross-check
`gen_golden.py` 의 `pe_out()` (Q7.8 곱 추출) + 정수 누적 모델을 C++ 로 옮겨
HW-bit-exact 인지 검증. L1/L2/L3 각각 비교.

### Phase 4 : single-img → 3-img 회귀
실 weight + 실 image → tb_top 회귀 → ALL PASS 확인.

### Phase 5 : Vivado 합성
- DSP 72, URAM 16 bank, weight BRAM 128-bit × 128 depth 필요 → BRAM IP 재생성.
- weight BRAM IP : 4_2 (64-bit) 와 별도. 정확히 128-bit width, depth ≥ 93. simple
  dual port, 1-clk read latency.
- URAM IP : 4_2 와 동일 (64-bit × 8192). bank 수만 16 개로 늘어남.
- FIFO IP : 4_2 와 동일 (64→16 standard mode), 인스턴스 16 개.

## 주의 사항 (4_2 와 공통 + 8_8 특이)
1. `PE.v` Q7.8 추출 규칙 = `{w_output[31], w_output[22:8]}`. 17-bit `[23:8]` 아님.
2. 입력 픽셀 Q8.8 부호 처리: signed -128..127 권장. 음수 변환 안 한 0..255 는 0x8000+
   가 signed 음수로 해석되어 L1 ReLU 후 0 됨.
3. L2 누적 8 ic × 9 tap × Q7.8 → 약 24-bit 영역. Stage B (26-bit) 로 처리. 실
   weight 가 클 경우 overflow 검토 필요. (4_2 24-bit 대비 +2 bit 확보.)
4. L3 도 8 ic 누적, 동일 26-bit 처리.
5. URAM 1-clk read latency 가정. Vivado URAM IP 가 2-clk 모드면 FSM `r_uram_en_cnt`
   조정 필요 (4_2 와 공통 항목).
6. FIFO `srst` busy : `dispatch_rst` 직후 한두 clk 안정 시간 필요. 4_2 검증과 동일.
7. `delay_shift(6)` (top.v 의 pe_done 지연) 은 pack commit 보장용 마진. 변경 시
   regression 으로 재확인.
8. line_buffer img_done 후 pipeline 6 clk 까지 last pack_we 가 발화함 — FSM 의
   S_DONE 진입 시점 / wr_addr_rst 시점 변경하면 마지막 4 픽셀 캡처가 깨질 위험.

## 4_2 와의 핵심 차이 요약
| 항목 | 4_2 | 8_8 |
|---|---|---|
| sub_max | L3=2 (4 pe_group 2-stage dispatch) | 모든 layer=1 |
| L1 packer | 4 동시 | 8 동시 |
| L2 pass 수 | 2 | 8 |
| Stage B 폭 | 24 b | 26 b |
| Stage A pair sum 폭 | 22 b | 23 b |
| weight word 폭 | 64 b | 128 b |
| weight depth | 35 | 93 |
| URAM bank (총) | 6 | 16 |
