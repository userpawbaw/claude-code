#!/usr/bin/env python3
# gen_golden.py — PU 구조 (srcnn/rtl_pu/) 용 golden 생성기.
# 변경점 (구 srcnn/verification/gen_golden.py 대비):
#  - 3-image 연속 처리 (NUM_IMG=3). input.txt 는 3 × 22500 = 67500 word.
#  - weight.txt 는 35 word (L1 9 + bias 1 + L2 18 + bias 1 + L3 5 + bias 1).
#  - bias 는 weight 뒤에 packing. L1: addr 9 = [b0..b3], L2: addr 28 = [b0,b1,0,0],
#    L3: addr 34 = [b,0,0,0].
#  - PE 규칙: o_output = {w_output[31], w_output[22:8]} (Q7.8).
#  - L1/L2: bias 더한 뒤 ReLU. L3: bias 더한 뒤 NO ReLU (마지막 refine 만).

import numpy as np

IMG       = 150
NPIX_IMG  = IMG * IMG     # 22500
NUM_IMG   = 3
np.random.seed(20250531)
ONE = 256

def u16(v): return int(v) & 0xFFFF
def s16_to_int(v):
    v = int(v) & 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

# ---- weight 생성 ([-0.125, 0.125] Q8.8) + bias ([-2.0, 2.0] Q8.8) ----
def gen_w(shape):
    return np.random.randint(-ONE//8, ONE//8 + 1, size=shape, dtype=np.int64)
def gen_b(shape):
    return np.random.randint(-2*ONE, 2*ONE + 1, size=shape, dtype=np.int64)

W1 = gen_w((4,1,9))
W2 = gen_w((2,4,9))
W3 = gen_w((1,2,9))
B1 = gen_b((4,))    # L1 bias per oc
B2 = gen_b((2,))    # L2 bias per oc
B3 = gen_b((1,))    # L3 bias

# ---- weight BRAM 패킹 ----
words = [[0,0,0,0] for _ in range(35)]
# L1 weight: addr 0..8
for n in range(9):
    for oc in range(4):
        words[n][oc] = u16(W1[oc,0,n])
# L1 bias: addr 9
for oc in range(4):
    words[9][oc] = u16(B1[oc])
# L2 weight: addr 10..27 (oc-interleave stride=2)
for oc in range(2):
    for tap in range(9):
        addr = 10 + oc + tap*2
        for ic in range(4):
            words[addr][ic] = u16(W2[oc,ic,tap])
# L2 bias: addr 28 (slots 2,3 = 0)
words[28][0] = u16(B2[0])
words[28][1] = u16(B2[1])
# L3 weight: addr 29..33 (5 word, sub_max=2)
for k in range(5):
    addr = 29 + k
    t0 = 2*k
    t1 = 2*k + 1
    words[addr][0] = u16(W3[0,0,t0])
    words[addr][1] = u16(W3[0,0,t1]) if t1 < 9 else 0
    words[addr][2] = u16(W3[0,1,t0])
    words[addr][3] = u16(W3[0,1,t1]) if t1 < 9 else 0
# L3 bias: addr 34 (slots 1,2,3 = 0)
words[34][0] = u16(B3[0])

with open("weight.txt","w") as f:
    for w in words:
        f.write(f"{w[0]:04X}{w[1]:04X}{w[2]:04X}{w[3]:04X}\n")

print(f"W1 [{W1.min()},{W1.max()}]  W2 [{W2.min()},{W2.max()}]  W3 [{W3.min()},{W3.max()}]")
print(f"B1 [{B1.min()},{B1.max()}]  B2 [{B2.min()},{B2.max()}]  B3 [{B3.min()},{B3.max()}]")

# ---- 입력 (3 img × 150×150, Q8.8 signed-positive 범위) ----
X = np.random.randint(0, 128, size=(NUM_IMG, IMG, IMG), dtype=np.int64) * ONE

# ---- conv 모델 (RTL 일치: full Q16.16 누적, 단일 late >>>8) ----
#   PE      : x(Q8.8) × w(Q8.8) → full 32-bit Q16.16 (no truncation)
#   pe_group: 9 tap full 합 (36-bit Q16.16)
#   PU      : 채널 full 합 → 단 한 번 >>>8 (Q16.16→Q8.8) → + bias(Q8.8) → saturate
#   ⇒ 탭/채널별 early truncation 없음. 비트 확장 누적 후 마지막에 한 번만 shift.
def conv3x3_full(inp, kernel):
    """3x3 same conv, full Q16.16 누적 (shift 없음)."""
    H,W = inp.shape
    pad = np.zeros((H+2, W+2), dtype=np.int64)
    pad[1:H+1, 1:W+1] = inp
    k = kernel.reshape(9).astype(np.int64)
    out = np.zeros((H,W), dtype=np.int64)
    for r in range(H):
        for c in range(W):
            win = pad[r:r+3, c:c+3].reshape(9).astype(np.int64)
            out[r,c] = int(np.sum(win * k))   # Q16.16
    return out

def shr8(x):
    """arithmetic >>> 8 (numpy int64 signed shift = sign-preserving)."""
    return np.asarray(x, dtype=np.int64) >> 8

# L1/L2 출력 saturate : ReLU(neg→0) + upper clip 0x7FFF
def sat_relu(v):
    v = np.asarray(v, dtype=np.int64)
    v = np.where(v < 0, 0, v)
    v = np.where(v > 0x7FFF, 0x7FFF, v)
    return v.astype(np.int64)

# L3 출력 saturate : bidirectional [-0x8000, 0x7FFF] (NO ReLU)
def sat_bidir(v):
    v = np.asarray(v, dtype=np.int64)
    v = np.where(v >  0x7FFF,  0x7FFF, v)
    v = np.where(v < -0x8000, -0x8000, v)
    return v.astype(np.int64)

# ---- 3 img 처리 ----
L1_all  = np.zeros((NUM_IMG, 4, IMG, IMG), dtype=np.int64)
L2_all  = np.zeros((NUM_IMG, 2, IMG, IMG), dtype=np.int64)
OUT_all = np.zeros((NUM_IMG, IMG, IMG), dtype=np.int64)

for m in range(NUM_IMG):
    L1 = np.zeros((4, IMG, IMG), dtype=np.int64)
    for oc in range(4):
        acc = conv3x3_full(X[m], W1[oc, 0])          # Q16.16
        L1[oc] = sat_relu(shr8(acc) + int(B1[oc]))   # >>>8 → +bias → ReLU+sat
    L2 = np.zeros((2, IMG, IMG), dtype=np.int64)
    for oc in range(2):
        acc = np.zeros((IMG, IMG), dtype=np.int64)
        for ic in range(4):
            acc += conv3x3_full(L1[ic], W2[oc, ic])  # 채널 full 합 (Q16.16)
        L2[oc] = sat_relu(shr8(acc) + int(B2[oc]))   # 단일 >>>8 → +bias → ReLU+sat
    acc = np.zeros((IMG, IMG), dtype=np.int64)
    for ic in range(2):
        acc += conv3x3_full(L2[ic], W3[0, ic])       # 채널 full 합 (Q16.16)
    OUT = sat_bidir(shr8(acc) + int(B3[0]))          # 단일 >>>8 → +bias → bidir sat (no ReLU)
    L1_all[m]  = L1
    L2_all[m]  = L2
    OUT_all[m] = OUT
    print(f"img{m}: L1 [{L1.min()},{L1.max()}]  L2 [{L2.min()},{L2.max()}]  OUT [{OUT.min()},{OUT.max()}]")

# ---- 파일 저장 ----
def to_hex16(v): return f"{int(v)&0xFFFF:04X}"
with open("input.txt","w") as f:
    for m in range(NUM_IMG):
        for r in range(IMG):
            for c in range(IMG):
                f.write(to_hex16(X[m,r,c]) + "\n")

def save_fmap(path, fmap_imgch):
    # shape (img, ch, H, W) or (img, H, W)
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
