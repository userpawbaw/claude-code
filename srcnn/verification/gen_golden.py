#!/usr/bin/env python3
# gen_golden.py
# weight.txt(64bit 32word)를 notes 레이아웃대로 (재)패킹하여 W1/W2/W3 적용,
# 입력 생성, conv-only(또는 ReLU) golden 생성. RTL 시뮬과 대조용.
#
# PE 규칙 (PE.v / stubs.v 일치):
#   o_output = {w_output[31], w_output[22:8]}  -> Q7.8 (sign + 15bit)
# 따라서 입력/가중치 모두 Q8.8 스케일로 생성해야 곱셈 결과가 >>8 후
# 의미 있는 값으로 남는다.
import numpy as np

IMG = 150
np.random.seed(20250531)
ONE = 256  # Q8.8 의 1.0

def s16(h):
    v = int(h, 16) & 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def u16(v):
    return int(v) & 0xFFFF

# ---- 가중치 생성 (Q8.8 스케일) ----
# 작은 실수 가중치 (-2.0 ~ +2.0) 를 Q8.8 정수로 표현.
# 곱셈 결과가 의미 있는 Q7.8 범위로 살아남도록 한다.
def gen_w(shape):
    # 작은 실수 가중치 (분포 [-0.25, 0.25] Q8.8) — L2 누적이 15bit refine 범위
    # (|acc| <= 32767) 안에 들어오도록 제한. 실제 학습된 SRCNN weight 크기와도 부합.
    raw = np.random.randint(-ONE//8, ONE//8 + 1, size=shape, dtype=np.int64)
    return raw

W1 = gen_w((4,1,9))   # L1: 4 out_ch x 1 in_ch x 9 tap
W2 = gen_w((2,4,9))   # L2: 2 out_ch x 4 in_ch x 9 tap
W3 = gen_w((1,2,9))   # L3: 1 out_ch x 2 in_ch x 9 tap

# ---- 가중치 패킹 (weight.txt 32 word, 64bit/word) ----
# L1: addr 0-8, word_n = [K1-1-n][K2-1-n][K3-1-n][K4-1-n]
# L2: addr 9-26. oc0 = addr 9,11,..25; oc1 = addr 10,12,..26
#       word = [K{oc}-1-tap][K{oc}-2-tap][K{oc}-3-tap][K{oc}-4-tap]
# L3: addr 27-31. word_k=[ic1-(2k)][ic1-(2k+1)][ic2-(2k)][ic2-(2k+1)]
words = [[0,0,0,0] for _ in range(32)]
for n in range(9):
    for oc in range(4):
        words[n][oc] = u16(W1[oc,0,n])
for oc in range(2):
    for tap in range(9):
        addr = 9 + oc + tap*2
        for ic in range(4):
            words[addr][ic] = u16(W2[oc,ic,tap])
for k in range(5):
    addr = 27 + k
    t0 = 2*k
    t1 = 2*k+1
    words[addr][0] = u16(W3[0,0,t0])
    words[addr][1] = u16(W3[0,0,t1]) if t1 < 9 else 0
    words[addr][2] = u16(W3[0,1,t0])
    words[addr][3] = u16(W3[0,1,t1]) if t1 < 9 else 0

with open("weight.txt","w") as f:
    for w in words:
        f.write(f"{w[0]:04X}{w[1]:04X}{w[2]:04X}{w[3]:04X}\n")

print("복원된 weight 범위:")
print(f"  W1 {W1.shape} [{W1.min()},{W1.max()}]")
print(f"  W2 {W2.shape} [{W2.min()},{W2.max()}]")
print(f"  W3 {W3.shape} [{W3.min()},{W3.max()}]")

# ---- 입력 (Q8.8 스케일, signed 16bit 양수 범위 내) ----
# RTL 의 i_input 은 signed [15:0] (PE.v 입력도 signed). 0..0x7F00 (= 픽셀 0..127)
# 까지가 signed 16bit 양수 표현 범위. 픽셀 128 이상은 Q8.8 표현이 0x8000 이상이
# 되어 signed 해석에서 음수로 뒤집힌다 (golden 의 np.int64 양수 해석과 어긋남).
# 따라서 테스트 픽셀 범위를 0..127 로 제한한다.
# 실 데이터에서는 입력을 Q7.8 정도로 한 단계 더 축소하거나, 입력 path 를
# unsigned-aware 로 분기해야 한다 (현재 설계는 signed-only).
X_pix = np.random.randint(0, 128, size=(IMG, IMG), dtype=np.int64)
X = X_pix * ONE

def refine16(x):
    # 21/23bit signed 누적값 -> {sign, 하위15bit} 16bit signed 정제
    x = np.asarray(x, dtype=np.int64)
    sign = (x < 0).astype(np.int64)
    mag15 = np.abs(x) & 0x7FFF
    return np.where(sign==1, -mag15, mag15).astype(np.int64)

def pe_out(x_arr, w_scalar):
    # PE.v 규칙: w_output = i_input * r_weight (signed 32bit).
    #   o_output = {w_output[31], w_output[22:8]} (sign + bits[22:8]).
    # 즉 부호는 32bit 곱의 부호, 크기는 |prod| 의 (>>8) 의 하위 15bit.
    x = np.asarray(x_arr, dtype=np.int64)
    w = np.int64(w_scalar)
    prod  = x * w                                  # signed 32bit (np.int64 보관)
    prod32 = prod & 0xFFFFFFFF                     # 32bit unsigned 표현
    sign  = (prod32 >> 31) & 1
    mag15 = (prod32 >> 8) & 0x7FFF                 # bits[22:8]
    val16 = (sign << 15) | mag15                   # 16bit signed 표현
    return np.where(val16 & 0x8000, val16 - 0x10000, val16).astype(np.int64)

def conv3x3_same(inp, kernel):
    # PE rule 적용: 각 탭 별로 pe_out(x, w) -> 16bit 정제값을 모아 합산.
    #   합산은 정수(>=21bit) 누적 -> refine16 은 호출자에서 적용.
    H,W = inp.shape
    pad = np.zeros((H+2,W+2), dtype=np.int64)
    pad[1:H+1,1:W+1] = inp
    k = kernel.reshape(3,3).astype(np.int64)
    out = np.zeros((H,W), dtype=np.int64)
    for r in range(H):
        for c in range(W):
            win = pad[r:r+3,c:c+3].reshape(9)
            acc = np.int64(0)
            for t in range(9):
                acc += pe_out(win[t], k.reshape(9)[t])
            out[r,c] = acc
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
