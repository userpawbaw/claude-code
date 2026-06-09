#!/usr/bin/env python3
"""Golden for L2 isolation test: real L1+L2 weights, identity L3 (sum of channels, then >> 1 to match scale)."""

import numpy as np

INPUT_FILE  = "/root/.claude/uploads/9964b73d-8e54-52ab-810e-6254193208bf/334e5d38-input.txt"
W_L1_FILE   = "/root/.claude/uploads/9964b73d-8e54-52ab-810e-6254193208bf/5c5f0b3f-weight_L1.txt"
W_L2_FILE   = "/root/.claude/uploads/9964b73d-8e54-52ab-810e-6254193208bf/d86ee955-weight_L2.txt"

IMG  = 150
NPIX = IMG * IMG

def read_hex_file(path):
    vals = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if s: vals.append(int(s, 16))
    return vals

def to_s16(v):
    v = int(v) & 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v

def pe(a, b):
    a = to_s16(a); b = to_s16(b)
    return max(-2147483648, min(2147483647, a * b))

def pe_group(w9, p9):
    outs = [pe(p9[i], w9[i]) for i in range(9)]
    s = [outs[0]+outs[1]+outs[2], outs[3]+outs[4]+outs[5], outs[6]+outs[7]+outs[8]]
    return s[0]+s[1]+s[2]

def slot(word64, s):
    v = (word64 >> (16*s)) & 0xFFFF
    return to_s16(v)

def conv_layer(feat_in, weights, biases, num_oc, num_ic, relu=True):
    padded = np.zeros((num_ic, IMG+2, IMG+2), dtype=np.int64)
    for ic in range(num_ic):
        padded[ic, 1:IMG+1, 1:IMG+1] = feat_in[ic]
    out = np.zeros((num_oc, IMG, IMG), dtype=np.int64)
    for out_r in range(IMG):
        for out_c in range(IMG):
            for oc in range(num_oc):
                total = 0
                for ic in range(num_ic):
                    w9 = [int(weights[oc, ic, k]) for k in range(9)]
                    p9 = [int(padded[ic, out_r+2-k//3, out_c+2-k%3]) for k in range(9)]
                    total += pe_group(w9, p9)
                q = (total >> 8) + int(biases[oc])
                if relu: q = max(0, min(32767, q))
                else:    q = max(-32768, min(32767, q))
                out[oc, out_r, out_c] = q
    return out.astype(np.int32)

# Load input
raw_in = read_hex_file(INPUT_FILE)[:NPIX]
feat_in = np.array([to_s16(v) for v in raw_in], dtype=np.int32).reshape(1, IMG, IMG)
print(f"Input: [{feat_in.min()},{feat_in.max()}]  first4={feat_in.flat[:4].tolist()}")

# Load L1
l1_raw = read_hex_file(W_L1_FILE)
w_l1 = np.zeros((8, 1, 9), dtype=np.int32)
for tap in range(9):
    w0 = l1_raw[2*tap]; w1 = l1_raw[2*tap+1]
    for oc in range(4):   w_l1[oc, 0, tap] = slot(w0, oc)
    for oc in range(4,8): w_l1[oc, 0, tap] = slot(w1, oc-4)
bias_l1 = [0]*8
for oc in range(4):   bias_l1[oc] = slot(l1_raw[18], oc)
for oc in range(4,8): bias_l1[oc] = slot(l1_raw[19], oc-4)

print("Running L1...")
feat_l1 = conv_layer(feat_in, w_l1, bias_l1, num_oc=8, num_ic=1, relu=True)
print(f"  L1 range: [{feat_l1.min()},{feat_l1.max()}]  ch0 first4={feat_l1[0].flat[:4].tolist()}")

# Load L2
l2_raw = read_hex_file(W_L2_FILE)
w_l2 = np.zeros((4, 8, 9), dtype=np.int32)
bias_l2 = [0]*4
for oc in range(4):
    base = oc*19
    for tap in range(9):
        w0 = l2_raw[base+2*tap]; w1 = l2_raw[base+2*tap+1]
        for ic in range(4):   w_l2[oc, ic, tap] = slot(w0, ic)
        for ic in range(4,8): w_l2[oc, ic, tap] = slot(w1, ic-4)
    bias_l2[oc] = slot(l2_raw[base+18], 3)

print("Running L2...")
feat_l2 = conv_layer(feat_l1, w_l2, bias_l2, num_oc=4, num_ic=8, relu=True)
print(f"  L2 range: [{feat_l2.min()},{feat_l2.max()}]  ch0 first4={feat_l2[0].flat[:4].tolist()}")

# Identity L3: center tap = 64 (Q8.8 = 0.25 per channel, 4 channels → sum >> 8 = /256 * 4 ≈ /64)
# weight_l3_id.txt: tap4 (center) slots 0-3 = 0x0100 (256 = 1.0 in Q8.8 → product=256*in)
# after >>8: in; bias=0; sum 4 channels → ReLU(sum)
# Actually: identity L3 = sum of 4 channels passed through
# From weight_l3_id.txt generation: center tap = 0x0040 = 64 per IC (4 ICs, 1 OC)
# pe(in, 64) = in*64; pe_group = sum 9 taps * 64 (only center ≠ 0) = in_center * 64
# total = sum over 4 IC of in_center_ic * 64 = 64 * sum(4 ICs)
# q = total >> 8 = sum(4 ICs) * 64 / 256 = sum(4 ICs) / 4
print("Computing identity L3 (center tap=64 per IC, sum/4 of 4 channels)...")
# Identity: output = sum(feat_l2, axis=0) * 64 >> 8 = sum / 4, no relu
# Reproduce exactly what RTL does with weight_l3_id.txt
# Let's check what weight_l3_id.txt actually has
id3 = read_hex_file("/home/user/claude-code/srcnn/verification_streamline/weight_l3_id.txt")
print(f"  L3 id weights ({len(id3)} words):")
for i,w in enumerate(id3): print(f"    [{i:02d}] = {w:016X}")

# center tap = tap4 = word4 in l3_id
w_l3 = np.zeros((1, 4, 9), dtype=np.int32)
for tap in range(9):
    for ic in range(4):
        w_l3[0, ic, tap] = slot(id3[tap], ic)
bias_l3 = [slot(id3[9], 3)]
print(f"  L3 id center weights (tap4): {[w_l3[0,ic,4] for ic in range(4)]}")
print(f"  L3 id bias: {bias_l3}")

print("Running L3 (identity)...")
feat_l3 = conv_layer(feat_l2, w_l3, bias_l3, num_oc=1, num_ic=4, relu=False)
output = feat_l3[0]
print(f"  L3 range: [{output.min()},{output.max()}]  first4={output.flat[:4].tolist()}")

# Save golden for l2test
out_path = "/home/user/claude-code/srcnn/verification_streamline/golden_l2test.txt"
with open(out_path, "w") as f:
    for r in range(IMG):
        for c in range(IMG):
            v = int(output[r, c]) & 0xFFFF
            f.write(f"{v:04X}\n")
print(f"\nGolden saved to {out_path}")
print(f"First 10: {[f'{int(output.flat[i])&0xFFFF:04X}' for i in range(10)]}")
