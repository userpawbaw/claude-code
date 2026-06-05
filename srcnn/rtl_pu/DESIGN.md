# SRCNN 4_2 — Recursive PU redesign

**단일 PU** 가 `i_layer_cnt` 로 모드 전환하면서 L1/L2/L3 를 시분할 처리. PU 내부에
line_buffer + pe_group + adder_tree + bias + (layer 별)ReLU + Q7.8 refine 통합.
3-이미지 연속 처리, weight 매-img 재로드.

자세한 인터페이스/파이프라인은 `HANDOFF.md` 참조.

## Channel 구조 (preset 4_2, 변경 없음)
- L1: 1 in_ch → 4 out_ch  (3×3, ReLU)
- L2: 4 in_ch → 2 out_ch  (3×3, ReLU, out_ch 시분할 1pass/1pass)
- L3: 2 in_ch → 1 out_ch  (3×3, NO ReLU, Q7.8 clipping)

## Weight BRAM 레이아웃 (64bit × 35 word)
각 word = 4 × 16-bit slot, MSB-first (`{slot0,slot1,slot2,slot3}`)

| addr  | layer | 의미 |
|------:|:-----:|------|
|  0..8 |  L1   | tap n: `[W1[oc0,0,n], W1[oc1,0,n], W1[oc2,0,n], W1[oc3,0,n]]` |
|     9 |  L1   | bias:  `[b_L1[0], b_L1[1], b_L1[2], b_L1[3]]` |
| 10..27|  L2   | oc-interleave (stride=2). oc0=10,12,...,26; oc1=11,13,...,27. word=`[W2[oc,ic0,t], W2[oc,ic1,t], W2[oc,ic2,t], W2[oc,ic3,t]]` |
|    28 |  L2   | bias:  `[b_L2[0], b_L2[1], 0, 0]` |
| 29..33|  L3   | 5 word, sub_max=2. word_k=`[W3[0,ic0,2k], W3[0,ic0,2k+1], W3[0,ic1,2k], W3[0,ic1,2k+1]]` (k=0..4). 마지막 k=4 의 2k+1=9 은 0-padding |
|    34 |  L3   | bias:  `[b_L3, 0, 0, 0]` |

총 word 수 = 35.

## Input BRAM 레이아웃 (16bit × 67500 word)
3 이미지 연속, 각 150×150 = 22500 word. img i 의 픽셀 = addr `i*22500 + r`.

## URAM (중간 feature map)
- `uram_L1[0..3]` : 64bit × 5625 word (L1 출력 4ch 의 4-pixel pack)
- `uram_L2[0..1]` : 64bit × 5625 word
- img 간에는 재사용 (L3 끝나면 L1/L2 데이터 불필요)

## FSM 진행 (per image)
```
S_IDLE
 → S_W_READ (L1: 10 word: 9 weight + 1 bias)
 → S_I_STREAM (L1 stream 152×152, 4 oc 병렬)
 → S_DONE   (out_ch_cnt 1 회만, layer_cnt 1+)
 → S_W_READ (L2 oc0: 9 weight, oc=0 부터)
 → S_I_STREAM (L2 oc0)
 → S_DONE → out_ch_cnt=1 → S_W_READ (L2 oc1: 9 weight)
 → S_I_STREAM (L2 oc1) → S_DONE → out_ch_cnt=0, layer_cnt+
 (L2 bias 는 oc0 word read 직전, addr 28 에서 미리 1회 load — bias_en_oc0/oc1)
 → S_W_READ (L3: 6 word: 5 weight + 1 bias)
 → S_I_STREAM (L3)
 → S_DONE → o_img_done 1clk pulse, img_cnt+
 → (img_cnt < 3) loop back to S_W_READ (L1)
 → (img_cnt == 3) o_all_done = 1
```

bias 로드는 `o_bias_en` 1clk 펄스로 PU 안에서 latch.
L2 의 두 oc bias 는 addr 28 에서 한 번에 두 slot 으로 들어옴 — 두 번째 pass 때
재-로드하거나, 첫 pass 때 둘 다 latch 해 두는 게 합리적. 본 설계는 후자 채택
(L2_PU 내부에 `r_bias[0]`, `r_bias[1]` 둘 다 보관, `i_out_ch_cnt` 로 선택).

## PU 인터페이스 (공통)
- input  pixel/window data + valid
- input  weight word (64bit), w_rd_en, bias_en
- input  layer_cnt (PU 가 active layer 인지 판단) — 단, 한 PU = 한 layer 라 사실상
         enable 신호로 사용 (`i_layer_active`)
- output pixel valid + pixel data (16bit or 64bit packed for L1)
- output img_done (line_buffer img_done 의 pipeline-aligned 버전)

## ReLU
- L1_PU, L2_PU 안에 hard-coded ReLU (음수 → 0).
- L3_PU 는 ReLU 없음, 대신 Q7.8 clipping (overflow → 0x7FFF / 0x8000).

`USE_RELU` 파라미터 제거. layer_cnt 의 ReLU 여부는 PU 구분으로 처리.

## Bias 산수
- pe_group → 9-tap 합 (L1: 단일 ic의 9-tap), adder_tree → ch-누적 (L2/L3),
  그 결과(21~24bit) 에 bias (16bit, Q8.8) 를 더한다.
- 더한 결과를 Q7.8 refine: `{sign, [22:8]}` (PE.v 와 동일 규칙).

## 검증 회귀
- `gen_golden.py`:
  - X = 3 × 150×150, Q8.8 (pixel 0..127)
  - W1/W2/W3 + bias 생성, 새 35-word weight.txt 출력
  - 3 img 각각 golden_L1 / golden_L2 / golden_out 생성
- `tb_top.v`: 3 img 연속 처리, img_done 펄스마다 캡처 인덱스 layer-wise 누적.

## 자원/타이밍 가시화 (Phase 5 reserve)
PU 단위로 DSP/URAM/LUT 사용량 측정. Phase 5 에서 합성 후 채움.
