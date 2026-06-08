# SRCNN 8_8 — Recursive PU (preset 8_8)

`srcnn/rtl_pu` (preset 4_2) 의 recursive PU 구조를 유지한 채 channel 만 8_8 로 확장.

**단일 PU** 가 `i_layer_cnt` 로 모드 전환하면서 L1/L2/L3 를 시분할 처리.
PU 내부 line_buffer + pe_group + adder_tree + bias + (layer 별) ReLU + Q7.8 refine 통합.
3-이미지 연속 처리, weight 매-img 재로드.

## Channel 구조 (preset 8_8)
- L1: 1 in_ch → 8 out_ch  (3×3, ReLU)
- L2: 8 in_ch → 8 out_ch  (3×3, ReLU, out_ch 시분할 8 pass)
- L3: 8 in_ch → 1 out_ch  (3×3, NO ReLU, Q7.8 clipping)

## HW 자원 (4_2 대비)
| 항목 | 4_2 | 8_8 |
|---|---:|---:|
| line_buffer | 4 | 8 |
| pe_group    | 4 | 8 |
| DSP         | 36 | 72 |
| URAM_L1 bank | 4 | 8 |
| URAM_L2 bank | 2 | 8 |
| FIFO L1→L2 | 4 | 8 |
| FIFO L2→L3 | 2 | 8 |
| packer | 4 | 8 |
| weight BRAM | 64bit×35 | **128bit×93** |
| L2 pass | 2 | **8** |

## Weight BRAM 레이아웃 (128bit × 93 word)
한 word = 8 × 16-bit slot. slot index s : bits[`16*(7-s) +: 16`].

| addr | layer | 의미 |
|------:|:-----:|------|
| 0..8 | L1 | tap n: `[W1[oc0,0,n], W1[oc1,0,n], ..., W1[oc7,0,n]]` |
| 9    | L1 | bias: `[B1[0..7]]` |
| 10..18 | L2 oc0 | tap n: `[W2[0,ic0,n], ..., W2[0,ic7,n]]` |
| 19..27 | L2 oc1 | tap n: `[W2[1,ic,n]]` |
| ...    | L2 | oc-block: base = `10 + oc*9` |
| 73..81 | L2 oc7 | tap n: `[W2[7,ic,n]]` |
| 82 | L2 | bias (oc0 시작 직전 prefetch): `[B2[0..7]]` |
| 83..91 | L3 | tap n: `[W3[0,ic0,n], ..., W3[0,ic7,n]]` |
| 92 | L3 | bias: `[B3, 0, 0, 0, 0, 0, 0, 0]` |

총 word 수 = 93.

**sub_max=1** (모든 layer). L3 도 8 ic 가 8 slot 에 직접 fit 하므로 dispatcher 가
단순한 tap_cnt one-hot 만으로 충분 (4_2 의 L3 sub_state 2-stage 가 사라짐).

## Input BRAM 레이아웃 (16bit × 67500 word)
3 이미지 연속, 각 150×150 = 22500 word. img i 의 픽셀 = addr `i*22500 + r`.

## URAM (중간 feature map)
- `uram_L1[0..7]` : 64bit × 5625 word (L1 8ch 의 4-pixel pack)
- `uram_L2[0..7]` : 64bit × 5625 word
- img 간 재사용 (L3 끝나면 L1/L2 데이터 불필요)

## FSM 진행 (per image)
```
S_IDLE → S_W_READ (L1: 10 word = 9 weight + 1 bias)
       → S_I_STREAM (L1 stream 152×152, 8 oc 병렬)
       → S_DONE → layer_cnt=1, out_ch_cnt=0
       → S_W_READ (L2 oc0: 9 weight + addr 82 bias)
       → S_I_STREAM (L2 oc0)
       → S_DONE → out_ch_cnt=1
       → S_W_READ (L2 oc1: 9 weight only)  ... 반복 oc 7 까지
       → S_DONE → layer_cnt=2
       → S_W_READ (L3: 9 weight + 1 bias)
       → S_I_STREAM (L3)
       → S_DONE → o_img_done 1clk pulse, img_cnt+
       (img_cnt < 3) loop back to S_W_READ (L1)
       (img_cnt == 3) o_all_done = 1
```

## PU 파이프라인 (3 stage)
- pe_group : 3 clk (PE 1 clk + adder 2 clk).
- Stage A (1 clk) :
  - L1 : `r_sA[g] <= w_partial[g]` (pass)
  - L2/L3 : pair sum `r_sA[0]=p0+p1, r_sA[1]=p2+p3, r_sA[2]=p4+p5, r_sA[3]=p6+p7`
- Stage B (1 clk) :
  - L1 : `r_sB[g] <= r_sA[g] + bias[g]`
  - L2 : `r_sB[0] <= r_sA[0]+r_sA[1]+r_sA[2]+r_sA[3] + bias[i_out_ch_cnt]`
  - L3 : `r_sB[0] <= r_sA[0]+r_sA[1]+r_sA[2]+r_sA[3] + bias[0]`
- Stage C (1 clk) : Q7.8 refine + (ReLU L1/L2 / refine only L3)

비트 폭 :
- pe_partial 21 b → Stage A 23 b → Stage B 26 b → refine `{r_sB[25], r_sB[14:0]}`

## o_img_done 타이밍 체인
line_buffer.o_img_done → pe_group.o_pe_done (+3) → PU.o_img_done (+3, Stage A/B/C)
→ top 의 `delay_shift(6)` → FSM.i_pe_done (총 +12). 4_2 와 동일.

## 검증 회귀
- `gen_golden.py` : 3 × 150×150 입력, W1/W2/W3 + bias 생성, 93-word weight.txt,
  3 img 각각 golden_L1 / golden_L2 / golden_out 생성.
- `tb_top.v` : 3 img 연속 처리, img_done 펄스마다 cap 인덱스 layer-wise 누적.
- iverilog 회귀 ALL PASS (L1 540K + L2 540K + OUT 67.5K, 0 errors).

## line_buffer_wide (8-px unroll) 슬라이스 규약
3-line buffer 를 row 경계 없는 연속 stream 으로 취급. 8-px shift 마다 윈도우는
10-px 폭을 유지하면서 입력의 8 col 단위로 정렬된 출력을 만든다.

- 슬라이스 위치 : `r_lineX[(WIN_COL+SHIFT_STEP-1)*DATA_BIT-1 : (SHIFT_STEP-1)*DATA_BIT]`
  = bits `[271:112]` (10 px, 160 bit).
- 슬라이스 내 정렬 : `win[9]` (MSB) = 가장 왼쪽 col (= row-start emit 의 "col -1"),
  `win[0]` (LSB) = 가장 오른쪽 col (= 최신 word 의 freshest pixel).
- emit 스케줄 (출력 row r ∈ [1..150]):
    * `word_cnt = 1..18` of 입력 row (r+1) → 출력 col 0..143 of out_row r.
    * `word_cnt = 0`     of 입력 row (r+2) → 출력 col 144..151 of out_row r.
  ⇒ 출력 row 150 의 마지막 8 col 을 뽑으려면 L1 stream 끝에 dummy zero word
  1 개 추가 필요 (= FSM 가 `WORDS_PER_ROW*IMG_HEIGHT + 1` 사이클 stream).
- lane-0 mask (내부에서 처리) :
    * row-start emit (`r_col_word == 1`) 시점에서 각 row 슬라이스의 `win[9]` 자리
      는 이전 row 의 잔존 데이터를 들고 있으므로, 강제 0 출력 (= conv lane 0
      의 left-column input 0 = col -1 padding).
- lane-7 mask 불필요 :
    * boundary emit (`r_col_word == 0`) 시점의 `win[0]` 자리는 다음 row 의 col 0
      = 0 (사전 padding 됨). 따라서 conv lane 7 의 right-column input 은 자연
      스럽게 0.

## line_buffer_wide_l3 (L3 4-px unroll) 슬라이스 규약
L3 (8 in_ch → 1 out_ch) 는 출력이 64-bit (= 4 px × 16 b) 만 사용하면 URAM word
폭에 정확히 맞으므로 **4-way unroll** 만 수행. L1/L2 가 576 PE 를 쓰는 동안
L3 는 그 절반 (288 PE = 8 ic × 9 tap × 4 lane) 만 가동.

별도 라인 버퍼 `line_buffer_wide_l3` 사용 (3×6 윈도우, 4-px shift).

- 슬라이스 위치 : `r_lineX[WIN_BITS+DATA_BIT-1 : DATA_BIT]` = bits `[111:16]`
  (6 px, 1-px shifted from LSB). 슬라이스가 `[4K-3 .. 4K+2]` 6 col 커버.
- 슬라이스 내 정렬 (per row, MSB→LSB pixel) :
    * pixel 5 = col 4K-3,  pixel 4 = col 4K-2,
    * pixel 3 = col 4K-1,  pixel 2 = col 4K,
    * pixel 1 = col 4K+1,  pixel 0 = col 4K+2.
- Lane → out col 매핑 (word_cnt K of input row R, 출력 row r = R-1) :
    * `lane k → out col (4K - 2 + k)`,  k ∈ [0..3].
- 3×3 conv 입력 (lane k, slice px 5=MSB 가장 오래된 col, 0=LSB 최신 col) :
    * left = win[5-k], center = win[4-k], right = win[3-k].
- emit 스케줄 (출력 row r ∈ [1..150]) :
    * `word_cnt = 0`     of 입력 row (r+1) → `lane_valid = 4'b1100` (lanes 2,3 = out cols 0, 1).
    * `word_cnt = 1..37` of 입력 row (r+1) → `lane_valid = 4'b1111` (cols 4K-2..4K+1).
  ⇒ 행당 38 emit, 2 + 37×4 = 150 col. Boundary emit / dummy word 불필요.
- "col -1" slot at K=0 (= slice win[3], from previous row's col 151) 은 L2
  출력의 right-pad 0. 자연 0 이므로 conv lane 2 의 left-column input 별도 mask 없음.
- `o_lane_valid` (4 bit) 출력으로 packer 가 `lane_valid` 보고 4-px URAM word
  로 모음 ({32'h0, output[31:0]} ↔ word_cnt=0 패턴).
