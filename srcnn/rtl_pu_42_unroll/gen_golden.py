#!/usr/bin/env python3
# gen_golden.py — preset 4_2 (UNROLLED 8 px/clk, no L2 time-mux) golden.
#
# Channel chain : 1 → 4 (L1) → 2 (L2) → 1 (L3).
#
# Weight BRAM layout (128-bit × 30 words, slot 0 = MSB) :
#   addr 0..8  : L1 weight tap 0..8.  slot 0..3 = oc 0..3,  slot 4..7 = 0.
#   addr 9     : L1 bias.            slot 0..3 = oc 0..3 bias.
#   addr 10..18: L2 weight tap 0..8. slot 0..3 = oc=0 ic 0..3,
#                                    slot 4..7 = oc=1 ic 0..3.
#   addr 19    : L2 bias.            slot 0 = oc=0 bias, slot 1 = oc=1 bias.
#   addr 20..28: L3 weight tap 0..8. slot 0..1 = ic 0..1, slot 2..7 = 0.
#   addr 29    : L3 bias.            slot 0 = bias.
#
# Memory layout per image (8 px/word, 152 col → 19 words/row, 152 row):
#   input.txt   : 1 ch × 2888 word × 3 img = 8664 lines.
#   golden_L1   : 4 ch × 2888 × 3 = 34656 lines.
#   golden_L2   : 2 ch × 2888 × 3 = 17328 lines.
#   golden_out  : 1 ch × 2888 × 3 = 8664 lines.

import numpy as np
import os

IMG       = 150
PAD_IMG   = 152
NUM_IMG   = 3
LANES     = 8
WORDS_ROW = PAD_IMG // LANES     # 19

# 4_2 preset channels.
L1_OC = 4
L2_OC = 2
L2_IC = 4   # = L1_OC
L3_IC = 2   # = L2_OC

assert PAD_IMG % LANES == 0

np.random.seed(20250605)
ONE = 256

def u16(v): return int(v) & 0xFFFF

def gen_w(shape):
    return np.random.randint(-ONE//8, ONE//8 + 1, size=shape, dtype=np.int64)
def gen_b(shape):
    return np.random.randint(-2*ONE, 2*ONE + 1, size=shape, dtype=np.int64)

W1 = gen_w((L1_OC, 1,     9))   # 4 × 1 × 9
W2 = gen_w((L2_OC, L2_IC, 9))   # 2 × 4 × 9
W3 = gen_w((1,     L3_IC, 9))   # 1 × 2 × 9
B1 = gen_b((L1_OC,))
B2 = gen_b((L2_OC,))
B3 = gen_b((1,))

# ---- weight.txt : 30 words ----
N_WORDS_W = 30
words = [[0]*8 for _ in range(N_WORDS_W)]

# L1 : addr 0..8 weight, addr 9 bias.
for n in range(9):
    for oc in range(L1_OC):
        words[n][oc] = u16(W1[oc, 0, n])
for oc in range(L1_OC):
    words[9][oc] = u16(B1[oc])

# L2 : addr 10..18 weight, addr 19 bias.
#   slot 0..3 = oc=0 ic 0..3, slot 4..7 = oc=1 ic 0..3.
for n in range(9):
    for ic in range(L2_IC):
        words[10 + n][ic]         = u16(W2[0, ic, n])  # oc=0
        words[10 + n][L2_IC + ic] = u16(W2[1, ic, n])  # oc=1
words[19][0] = u16(B2[0])
words[19][1] = u16(B2[1])

# L3 : addr 20..28 weight, addr 29 bias.
for n in range(9):
    for ic in range(L3_IC):
        words[20 + n][ic] = u16(W3[0, ic, n])
words[29][0] = u16(B3[0])

os.makedirs("work", exist_ok=True)
with open("work/weight.txt", "w") as f:
    for w in words:
        f.write("".join(f"{w[s]:04X}" for s in range(8)) + "\n")

print(f"W1 [{W1.min()},{W1.max()}]  W2 [{W2.min()},{W2.max()}]  W3 [{W3.min()},{W3.max()}]")
print(f"B1 [{B1.min()},{B1.max()}]  B2 [{B2.min()},{B2.max()}]  B3 [{B3.min()},{B3.max()}]")

# ---- input : 150x150 random → 152x152 zero-pad ----
X     = np.random.randint(0, 128, size=(NUM_IMG, IMG, IMG), dtype=np.int64) * ONE
X_pad = np.zeros((NUM_IMG, PAD_IMG, PAD_IMG), dtype=np.int64)
X_pad[:, 1:1+IMG, 1:1+IMG] = X

# ---- conv 모델 (Q16.16 accumulate) ----
def conv3x3_same_q1616(inp_q88, kernel_q88):
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
                acc += int(win[t]) * int(k[t])
            out[r, c] = acc
    return out

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

L1_orig  = np.zeros((NUM_IMG, L1_OC, IMG, IMG), dtype=np.int64)
L2_orig  = np.zeros((NUM_IMG, L2_OC, IMG, IMG), dtype=np.int64)
OUT_orig = np.zeros((NUM_IMG, IMG, IMG), dtype=np.int64)

for m in range(NUM_IMG):
    L1 = np.zeros((L1_OC, IMG, IMG), dtype=np.int64)
    for oc in range(L1_OC):
        acc = conv3x3_same_q1616(X[m], W1[oc, 0])
        L1[oc] = to_q88_relu_sat(acc, B1[oc])
    L2 = np.zeros((L2_OC, IMG, IMG), dtype=np.int64)
    for oc in range(L2_OC):
        acc = np.zeros((IMG, IMG), dtype=np.int64)
        for ic in range(L2_IC):
            acc += conv3x3_same_q1616(L1[ic], W2[oc, ic])
        L2[oc] = to_q88_relu_sat(acc, B2[oc])
    acc = np.zeros((IMG, IMG), dtype=np.int64)
    for ic in range(L3_IC):
        acc += conv3x3_same_q1616(L2[ic], W3[0, ic])
    OUT = to_q88_bidir_sat(acc, B3[0])
    L1_orig[m]  = L1
    L2_orig[m]  = L2
    OUT_orig[m] = OUT
    print(f"img{m}: L1 [{L1.min()},{L1.max()}]  L2 [{L2.min()},{L2.max()}]  OUT [{OUT.min()},{OUT.max()}]")

def pad152(arr_orig):
    if arr_orig.ndim == 4:
        N, C, H, W = arr_orig.shape
        out = np.zeros((N, C, PAD_IMG, PAD_IMG), dtype=np.int64)
        out[:, :, 1:1+H, 1:1+W] = arr_orig
    else:
        N, H, W = arr_orig.shape
        out = np.zeros((N, PAD_IMG, PAD_IMG), dtype=np.int64)
        out[:, 1:1+H, 1:1+W] = arr_orig
    return out

L1_pad  = pad152(L1_orig)
L2_pad  = pad152(L2_orig)
OUT_pad = pad152(OUT_orig)

def dump_word128(f, eight_px):
    line = "".join(f"{u16(p):04X}" for p in eight_px)
    f.write(line + "\n")

def save_fmap_128(path, fmap):
    """fmap : (N, [C,] 152, 152). order : image → ch → row → col_word."""
    if fmap.ndim == 3:
        fmap = fmap[:, None, :, :]
    N, C, H, W = fmap.shape
    assert H == PAD_IMG and W == PAD_IMG
    with open(path, "w") as f:
        for m in range(N):
            for c in range(C):
                for r in range(H):
                    for cw in range(WORDS_ROW):
                        eight = fmap[m, c, r, cw*LANES:(cw+1)*LANES]
                        dump_word128(f, eight)

save_fmap_128("work/input.txt",      X_pad)
save_fmap_128("work/golden_L1.txt",  L1_pad)
save_fmap_128("work/golden_L2.txt",  L2_pad)
save_fmap_128("work/golden_out.txt", OUT_pad)

np.savez("work/golden.npz",
         W1=W1, W2=W2, W3=W3, B1=B1, B2=B2, B3=B3,
         X_orig=X, X_pad=X_pad,
         L1_orig=L1_orig, L2_orig=L2_orig, OUT_orig=OUT_orig,
         L1_pad=L1_pad,   L2_pad=L2_pad,   OUT_pad=OUT_pad)
print("OK — preset 4_2 golden written to ./work/")
