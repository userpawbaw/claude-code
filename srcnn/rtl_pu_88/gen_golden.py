#!/usr/bin/env python3
# gen_golden.py — PU 구조 (srcnn/rtl_pu_88/) 용 golden 생성기 (preset 8_8).
#  - 3-image 연속 처리, NUM_IMG=3. input.txt = 3 × 22500 = 67500 word.
#  - weight.txt = 93 word, 128-bit (32 hex chars / line).
#       L1:  addr 0..8 weights, 9 bias.
#       L2:  addr (10+k*9)..(18+k*9) per oc=k(0..7), bias at addr 82.
#       L3:  addr 83..91 weights, 92 bias.
#  - 한 word = 8 × 16-bit slot. slot index s : bits[16*(7-s) +: 16].
#       L1 tap n:    slot s (0..7) = W1[s, 0, n]
#       L1 bias:     slot s = B1[s]
#       L2 oc=k,tap n: slot s = W2[k, s, n]   (s = ic)
#       L2 bias:     slot s = B2[s]
#       L3 tap n:    slot s = W3[0, s, n]
#       L3 bias:     slot 0 = B3[0], 나머지 0
#  - PE 규칙: o_output = {w_output[31], w_output[22:8]} (Q7.8).
#  - L1/L2: bias 더한 뒤 ReLU. L3: bias 더한 뒤 NO ReLU.

import numpy as np

IMG       = 150
NPIX_IMG  = IMG * IMG
NUM_IMG   = 3
np.random.seed(20250605)
ONE = 256
MAX_CH = 8

def u16(v): return int(v) & 0xFFFF

def gen_w(shape):
    return np.random.randint(-ONE//8, ONE//8 + 1, size=shape, dtype=np.int64)
def gen_b(shape):
    return np.random.randint(-2*ONE, 2*ONE + 1, size=shape, dtype=np.int64)

W1 = gen_w((8,1,9))   # 8 oc x 1 ic x 9 tap
W2 = gen_w((8,8,9))   # 8 oc x 8 ic x 9 tap
W3 = gen_w((1,8,9))   # 1 oc x 8 ic x 9 tap
B1 = gen_b((8,))
B2 = gen_b((8,))
B3 = gen_b((1,))

# ---- weight BRAM 패킹 ----
N_WORDS = 93
words = [[0]*MAX_CH for _ in range(N_WORDS)]

# L1 weights (addr 0..8)
for n in range(9):
    for s in range(8):
        words[n][s] = u16(W1[s, 0, n])
# L1 bias (addr 9)
for s in range(8):
    words[9][s] = u16(B1[s])

# L2 weights (oc-block)
for k in range(8):
    base = 10 + k*9
    for n in range(9):
        for s in range(8):
            words[base + n][s] = u16(W2[k, s, n])
# L2 bias (addr 82)
for s in range(8):
    words[82][s] = u16(B2[s])

# L3 weights (addr 83..91)
for n in range(9):
    for s in range(8):
        words[83 + n][s] = u16(W3[0, s, n])
# L3 bias (addr 92)
words[92][0] = u16(B3[0])

# 128-bit hex line: slot0 first (MSB)
with open("weight.txt","w") as f:
    for w in words:
        line = "".join(f"{w[s]:04X}" for s in range(8))
        f.write(line + "\n")

print(f"W1 [{W1.min()},{W1.max()}]  W2 [{W2.min()},{W2.max()}]  W3 [{W3.min()},{W3.max()}]")
print(f"B1 [{B1.min()},{B1.max()}]  B2 [{B2.min()},{B2.max()}]  B3 [{B3.min()},{B3.max()}]")

# ---- 입력 (3 img × 150×150, Q8.8 positive: pixel 0..127) ----
X = np.random.randint(0, 128, size=(NUM_IMG, IMG, IMG), dtype=np.int64) * ONE

# ---- conv 모델 (README spec: full Q16.16 accumulate → >>8 → +bias(Q8.8) → sat) ----
def conv3x3_same_q1616(inp_q88, kernel_q88):
    """입력/가중치 Q8.8 (int16) → 3x3 conv, Q16.16 정수 누적."""
    H, W = inp_q88.shape
    pad = np.zeros((H+2, W+2), dtype=np.int64)
    pad[1:H+1, 1:W+1] = inp_q88
    k = kernel_q88.reshape(9).astype(np.int64)
    out = np.zeros((H, W), dtype=np.int64)
    for r in range(H):
        for c in range(W):
            win = pad[r:r+3, c:c+3].reshape(9)
            acc = 0
            for t in range(9):
                acc += int(win[t]) * int(k[t])   # Q16.16, full precision
            out[r, c] = acc
    return out   # int64, Q16.16

def to_q88_relu_sat(acc_q1616, bias_q88):
    """L1/L2: (acc>>8) + bias → ReLU + upper sat (0..0x7FFF) → int16."""
    v = (acc_q1616 >> 8) + int(bias_q88)        # arithmetic shift right
    v = np.where(v < 0, 0, v)
    v = np.where(v > 0x7FFF, 0x7FFF, v)
    return v.astype(np.int64)                    # 0..0x7FFF, treated as Q8.8

def to_q88_bidir_sat(acc_q1616, bias_q88):
    """L3: (acc>>8) + bias → bidirectional sat (-0x8000..0x7FFF) → int16."""
    v = (acc_q1616 >> 8) + int(bias_q88)
    v = np.where(v >  0x7FFF,  0x7FFF, v)
    v = np.where(v < -0x8000, -0x8000, v)
    # 16-bit two's complement 표현 (음수 → +0x10000 처리는 to_hex16 에서)
    return v.astype(np.int64)

L1_all  = np.zeros((NUM_IMG, 8, IMG, IMG), dtype=np.int64)
L2_all  = np.zeros((NUM_IMG, 8, IMG, IMG), dtype=np.int64)
OUT_all = np.zeros((NUM_IMG, IMG, IMG), dtype=np.int64)

for m in range(NUM_IMG):
    # L1 : Q16.16 누적 → >>8 + bias → ReLU+sat
    L1 = np.zeros((8, IMG, IMG), dtype=np.int64)
    for oc in range(8):
        acc_q1616 = conv3x3_same_q1616(X[m], W1[oc, 0])
        L1[oc] = to_q88_relu_sat(acc_q1616, B1[oc])
    # L2 : Σic Q16.16 누적 → >>8 + bias → ReLU+sat
    L2 = np.zeros((8, IMG, IMG), dtype=np.int64)
    for oc in range(8):
        acc_q1616 = np.zeros((IMG, IMG), dtype=np.int64)
        for ic in range(8):
            acc_q1616 += conv3x3_same_q1616(L1[ic], W2[oc, ic])
        L2[oc] = to_q88_relu_sat(acc_q1616, B2[oc])
    # L3 : Σic Q16.16 누적 → >>8 + bias → bidirectional sat (no ReLU)
    acc_q1616 = np.zeros((IMG, IMG), dtype=np.int64)
    for ic in range(8):
        acc_q1616 += conv3x3_same_q1616(L2[ic], W3[0, ic])
    OUT = to_q88_bidir_sat(acc_q1616, B3[0])
    L1_all[m]  = L1
    L2_all[m]  = L2
    OUT_all[m] = OUT
    print(f"img{m}: L1 [{L1.min()},{L1.max()}]  L2 [{L2.min()},{L2.max()}]  OUT [{OUT.min()},{OUT.max()}]")

def to_hex16(v): return f"{int(v)&0xFFFF:04X}"
with open("input.txt","w") as f:
    for m in range(NUM_IMG):
        for r in range(IMG):
            for c in range(IMG):
                f.write(to_hex16(X[m,r,c]) + "\n")

def save_fmap(path, fmap_imgch):
    if fmap_imgch.ndim == 3:
        fmap_imgch = fmap_imgch[:, None, :, :]
    with open(path, "w") as f:
        for m in range(fmap_imgch.shape[0]):
            for c in range(fmap_imgch.shape[1]):
                for r in range(fmap_imgch.shape[2]):
                    for col in range(fmap_imgch.shape[3]):
                        f.write(to_hex16(fmap_imgch[m,c,r,col]) + "\n")

save_fmap("golden_L1.txt",  L1_all)
save_fmap("golden_L2.txt",  L2_all)
save_fmap("golden_out.txt", OUT_all)

np.savez("golden.npz", W1=W1,W2=W2,W3=W3,B1=B1,B2=B2,B3=B3,
         X=X, L1=L1_all, L2=L2_all, OUT=OUT_all)
print("OK")
