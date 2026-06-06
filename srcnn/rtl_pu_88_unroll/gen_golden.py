#!/usr/bin/env python3
# gen_golden.py — preset 8_8 (UNROLLED 8 px/clk) golden 생성기.
#
# 변경점 (vs baseline rtl_pu_88/gen_golden.py):
#   - 입력/출력 stream 단위 : 16-bit × 1 → 128-bit × 1 = 8 col / clk.
#   - 메모리에 사전 패딩 포함 (option-2). image는 152×152 zero-border.
#   - 한 word = 8 lane (lane 0 = 가장 왼쪽 col, MSB slot bits[127:112]).
#   - input.txt / golden_L*.txt / golden_out.txt 모두 32 hex / line (128b).
#   - row 0 / row 151 + col 0 / col 151 위치는 모두 0 (border).
#   - weight.txt 는 baseline 과 완전 동일 (재로딩 schedule 만 단순화 예정).
#
# 한 image word 수 :
#   152 row × 19 col_word = 2888 word/ch/image.
#   input.txt : 1 ch × 2888 × 3 img = 8664 line.
#   golden_L1 : 8 ch × 2888 × 3 img = 69312 line.
#   golden_L2 : 8 ch × 2888 × 3 img = 69312 line.
#   golden_out: 1 ch × 2888 × 3 img = 8664 line.

import numpy as np
import os

IMG       = 150
PAD_IMG   = 152
NPIX_PAD  = PAD_IMG * PAD_IMG
NUM_IMG   = 3
MAX_CH    = 8
LANES     = 8                    # 8 px per word
WORDS_ROW = PAD_IMG // LANES     # 19

assert PAD_IMG % LANES == 0, "152 must be divisible by 8"

np.random.seed(20250605)
ONE = 256

def u16(v): return int(v) & 0xFFFF

def gen_w(shape):
    return np.random.randint(-ONE//8, ONE//8 + 1, size=shape, dtype=np.int64)
def gen_b(shape):
    return np.random.randint(-2*ONE, 2*ONE + 1, size=shape, dtype=np.int64)

# baseline 과 동일한 난수 seed → 동일 weight (regression 호환)
W1 = gen_w((8,1,9))
W2 = gen_w((8,8,9))
W3 = gen_w((1,8,9))
B1 = gen_b((8,))
B2 = gen_b((8,))
B3 = gen_b((1,))

# ---- weight.txt : baseline 과 동일 (128-bit × 93 word, slot 0 = MSB) ----
N_WORDS_W = 93
words = [[0]*MAX_CH for _ in range(N_WORDS_W)]
for n in range(9):
    for s in range(8): words[n][s] = u16(W1[s, 0, n])
for s in range(8):     words[9][s] = u16(B1[s])
for k in range(8):
    base = 10 + k*9
    for n in range(9):
        for s in range(8): words[base + n][s] = u16(W2[k, s, n])
for s in range(8): words[82][s] = u16(B2[s])
for n in range(9):
    for s in range(8): words[83 + n][s] = u16(W3[0, s, n])
words[92][0] = u16(B3[0])

os.makedirs("work", exist_ok=True)
with open("work/weight.txt","w") as f:
    for w in words:
        f.write("".join(f"{w[s]:04X}" for s in range(8)) + "\n")

print(f"W1 [{W1.min()},{W1.max()}]  W2 [{W2.min()},{W2.max()}]  W3 [{W3.min()},{W3.max()}]")
print(f"B1 [{B1.min()},{B1.max()}]  B2 [{B2.min()},{B2.max()}]  B3 [{B3.min()},{B3.max()}]")

# ---- 입력 : 150×150 → 152×152 zero-border padding ----
X     = np.random.randint(0, 128, size=(NUM_IMG, IMG, IMG), dtype=np.int64) * ONE
X_pad = np.zeros((NUM_IMG, PAD_IMG, PAD_IMG), dtype=np.int64)
X_pad[:, 1:1+IMG, 1:1+IMG] = X

# ---- conv 모델 (Q16.16 누적, baseline 과 동일) ----
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

# ---- conv 는 원본 150×150 위에서 same-padding, 결과 150×150 (baseline 동일) ----
L1_orig  = np.zeros((NUM_IMG, 8, IMG, IMG), dtype=np.int64)
L2_orig  = np.zeros((NUM_IMG, 8, IMG, IMG), dtype=np.int64)
OUT_orig = np.zeros((NUM_IMG, IMG, IMG), dtype=np.int64)

for m in range(NUM_IMG):
    L1 = np.zeros((8, IMG, IMG), dtype=np.int64)
    for oc in range(8):
        acc = conv3x3_same_q1616(X[m], W1[oc, 0])
        L1[oc] = to_q88_relu_sat(acc, B1[oc])
    L2 = np.zeros((8, IMG, IMG), dtype=np.int64)
    for oc in range(8):
        acc = np.zeros((IMG, IMG), dtype=np.int64)
        for ic in range(8):
            acc += conv3x3_same_q1616(L1[ic], W2[oc, ic])
        L2[oc] = to_q88_relu_sat(acc, B2[oc])
    acc = np.zeros((IMG, IMG), dtype=np.int64)
    for ic in range(8):
        acc += conv3x3_same_q1616(L2[ic], W3[0, ic])
    OUT = to_q88_bidir_sat(acc, B3[0])
    L1_orig[m]  = L1
    L2_orig[m]  = L2
    OUT_orig[m] = OUT
    print(f"img{m}: L1 [{L1.min()},{L1.max()}]  L2 [{L2.min()},{L2.max()}]  OUT [{OUT.min()},{OUT.max()}]")

# ---- 152×152 zero-border 형태로 확장 (URAM 저장 포맷) ----
def pad152(arr_orig):
    if arr_orig.ndim == 4:  # (N, C, H, W)
        N, C, H, W = arr_orig.shape
        out = np.zeros((N, C, PAD_IMG, PAD_IMG), dtype=np.int64)
        out[:, :, 1:1+H, 1:1+W] = arr_orig
    else:  # (N, H, W)
        N, H, W = arr_orig.shape
        out = np.zeros((N, PAD_IMG, PAD_IMG), dtype=np.int64)
        out[:, 1:1+H, 1:1+W] = arr_orig
    return out

L1_pad  = pad152(L1_orig)
L2_pad  = pad152(L2_orig)
OUT_pad = pad152(OUT_orig)

# ---- dump : 128-bit / line, lane 0 (가장 왼쪽 col) = MSB ----
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
print("OK — 128b/word, 152x152 padded golden written to ./work/")
