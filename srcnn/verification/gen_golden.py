#!/usr/bin/env python3
# gen_golden.py
# weight.txt(64bit 32word)를 notes 레이아웃대로 역패킹하여 W1/W2/W3 복원,
# 입력 생성, conv-only(또는 ReLU) golden 생성. RTL 시뮬과 대조용.
import numpy as np

IMG = 150
np.random.seed(20250531)

def s16(h):
    v = int(h, 16) & 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

# weight.txt 읽기 -> 각 word를 4개 16bit slot으로 (MSB first)
words = []
with open("weight.txt") as f:
    for line in f:
        line = line.strip()
        if not line: continue
        slots = [s16(line[0:4]), s16(line[4:8]), s16(line[8:12]), s16(line[12:16])]
        words.append(slots)
assert len(words) == 32, f"expected 32 words, got {len(words)}"

# ---- 역패킹 ----
# L1: addr 0-8, word_n = [K1-1-n][K2-1-n][K3-1-n][K4-1-n]  (out_ch=4, in_ch=1, tap n)
W1 = np.zeros((4,1,9), dtype=np.int64)
for n in range(9):
    for oc in range(4):
        W1[oc,0,n] = words[n][oc]

# L2: addr 9-26 (18 word). oc0 = addr 9,11,..25; oc1 = addr 10,12,..26
#   word = [K{oc}-1-tap][K{oc}-2-tap][K{oc}-3-tap][K{oc}-4-tap] (in_ch 1..4)
W2 = np.zeros((2,4,9), dtype=np.int64)
for oc in range(2):
    for tap in range(9):
        addr = 9 + oc + tap*2     # base9 + oc*1 + tap*2
        for ic in range(4):
            W2[oc,ic,tap] = words[addr][ic]

# L3: addr 27-31 (5 word). word_k=[ic1-(2k)][ic1-(2k+1)][ic2-(2k)][ic2-(2k+1)]
#   마지막 word(k=4)는 tap8 + 0패딩
W3 = np.zeros((1,2,9), dtype=np.int64)
for k in range(5):
    addr = 27 + k
    w = words[addr]
    t0 = 2*k
    t1 = 2*k+1
    # ic1 (group0): sub0=slot0, sub1=slot1
    W3[0,0,t0] = w[0]
    if t1 < 9: W3[0,0,t1] = w[1]
    # ic2 (group1): sub0=slot2, sub1=slot3
    W3[0,1,t0] = w[2]
    if t1 < 9: W3[0,1,t1] = w[3]

print("복원된 weight 범위:")
print(f"  W1 {W1.shape} [{W1.min()},{W1.max()}]")
print(f"  W2 {W2.shape} [{W2.min()},{W2.max()}]")
print(f"  W3 {W3.shape} [{W3.min()},{W3.max()}]")

# ---- 입력 (ref와 동일 시드/범위) ----
X = np.random.randint(0, 16, size=(IMG, IMG), dtype=np.int64)

def refine16(x):
    x = np.asarray(x, dtype=np.int64)
    sign = (x < 0).astype(np.int64)
    mag15 = np.abs(x) & 0x7FFF
    return np.where(sign==1, -mag15, mag15).astype(np.int64)

def conv3x3_same(inp, kernel):
    H,W = inp.shape
    pad = np.zeros((H+2,W+2), dtype=np.int64)
    pad[1:H+1,1:W+1] = inp
    k = kernel.reshape(3,3).astype(np.int64)
    out = np.zeros((H,W), dtype=np.int64)
    for r in range(H):
        for c in range(W):
            out[r,c] = np.sum(pad[r:r+3,c:c+3]*k)
    return out

import sys
USE_RELU = (len(sys.argv)>1 and sys.argv[1]=="relu")
def act(x): return np.maximum(x,0) if USE_RELU else x

# L1: 1->4
L1 = np.zeros((4,IMG,IMG), dtype=np.int64)
for oc in range(4):
    L1[oc] = refine16(act(conv3x3_same(X, W1[oc,0])))
# L2: 4->2
L2 = np.zeros((2,IMG,IMG), dtype=np.int64)
for oc in range(2):
    acc = np.zeros((IMG,IMG), dtype=np.int64)
    for ic in range(4):
        acc += conv3x3_same(L1[ic], W2[oc,ic])
    L2[oc] = refine16(act(acc))
# L3: 2->1
acc = np.zeros((IMG,IMG), dtype=np.int64)
for ic in range(2):
    acc += conv3x3_same(L2[ic], W3[0,ic])
OUT = refine16(act(acc))

def to_hex16(v): return f"{int(v)&0xFFFF:04X}"
def save_fmap(path, fmap):
    with open(path,"w") as f:
        if fmap.ndim==2: fmap = fmap[None,...]
        for c in range(fmap.shape[0]):
            for r in range(fmap.shape[1]):
                for col in range(fmap.shape[2]):
                    f.write(to_hex16(fmap[c,r,col])+"\n")

# input.txt (150x150)
with open("input.txt","w") as f:
    for r in range(IMG):
        for c in range(IMG):
            f.write(to_hex16(X[r,c])+"\n")

save_fmap("golden_L1.txt", L1)
save_fmap("golden_L2.txt", L2)
save_fmap("golden_out.txt", OUT)

print(f"\nReLU={'ON' if USE_RELU else 'OFF'}")
print(f"L1 [{L1.min()},{L1.max()}]  L2 [{L2.min()},{L2.max()}]  OUT [{OUT.min()},{OUT.max()}]")
# 오버플로 점검
raw_max=0
for oc in range(2):
    acc=np.zeros((IMG,IMG),dtype=np.int64)
    for ic in range(4): acc+=conv3x3_same(L1[ic],W2[oc,ic])
    raw_max=max(raw_max,int(np.abs(acc).max()))
print(f"L2 raw max |acc| = {raw_max} (15bit limit 32767) -> {'OK' if raw_max<=32767 else 'OVERFLOW'}")
np.savez("golden.npz", W1=W1,W2=W2,W3=W3,X=X,L1=L1,L2=L2,OUT=OUT)
