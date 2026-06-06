# rtl_pu_88_8x — 8-px unroll + L2 시분할 제거 (576 PE 균등)

## 1. 목적
- 기존 `rtl_pu_88` (1 px/clk, recursive PU 시분할 L1/L2/L3) 대비:
  - **L1/L3** : 8-px/clk unroll 로 throughput ≈ ×8.
  - **L2** : out_ch 8 시분할을 제거하고 공간 병렬화 (8 × 더 큰 PU 1개).
  - **DSP** : 모든 레이어 576 개 균등 가동 (총 1152, L1↔L3 공유).
- KV-260 (1248 DSP) 한도 내. 다음 단계에서 L2 추가 unroll 시 576×2=1152 (L1/L3 그대로) 까지 확장 여지.

## 2. 메모리 포맷 (옵션-2 : 패딩 포함 저장)

| 메모리 | 폭 | 깊이 | 내용 |
|---|---|---|---|
| weight BRAM | 128 b | 93 | rtl_pu_88 와 **동일** (재사용) |
| input BRAM  | 128 b | 3 × 152×152/8 = **8664** | 152×152 zero-padded 이미지, 8 px/word LSB-first |
| URAM_L1     | 128 b × 8 bank | 152×152/8 = **2888** | L1 출력 8 ch 각자 1 bank, 8 px/word |
| URAM_L2     | 128 b × 8 bank | 2888 | L2 출력 8 ch 각자 1 bank |
| output BRAM | 128 b | 8664 | L3 출력 패딩 포함 |

### 2.1 패킹 컨벤션 (LSB-first per word)
```
word[15:0]    = col 8w + 0   (가장 왼쪽 col)
word[31:16]   = col 8w + 1
...
word[127:112] = col 8w + 7   (가장 오른쪽 col)
```
- $readmemh hex 라인: **MSB-first 32 hex chars**. 따라서 가장 왼쪽 4 hex = col 8w+7, 가장 오른쪽 4 hex = col 8w.
- 한 row = 19 word (152/8).
- 한 image = 152 row × 19 word = 2888 word.

### 2.2 패딩 정책
- 모든 feature map(input/L1/L2/L3 output)을 **152×152 zero-border** 로 저장:
  - row 0, row 151, col 0, col 151 = 0.
  - real conv 결과는 rows 1..150, cols 1..150 에만 들어감.
- L2 입력 read 시 별도 `is_pad` mux 불필요 (메모리에서 직접 0 읽힘).

## 3. line_buffer_unroll8.v (신규)

### 3.1 인터페이스
```
parameter IMG_WIDTH = 152, WIN_ROW = 3, WIN_COL = 10, DATA_BIT = 16, UNROLL = 8

input  wire [128-1:0] i_input_data            // 8 px LSB-first
input  wire           i_input_valid
output reg  [8*9*16-1:0] o_line_data          // 8 lane × 3×3 windows
output reg               o_line_valid         // 모든 lane 공통
output reg               o_line_rd_done       // 한 row 종료
output reg               o_img_done           // 한 img 종료
```

### 3.2 동작
- 매 `i_input_valid` clk 마다 128 b push → r_line0 LSB 측에 누적.
- 한 row = **20 clk** (19 real batch + 1 trailing zero shift).
  - trailing shift : FSM 이 `i_input_valid=1` 유지 + `i_input_data=0` 을 1 clk 더 공급.
  - 또는 line_buffer 내부에서 row 끝 감지 → 자동 1 clk zero shift (추후 결정).
- 출력 시점 : `r_row >= 2` 이고 `r_input_shift_in_row >= 1` 부터 valid.
  - row 별로 19 valid 출력 (각 valid 클럭마다 8 lane = 8 cols).

### 3.3 Lane → URAM col mapping
- 출력 clk 시점 = batch s_in 이 막 들어온 직후 (1 clk delay).
- Lane l (l=0..7) center col = 8 × s_out + l, 여기서 s_out = s_in - 1.
- 즉 1번째 output clk (s_in=1, s_out=0) → centers 0..7 (URAM word 0).
- 19번째 output clk (s_in=19=trailing zero, s_out=18) → centers 144..151 (URAM word 18).
  - center=151 lane 7 의 window cols = (150, 151, 152). col 152 는 trailing zero batch 의 LSB → 0 ✓.

### 3.4 Window slice (per lane l, 144-bit)
입력 word LSB-first 패킹과 일관:
```
col(k) at r_lineX bit pos = bits[16*((k - 8*s_in) + offset_batch) +: 16]
  where  k ∈ [8*s_in..8*s_in+7]  → 최신 batch  (offset_batch = 0)
         k ∈ [8*s_in-8..8*s_in-1] → 이전 batch (offset_batch = 8)
         k ∈ [8*s_in-16..8*s_in-9] → 이전이전   (offset_batch = 16)
```
lane l center = 8*s_out + l = 8*(s_in-1) + l = 8*s_in + (l-8). window cols (c-1, c, c+1) :
- col c-1 = 8*s_in + l - 9 → 이전 batch (offset 8) 의 m=l-1 (l=1..7) 또는 이전이전 batch (offset 16) m=l-1+8=l+7 (l=0)
- col c   = 8*s_in + l - 8 → 이전 batch m=l    (l=0..7)
- col c+1 = 8*s_in + l - 7 → 이전 batch m=l+1  (l=0..6) 또는 최신 batch m=0 (l=7)

→ 구현은 8 lane 각각 explicit 3-slot concat (각 lane 의 슬라이스 인덱스는 컴파일 타임 상수).
출력 144-bit/lane 포맷 : `{r_line2 cols(c-1,c,c+1) MSB-first, r_line1 ..., r_line0 ...}` (pe_group 기존 컨벤션 그대로).

## 4. PU 구조

### 4.1 L1_L3_PU (recursive 공유)
- `i_layer_cnt` 가 0 (L1) 또는 2 (L3) 만 사용.
- 64 pe_group : `i_layer_cnt==0` 일 때 8 out_ch × 8 lane (L1, single in_ch broadcast),
  `i_layer_cnt==2` 일 때 8 in_ch × 8 lane (L3, lane 별 8-ch adder tree).
- Stage 파이프라인 : pe_group 출력 36-bit Q16.16 → adder/bias/sat → 16-bit Q8.8.
- 출력 : 128 b (8 px/clk) 1 ch — L1 의 경우 8 ch 동시 → 1024 b (8 ch × 128 b).
  - L1: `o_pixel_data_L1 [8 ch][128 b/ch]` = 1024 b
  - L3: `o_pixel_data_L3 [128 b]` = 128 b

### 4.2 L2_PU (별도 모듈)
- in_ch=8 line_buffer 8 개 (3×3, **1 px/clk** — unroll 안 함).
- out_ch=8 instance 병렬 : 각 instance = 72 PE + 8-ch adder tree + bias + sat → 1 ch px/clk.
- 출력 : 128 b (8 out_ch packed × 16 b) per clk → URAM_L2 8 banks 동시 write.

## 5. FSM_pad.v 변경
- **L1/L3** path : col 보폭 8 (`r_col_word` 0..18). 한 row = 20 clk (19 real + 1 trailing zero).
- **L2** path   : col 보폭 1 (기존 동일). 한 row = 152 clk. 시분할 reload 제거 (weight 1 회 로드).
- `is_pad / is_pad_valid` 신호 제거 (메모리 사전 패딩).
- 입력 BRAM addr : `r_img_cnt * 2888 + (r_row * 19 + r_col_word)` (L1).
- URAM_L1 read addr (L2 입력): `(r_row * 19 + r_col_word)` ; L2 가 1 px/clk 이므로 8 clk 마다 1 word advance — small de-pack 레지스터로 처리.
- URAM_L2 read addr (L3 입력): L3 도 8 px/clk 라 `r_row * 19 + r_col_word` 매 clk advance.

## 6. Throughput / DSP

| Layer | Latency/img (clk) | DSP |
|---|---|---|
| L1 (8 px unroll) | 152 row × 20 clk + pipeline ≈ **3040 + ε** | 576 (8 lane × 8 oc × 9) |
| L2 (1 px, 8 oc parallel) | **152 × 152 + ε ≈ 23104** | 576 (8 oc × 8 ic × 9) |
| L3 (8 px unroll) | ≈ **3040** | 576 (8 lane × 8 ic × 9) |
| **합 (3 img)** | (3040 + 23104 + 3040) × 3 ≈ 87.5 K | 1152 (peak) / 576 (공유) |

기존 rtl_pu_88 : 184 K × 3 ≈ 552 K → **약 6.3× speedup**.
L2 가 병목 (다음 단계에서 2-px unroll 시 23104→11552, 합 56.5 K, 추가 1.55× speedup).

## 7. 변경 / 무변경 파일

### 7.1 무변경 (rtl_pu_88 에서 그대로 복사)
- `PE.v`, `pe_group.v`, `stubs.v`, `delay_shift.v`

### 7.2 신규 / 변경
- `gen_golden.py` — 128 b/word LSB-first, 152×152 패딩 포함 ✅ (이번 commit)
- `line_buffer_unroll8.v` — 3×10 윈도우, 8 lane 출력
- `L1_L3_PU.v` — L1/L3 공유 PU
- `L2_PU.v` — L2 dedicated (out_ch 병렬)
- `FSM_pad.v` — L1/L3 보폭 8 + L2 보폭 1 + is_pad 제거
- `top.v` — 128 b BRAM/URAM, 8 packer×ch, L2 PU 8 instance
- `tb_top.v` — 128 b 비교

## 8. 단계 (commit milestone)
1. **Phase 1 (현재)** : 폴더 + 변경 없는 파일 복사 + `gen_golden.py` + `DESIGN.md`
2. **Phase 2** : `line_buffer_unroll8.v` + 단위 TB
3. **Phase 3** : `L1_L3_PU.v` + 단위 TB (L1 mode)
4. **Phase 4** : `L2_PU.v` + 단위 TB
5. **Phase 5** : `FSM_pad.v` + `top.v` 통합
6. **Phase 6** : `tb_top.v` 회귀 (3 img full pipeline)
