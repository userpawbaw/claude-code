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
