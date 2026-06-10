#!/usr/bin/env python3
# gen_golden_real.py — 실제 입력 + 학습된 Q8.8 weight(q88_4_2) 로 golden 생성.
#   - 입력 : 업로드된 input_345.txt (3 img × 22500 = 67500 word, Q8.8 hex)
#   - weight: srcnn/bias&weight/q88_4_2{weight,bias}/  (W1 4x1x9, W2 2x4x9, W3 1x2x9)
#   - 모델 : RTL 일치 (full Q16.16 누적 → 채널 합 → 단일 >>>8 → +bias(Q8.8) → saturate)
#   - 출력 : input.txt / golden_L1.txt / golden_L2.txt / golden_out.txt / weight.txt
#            (weight.txt = pack_recursive_4_2 와 동일 35-word 패킹)

import os
import numpy as np

IMG      = 150
NPIX_IMG = IMG * IMG     # 22500
NUM_IMG  = 3

HERE   = os.path.dirname(os.path.abspath(__file__))
BW_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "bias&weight"))
SRC_IN = os.environ.get(
    "INPUT_TXT",
    "/root/.claude/uploads/60acc73a-dab0-5e99-960f-34c01a9cb772/15d1a93f-input_345.txt",
)

def u16(v): return int(v) & 0xFFFF

def load_hex_signed(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            v = int(line, 16) & 0xFFFF
            if v & 0x8000:
                v -= 0x10000
            out.append(v)
    return np.array(out, dtype=np.int64)

# ---- 학습된 weight / bias 로드 (oc 외측, ic 중간, 3x3 내측) ----
def load_w(li, oc, ic):
    arr = load_hex_signed(f"{BW_DIR}/q88_4_2weight/fixed_point_W{li}_hex.txt")
    assert arr.size == oc*ic*9, f"W{li}: got {arr.size}, want {oc*ic*9}"
    return arr.reshape(oc, ic, 9)

def load_b(li, oc):
    arr = load_hex_signed(f"{BW_DIR}/q88_4_2bias/fixed_point_B{li}_hex.txt")
    assert arr.size == oc, f"B{li}: got {arr.size}, want {oc}"
    return arr

W1 = load_w(1, 4, 1)   # (4,1,9)
W2 = load_w(2, 2, 4)   # (2,4,9)
W3 = load_w(3, 1, 2)   # (1,2,9)
B1 = load_b(1, 4)
B2 = load_b(2, 2)
B3 = load_b(3, 1)

# ---- 입력 로드 (3 img × 150×150) ----
Xflat = load_hex_signed(SRC_IN)
assert Xflat.size == NUM_IMG * NPIX_IMG, f"input: got {Xflat.size}, want {NUM_IMG*NPIX_IMG}"
X = Xflat.reshape(NUM_IMG, IMG, IMG)

# ---- weight BRAM 패킹 (pack_recursive_4_2 와 동일 35 word) ----
words = [[0, 0, 0, 0] for _ in range(35)]
for n in range(9):                       # L1 weight addr 0..8
    for oc in range(4):
        words[n][oc] = u16(W1[oc, 0, n])
for oc in range(4):                      # L1 bias addr 9
    words[9][oc] = u16(B1[oc])
for oc in range(2):                      # L2 weight addr 10..27 (stride=2)
    for tap in range(9):
        addr = 10 + oc + tap * 2
        for ic in range(4):
            words[addr][ic] = u16(W2[oc, ic, tap])
words[28][0] = u16(B2[0])                # L2 bias addr 28
words[28][1] = u16(B2[1])
for k in range(5):                       # L3 weight addr 29..33 (sub_max=2)
    addr = 29 + k
    t0, t1 = 2 * k, 2 * k + 1
    words[addr][0] = u16(W3[0, 0, t0])
    words[addr][1] = u16(W3[0, 0, t1]) if t1 < 9 else 0
    words[addr][2] = u16(W3[0, 1, t0])
    words[addr][3] = u16(W3[0, 1, t1]) if t1 < 9 else 0
words[34][0] = u16(B3[0])                # L3 bias addr 34
with open(os.path.join(HERE, "weight.txt"), "w") as f:
    for w in words:
        f.write(f"{w[0]:04X}{w[1]:04X}{w[2]:04X}{w[3]:04X}\n")

# ---- conv 모델 (RTL 일치: full Q16.16 누적, 단일 late >>>8) ----
def conv3x3_full(inp, kernel):
    # tap t = dr*3+dc (row-major), full Q16.16 누적 (벡터화)
    H, W = inp.shape
    pad = np.zeros((H + 2, W + 2), dtype=np.int64)
    pad[1:H + 1, 1:W + 1] = inp
    k = kernel.reshape(3, 3).astype(np.int64)
    out = np.zeros((H, W), dtype=np.int64)
    for dr in range(3):
        for dc in range(3):
            out += pad[dr:dr + H, dc:dc + W] * k[dr, dc]
    return out

def shr8(x):
    return np.asarray(x, dtype=np.int64) >> 8

def sat_relu(v):
    v = np.asarray(v, dtype=np.int64)
    v = np.where(v < 0, 0, v)
    v = np.where(v > 0x7FFF, 0x7FFF, v)
    return v.astype(np.int64)

def sat_bidir(v):
    v = np.asarray(v, dtype=np.int64)
    v = np.where(v >  0x7FFF,  0x7FFF, v)
    v = np.where(v < -0x8000, -0x8000, v)
    return v.astype(np.int64)

print(f"W1 [{W1.min()},{W1.max()}]  W2 [{W2.min()},{W2.max()}]  W3 [{W3.min()},{W3.max()}]")
print(f"B1 {B1.tolist()}  B2 {B2.tolist()}  B3 {B3.tolist()}")
print(f"X  [{X.min()},{X.max()}]")

L1_all  = np.zeros((NUM_IMG, 4, IMG, IMG), dtype=np.int64)
L2_all  = np.zeros((NUM_IMG, 2, IMG, IMG), dtype=np.int64)
OUT_all = np.zeros((NUM_IMG, IMG, IMG), dtype=np.int64)

for m in range(NUM_IMG):
    L1 = np.zeros((4, IMG, IMG), dtype=np.int64)
    for oc in range(4):
        acc = conv3x3_full(X[m], W1[oc, 0])
        L1[oc] = sat_relu(shr8(acc) + int(B1[oc]))
    L2 = np.zeros((2, IMG, IMG), dtype=np.int64)
    for oc in range(2):
        acc = np.zeros((IMG, IMG), dtype=np.int64)
        for ic in range(4):
            acc += conv3x3_full(L1[ic], W2[oc, ic])
        L2[oc] = sat_relu(shr8(acc) + int(B2[oc]))
    acc = np.zeros((IMG, IMG), dtype=np.int64)
    for ic in range(2):
        acc += conv3x3_full(L2[ic], W3[0, ic])
    OUT = sat_bidir(shr8(acc) + int(B3[0]))
    L1_all[m], L2_all[m], OUT_all[m] = L1, L2, OUT
    print(f"img{m}: L1 [{L1.min()},{L1.max()}]  L2 [{L2.min()},{L2.max()}]  OUT [{OUT.min()},{OUT.max()}]")

# ---- 파일 저장 ----
def to_hex16(v): return f"{int(v) & 0xFFFF:04X}"

with open(os.path.join(HERE, "input.txt"), "w") as f:
    for m in range(NUM_IMG):
        for r in range(IMG):
            for c in range(IMG):
                f.write(to_hex16(X[m, r, c]) + "\n")

def save_fmap(path, fmap):
    if fmap.ndim == 3:
        fmap = fmap[:, None, :, :]
    with open(path, "w") as f:
        for m in range(fmap.shape[0]):
            for c in range(fmap.shape[1]):
                for r in range(fmap.shape[2]):
                    for col in range(fmap.shape[3]):
                        f.write(to_hex16(fmap[m, c, r, col]) + "\n")

save_fmap(os.path.join(HERE, "golden_L1.txt"),  L1_all)
save_fmap(os.path.join(HERE, "golden_L2.txt"),  L2_all)
save_fmap(os.path.join(HERE, "golden_out.txt"), OUT_all)
np.savez(os.path.join(HERE, "golden.npz"),
         W1=W1, W2=W2, W3=W3, B1=B1, B2=B2, B3=B3,
         X=X, L1=L1_all, L2=L2_all, OUT=OUT_all)
print("OK")
