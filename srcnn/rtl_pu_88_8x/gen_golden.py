#!/usr/bin/env python3
# gen_golden.py — rtl_pu_88_8x (L1/L3 8-px unroll, L2 시분할 제거, 576 PE 균등).
#
# 메모리 포맷 변경 (rtl_pu_88 대비):
#   - 이미지/feature map 을 **152×152 zero-padded** 로 저장 (옵션-2).
#   - 입력/중간/출력 BRAM/URAM 폭 = **128-bit/word = 8 × 16-bit Q8.8** (LSB-first 패킹).
#       word[15:0]    = col 8w + 0
#       word[31:16]   = col 8w + 1
#       ...
#       word[127:112] = col 8w + 7
#   - input.txt   : 3 img × 152 rows × 19 word/row = 8664 word × 128-bit
#   - golden_L1   : 3 img × 8 ch  × 152 rows × 19 word = 69312 word × 128-bit
#                    (ch 0..7 채널-순차, 같은 row 안에서 col-순차 19 word)
#   - golden_L2   : 같은 포맷 (3 × 8 × 152 × 19 = 69312 word)
#   - golden_out  : 3 img × 152 rows × 19 word = 8664 word × 128-bit (1 ch)
#   - weight.txt  : 변경 없음 (128b × 93 word, 기존 포맷 그대로)
#
# 패딩 정책:
#   - 입력 이미지 X[m, 0..149, 0..149] 를 padded X_pad[m, 0..151, 0..151] 로 zero-border.
#   - L1/L2/L3 출력도 같은 152×152 zero-border 로 저장 (real conv는 cols 1..150,
#     rows 1..150 영역에만 들어가고 나머지는 0).
#
# 산술:
#   - PE/adder Q16.16 (rtl_pu_88 와 동일 README spec).
#   - L1/L2 : (acc >>> 8) + bias_q88  → ReLU + upper-sat (0..0x7FFF)
#   - L3    : (acc >>> 8) + bias_q88  → bidirectional sat (-0x8000..0x7FFF)

import numpy as np

IMG       = 150
PAD       = 1
PAD_IMG   = IMG + 2*PAD    # 152
WORDS_ROW = PAD_IMG // 8   # 19 word / row (128-bit each)
NPIX_PAD  = PAD_IMG * PAD_IMG
NWORD_IMG = PAD_IMG * WORDS_ROW
NUM_IMG   = 3
np.random.seed(20250605)
ONE = 256
MAX_CH = 8

assert PAD_IMG % 8 == 0, "PAD_IMG must be multiple of 8 for 8-px packing"

def u16(v): return int(v) & 0xFFFF

def gen_w(shape):
    return np.random.randint(-ONE//8, ONE//8 + 1, size=shape, dtype=np.int64)
def gen_b(shape):
    return np.random.randint(-2*ONE, 2*ONE + 1, size=shape, dtype=np.int64)

W1 = gen_w((8,1,9))
W2 = gen_w((8,8,9))
W3 = gen_w((1,8,9))
B1 = gen_b((8,))
B2 = gen_b((8,))
B3 = gen_b((1,))

# ---- weight BRAM (변경 없음, rtl_pu_88 와 동일 lay-out) ----
N_WORDS = 93
words = [[0]*MAX_CH for _ in range(N_WORDS)]
for n in range(9):
    for s in range(8):
        words[n][s] = u16(W1[s, 0, n])
for s in range(8):
    words[9][s] = u16(B1[s])
for k in range(8):
    base = 10 + k*9
    for n in range(9):
        for s in range(8):
            words[base + n][s] = u16(W2[k, s, n])
for s in range(8):
    words[82][s] = u16(B2[s])
for n in range(9):
    for s in range(8):
        words[83 + n][s] = u16(W3[0, s, n])
words[92][0] = u16(B3[0])

# weight word : slot 0 MSB-first 유지 (PE.v 슬롯 인덱싱 동일)
with open("weight.txt","w") as f:
    for w in words:
        line = "".join(f"{w[s]:04X}" for s in range(8))
        f.write(line + "\n")

print(f"W1 [{W1.min()},{W1.max()}]  W2 [{W2.min()},{W2.max()}]  W3 [{W3.min()},{W3.max()}]")
print(f"B1 [{B1.min()},{B1.max()}]  B2 [{B2.min()},{B2.max()}]  B3 [{B3.min()},{B3.max()}]")

# ---- 입력 (3 img × 150×150 → 152×152 zero-padded Q8.8) ----
X = np.random.randint(0, 128, size=(NUM_IMG, IMG, IMG), dtype=np.int64) * ONE

def pad_to(img):  # (H, W) → (H+2, W+2)
    H, W = img.shape
    out = np.zeros((H+2*PAD, W+2*PAD), dtype=np.int64)
    out[PAD:PAD+H, PAD:PAD+W] = img
    return out

# ---- conv (README spec, Q16.16) ----
def conv3x3_same_q1616(inp_q88_padded, kernel_q88):
    # inp_q88_padded : already 152×152, kernel : (9,)
    PH, PW = inp_q88_padded.shape
    H, W = PH - 2*PAD, PW - 2*PAD
    k = kernel_q88.reshape(9).astype(np.int64)
    out = np.zeros((H, W), dtype=np.int64)
    for r in range(H):
        for c in range(W):
            win = inp_q88_padded[r:r+3, c:c+3].reshape(9)
            acc = 0
            for t in range(9):
                acc += int(win[t]) * int(k[t])
            out[r, c] = acc
    return out  # 150×150, Q16.16

def to_q88_relu_sat(acc_q1616, bias_q88):
    v = (acc_q1616 >> 8) + int(bias_q88)
    v = np.where(v < 0, 0, v)
    v = np.where(v > 0x7FFF, 0x7FFF, v)
    return v.astype(np.int64)

def to_q88_bidir_sat(acc_q1616, bias_q88):
    v = (acc_q1616 >> 8) + int(bias_q88)
    v = np.where(v >  0x7FFF,  0x7FFF, v)
    v = np.where(v < -0x8000, -0x8000, v)
    return v.astype(np.int64)

# featuremap 들을 152×152 padded 형태로 저장
L1_pad  = np.zeros((NUM_IMG, 8, PAD_IMG, PAD_IMG), dtype=np.int64)
L2_pad  = np.zeros((NUM_IMG, 8, PAD_IMG, PAD_IMG), dtype=np.int64)
OUT_pad = np.zeros((NUM_IMG, PAD_IMG, PAD_IMG), dtype=np.int64)

for m in range(NUM_IMG):
    Xp = pad_to(X[m])
    # L1
    L1_real = np.zeros((8, IMG, IMG), dtype=np.int64)
    for oc in range(8):
        acc = conv3x3_same_q1616(Xp, W1[oc, 0])
        L1_real[oc] = to_q88_relu_sat(acc, B1[oc])
    L1_pad[m, :, PAD:PAD+IMG, PAD:PAD+IMG] = L1_real

    # L2 (Σ ic on padded L1)
    L2_real = np.zeros((8, IMG, IMG), dtype=np.int64)
    L1_pad_in = np.zeros((8, PAD_IMG, PAD_IMG), dtype=np.int64)
    L1_pad_in[:, PAD:PAD+IMG, PAD:PAD+IMG] = L1_real
    for oc in range(8):
        acc = np.zeros((IMG, IMG), dtype=np.int64)
        for ic in range(8):
            acc += conv3x3_same_q1616(L1_pad_in[ic], W2[oc, ic])
        L2_real[oc] = to_q88_relu_sat(acc, B2[oc])
    L2_pad[m, :, PAD:PAD+IMG, PAD:PAD+IMG] = L2_real

    # L3 (Σ ic on padded L2)
    L2_pad_in = np.zeros((8, PAD_IMG, PAD_IMG), dtype=np.int64)
    L2_pad_in[:, PAD:PAD+IMG, PAD:PAD+IMG] = L2_real
    acc = np.zeros((IMG, IMG), dtype=np.int64)
    for ic in range(8):
        acc += conv3x3_same_q1616(L2_pad_in[ic], W3[0, ic])
    OUT_real = to_q88_bidir_sat(acc, B3[0])
    OUT_pad[m, PAD:PAD+IMG, PAD:PAD+IMG] = OUT_real

    print(f"img{m}: L1 [{L1_real.min()},{L1_real.max()}]  "
          f"L2 [{L2_real.min()},{L2_real.max()}]  "
          f"OUT [{OUT_real.min()},{OUT_real.max()}]")

# ---- 128-bit packing (LSB-first 8 px/word) ----
def pack_row_128b(row_152px):
    """152 elements → 19 lines of 32-hex-char (128-bit)."""
    lines = []
    for w in range(WORDS_ROW):
        slots = row_152px[8*w : 8*w + 8]   # 8 px, col-ascending
        # LSB = col 8w, MSB = col 8w+7
        hex_str = "".join(f"{u16(slots[7-i]):04X}" for i in range(8))
        # 위 표현: 가장 왼쪽 hex 4글자 = MSB = col 8w+7, 가장 오른쪽 = LSB = col 8w.
        lines.append(hex_str)
    return lines

# input.txt : 3 img × 152 row × 19 word
with open("input.txt", "w") as f:
    for m in range(NUM_IMG):
        Xp_m = pad_to(X[m])
        for r in range(PAD_IMG):
            for line in pack_row_128b(Xp_m[r]):
                f.write(line + "\n")

def save_fmap_128b(path, fmap):
    """fmap: (NUM_IMG, CH, PAD_IMG, PAD_IMG) → 128b/word LSB-first."""
    with open(path, "w") as f:
        for m in range(fmap.shape[0]):
            for c in range(fmap.shape[1]):
                for r in range(PAD_IMG):
                    for line in pack_row_128b(fmap[m, c, r]):
                        f.write(line + "\n")

def save_out_128b(path, fmap):
    """fmap: (NUM_IMG, PAD_IMG, PAD_IMG) → 128b/word."""
    with open(path, "w") as f:
        for m in range(fmap.shape[0]):
            for r in range(PAD_IMG):
                for line in pack_row_128b(fmap[m, r]):
                    f.write(line + "\n")

save_fmap_128b("golden_L1.txt",  L1_pad)
save_fmap_128b("golden_L2.txt",  L2_pad)
save_out_128b ("golden_out.txt", OUT_pad)

# 디버그용 raw numpy dump
np.savez("golden.npz",
         W1=W1, W2=W2, W3=W3, B1=B1, B2=B2, B3=B3,
         X=X, L1_pad=L1_pad, L2_pad=L2_pad, OUT_pad=OUT_pad)
print(f"OK : input {NUM_IMG*NWORD_IMG} words, golden_L1/L2 {NUM_IMG*8*NWORD_IMG} words each, "
      f"golden_out {NUM_IMG*NWORD_IMG} words")
