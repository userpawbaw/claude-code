# SRCNN RTL 설계 참고 문서
> 작성 기준: rtl_pu_88_unroll 검증 완료 시점 (2026-06-08)

---

## 1. 검증 완료 상태

### rtl_pu_88_unroll — PASS (tb_top2.v, 3 image)
| Layer | Write 횟수 | 오류 |
|-------|-----------|------|
| L1    | 8,550     | 0    |
| L2    | 68,400    | 0    |
| L3    | 17,100 pulses | 0 |

- 이미지 3장 연속 처리, `all_done=1` 정상 확인
- 시뮬레이터: iverilog 12.0

---

## 2. 네트워크 스펙 (SRCNN 3-layer)

```
Input  : 150×150 grayscale, Q8.8 fixed-point (16-bit)
L1     : 1 → 8 ch,  3×3 conv, ReLU,    Q8.8 output
L2     : 8 → 8 ch,  3×3 conv, ReLU,    Q8.8 output
L3     : 8 → 1 ch,  3×3 conv, bidir-sat, Q8.8 output (signed ±32767)

Accumulator : Q16.16 (32-bit signed)
Bias add    : >>> 8 후 bias 더함 (Q8.8 + bias → Q8.8)
Padding     : 152×152 zero-border (row/col 0,151 = 0)
```

---

## 3. 메모리 구조

### 입력 BRAM
```
simple_dual_port_bram : 128-bit × 8,664 word
  = 3 img × 152 row × 19 col_word
  col_word = 8 px × 16-bit = 128-bit
```

### 중간 URAM (L1 출력)
```
8 bank (채널당 1 bank)
각 bank : 128-bit × 2,888 word
  = 152 row × 19 col_word
  write addr 시작: 19 (row 0은 URAM init=0으로 zero-border 자동)
```

### 중간 URAM (L2 출력)
```
8 bank (채널당 1 bank), 동일 구조
```

### Weight BRAM
```
128-bit × 128 word
주소 레이아웃:
  0..8   : L1 weight (9 tap, 8 oc broadcast)
  9      : L1 bias (8 oc packed)
  10..17 : L2 weight oc0 (9 tap)
  19..27 : L2 weight oc1
  ...
  73..81 : L2 weight oc7
  82     : L2 bias (8 oc packed)
  83..91 : L3 weight (9 tap)
  92     : L3 bias
```

---

## 4. 모듈 구조

```
top.v
├── FSM_pad.v          ← 제어 FSM
├── simple_dual_port_bram (stubs.v)  ← weight / input
├── simple_dual_port_uram (stubs.v)  ← URAM_L1 × 8, URAM_L2 × 8
├── PU.v               ← 메인 연산 블록
│   ├── line_buffer_wide.v × 8      ← L1/L2 용 (3×10, 8-px shift)
│   ├── line_buffer_wide_l3.v × 8   ← L3 용 (3×6, 4-px shift)
│   └── pe_group.v × 64             ← 8 oc × 8 lane = 576 PE
│       └── PE.v × 9                ← 단일 MAC (Q16.16)
├── packer_8x.v × 8   ← emit → URAM word (1-clk pass-through)
└── delay_shift.v      ← pe_done 지연
```

### 핵심 모듈 파라미터
| 모듈 | 주요 파라미터 |
|------|-------------|
| FSM_pad | I_NUM=152, O_NUM=150, WORDS_PER_ROW=19, NPIX_IMG=2888, NUM_IMG=3 |
| PU | MAX_CH=8, LANES_WIDE=8, LANES_L3=4 |
| line_buffer_wide | IMG_WIDTH=152, WIN_COL=10, SHIFT_STEP=8 |
| line_buffer_wide_l3 | IMG_WIDTH=152, WIN_COL=6, SHIFT_STEP=4 |
| simple_dual_port_uram | WIDTH=128, DEPTH=2888 |

---

## 5. FSM 상태 흐름

```
S_IDLE → S_W_READ → S_I_STREAM → S_DRAIN → S_DONE → (S_IDLE)

S_W_READ   : weight 9 + bias 1 = 10 cycle 로드
S_I_STREAM :
  L1: BRAM read 2888 cycle + 1 dummy
  L2: URAM_L1 read 2888 cycle + 1 dummy  (oc 0..7 순차 8 pass)
  L3: URAM_L2 read every-other-clk × 5776 cycle
S_DRAIN    : pe_done 대기 (DRAIN_LEN=30)
S_DONE     : counters 업데이트, 다음 pass로

Layer 순서: L1 → L2(oc0) → L2(oc1) → ... → L2(oc7) → L3
이미지 순서: img0 전체 완료 후 img1...
```

---

## 6. 주요 타이밍

```
Pipeline depth (input → emit):
  line_buffer_wide : 2 clk
  pe_group         : 3 clk (adder tree 포함)
  PU Stage A/B/C   : 3 clk
  delay_shift(top) : 6 clk
  총 emit 지연     : ~8 clk

처리 사이클 / 이미지:
  L1              : 2,931 clk
  L2 (8 pass)     : 23,448 clk
  L3              : 5,817 clk
  합계            : ~32,200 clk/image
  3 images        : ~96,600 clk
```

---

## 7. 고친 버그 (재발 방지)

### Bug 1: PU bias 부호 확장 (PU.v)
```verilog
// BEFORE (버그): unsigned concat → >>> 가 logical shift
(r_add_stage1[0][sk] >>> 8) + {{16{r_bias[0][15]}}, r_bias[0]}

// AFTER (수정):
(r_add_stage1[0][sk] >>> 8) + $signed({{16{r_bias[0][15]}}, r_bias[0]})
```
- 원인: `{{...}, ...}` concat 결과가 unsigned → `>>>` 가 산술 shift 아님 → 음수 partial 이 양수 포화값으로
- **L1/L2/L3 bias add 세 곳 모두 수정 필요**

### Bug 2: L3 depacker 스퓨리어스 첫 사이클 (top.v)
```verilog
// BEFORE (버그): layer=2 진입 즉시 in_valid=1 → zero word 주입
r_l3_in_valid <= 1'b1;  // 항상

// AFTER (수정): 첫 rd_valid 이후에만 시작
if (w_uram_L2_rd_valid[0]) begin
    r_l3_word[hi] <= w_uram_L2_dout[hi];
    r_l3_half     <= 0;
    r_l3_in_valid <= 1'b1;
end else if (r_l3_in_valid && r_l3_half == 1'b0) begin
    r_l3_half     <= 1;
    r_l3_in_valid <= 1'b1;
end else begin
    r_l3_in_valid <= 1'b0;  // 첫 rd_valid 전에는 0
end
```
- 원인: URAM 응답 전에 line buffer에 쓰레기 데이터 → 출력 1행 밀림

### Bug 3: line_buffer_wide_l3 img_done 조건 (line_buffer_wide_l3.v)
```verilog
// BEFORE (버그): 5777번째 입력 필요
wire w_img_done = (r_row == IMG_WIDTH);

// AFTER (수정): 5776번째 (마지막 실제 입력)에서 발생
wire w_img_done = (r_row == IMG_WIDTH - 1) && (r_col_word == WORDS_PER_ROW - 1);
```
- Bug 2 수정 후 spurious cycle 제거로 5776번째 입력이 마지막 → 5777번째 없어서 FSM hang
- Bug 2와 Bug 3은 세트로 적용해야 함

### Bug 4: iverilog에서 PE.v + stubs.v 동시 컴파일
```bash
# stubs.v 안에 PE stub이 있어서 PE.v 별도 포함 시 컴파일은 되지만 출력 파일 미생성
# PE.v 제외하고 stubs.v만 포함
iverilog ... top.v FSM_pad.v PU.v pe_group.v ... stubs.v  # PE.v 없음
```

---

## 8. Testbench 구조 (tb_top2.v)

```verilog
// 핵심 설계 원칙:
// 1. $readmemh 로 128-bit golden 배열 로드 (69312+69312+8664 entries)
// 2. on-the-fly 비교 (캡처 배열 없음 → hang 방지)
// 3. repeat(110000) 고정 사이클 (wait(all_done) 금지)
// 4. L3 비교: lane_valid 마스크 적용, 유효 영역(row 1..150, col 1..149)만

// Golden 인덱스 공식:
// L1: gold_L1[img*8*2888 + ch*2888 + r_wr_addr]
// L2: gold_L2[img*8*2888 + oc*2888  + r_wr_addr]
// L3: gold_out[img*2888   + row*19   + col/8],  pixel = (7-col%8)*16+:16

// L3 lane→col 매핑:
// pix_data[63:48]=lane0→col 4K-2,  [47:32]=lane1→col 4K-1
// pix_data[31:16]=lane2→col 4K,    [15:0] =lane3→col 4K+1
// K=0: lanes 0,1 invalid (lane_valid[1:0]=0)
```

---

## 9. 재사용 가능 모듈 (변경 없이 사용 가능)

| 모듈 | 용도 | 비고 |
|------|------|------|
| PE.v / stubs.v | 단일 MAC | Q16.16, 변경 불필요 |
| pe_group.v | 9 PE + adder tree | 변경 불필요 |
| packer_8x.v | emit → URAM word | 1-clk pass-through |
| delay_shift.v | 파이프라인 지연 | WIDTH/DELAY 파라미터화 |
| line_buffer_wide.v | L1/L2 8-px shift | IMG_WIDTH/WIN_COL 조정 가능 |
| line_buffer_wide_l3.v | L3 4-px shift | 동일 |
| stubs.v (BRAM/URAM) | 시뮬레이션 메모리 | DEPTH/WIDTH 파라미터화 |

---

## 10. Recursive / 채널 확장 설계 시 변경 포인트

### 채널 수 변경 시

| 항목 | 현재 (8ch) | N ch 으로 변경 |
|------|-----------|---------------|
| URAM 뱅크 수 | 8 | N |
| PU MAX_CH | 8 | N |
| pe_group 인스턴스 | 8×8=64 | N×LANES |
| Weight BRAM 레이아웃 | L2: 8×9+1=73 addr | L2: N×9+1 addr |
| FSM out_ch_cnt 폭 | 3-bit (0..7) | ceil(log2(N))-bit |
| L2 pass 수 | 8 | N |

### Unrolling 변경 시

| 항목 | 현재 (8-way) | K-way 로 변경 |
|------|------------|--------------|
| WORDS_PER_ROW | 19 (=152/8) | ceil(152/K) |
| NPIX_IMG | 2888 (=152×19) | 152×ceil(152/K) |
| input BRAM DEPTH | 8664 (=3×2888) | 3×NPIX_IMG |
| line_buffer SHIFT_STEP | 8 | K |
| line_buffer WIN_COL | 10 (=K+2) | K+2 |
| STREAM_L3_LEN | 5776 (=2×2888) | 2×NPIX_IMG |

### Recursive 구조 검토 항목
1. **동일 weight 재사용**: W_READ를 한 번만 하고 i_pe_done 후 다시 I_STREAM?
2. **중간 결과 저장**: URAM → 다음 iteration 입력으로 재사용
3. **FSM 수정**: img_cnt 대신 iter_cnt 추가, weight reload 조건 변경
4. **PE 공유**: layer 수 × iteration 수 만큼 시분할 → DSP 절감

---

## 11. 파일 위치

```
srcnn/rtl_pu_88_unroll/
├── top.v                  ← 최상위 (검증 완료)
├── FSM_pad.v              ← 제어 FSM
├── PU.v                   ← 연산 블록
├── PE.v                   ← MAC
├── pe_group.v             ← 9 PE + adder
├── packer_8x.v            ← pass-through packer
├── line_buffer_wide.v     ← L1/L2 line buffer
├── line_buffer_wide_l3.v  ← L3 line buffer
├── line_buffer_improved.v ← (미사용, 이전 버전)
├── delay_shift.v          ← 지연 시프터
├── fifo_add_to_uram.v     ← (미사용)
├── stubs.v                ← 시뮬레이션 IP (BRAM/URAM/PE)
├── tb_top2.v              ← 통합 TB (권장)
├── tb_pu_l1.v             ← L1 단위 TB
├── gen_golden.py          ← 골든 데이터 생성
└── work/                  ← 시뮬레이션 작업 디렉토리
    ├── weight.txt / input.txt
    ├── golden_L1/L2/out.txt
    └── golden.npz
```

---

## 12. 컴파일 / 실행 명령

```bash
cd srcnn/rtl_pu_88_unroll/work

# 컴파일 (PE.v 제외 — stubs.v 에 포함)
iverilog -g2012 -o tb_top2.vvp ../tb_top2.v \
  ../top.v ../FSM_pad.v ../PU.v ../pe_group.v \
  ../packer_8x.v ../line_buffer_wide.v \
  ../line_buffer_wide_l3.v ../delay_shift.v \
  ../fifo_add_to_uram.v ../stubs.v

# 실행 (~110,000 clk, 약 5분)
vvp tb_top2.vvp 2>&1 | grep -v WARNING
```
