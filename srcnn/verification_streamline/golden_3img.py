#!/usr/bin/env python3
# Generate 3-image golden + per-image input block files.
#  - input_real.txt holds 3 DIFFERENT 150x150 images, one pixel per line (hex).
#  - Splits into img_block0/1/2.txt (for testbench BRAM reload), and
#    runs the SRCNN golden model on each to produce golden_3img.txt (concatenated).
import numpy as np
import sys, os
sys.path.insert(0, os.path.dirname(__file__))

IMG = 150
NPIX = IMG * IMG  # 22500

def read_hex_file(path):
    with open(path) as f:
        return [int(line.strip(), 16) for line in f if line.strip()]

def to_s16(v):
    return v - 0x10000 if v >= 0x8000 else v

def slot(word64, s):
    return to_s16((word64 >> (16 * s)) & 0xFFFF)

def pe_group(p9, w9):
    return sum(p9[k] * w9[k] for k in range(9))

def conv_layer(feat_in, weights, biases, num_oc, num_ic, relu=True):
    padded = np.zeros((num_ic, IMG + 2, IMG + 2), dtype=np.int64)
    for ic in range(num_ic):
        padded[ic, 1:IMG+1, 1:IMG+1] = feat_in[ic]
    out = np.zeros((num_oc, IMG, IMG), dtype=np.int64)
    for out_r in range(IMG):
        for out_c in range(IMG):
            for oc in range(num_oc):
                total = 0
                for ic in range(num_ic):
                    w9 = [int(weights[oc, ic, k]) for k in range(9)]
                    p9 = [int(padded[ic, out_r + 2 - k//3, out_c + 2 - k%3]) for k in range(9)]
                    total += pe_group(p9, w9)
                q = (total >> 8) + int(biases[oc])
                if relu:
                    q = max(0, min(32767, q))
                else:
                    q = max(-32768, min(32767, q))
                out[oc, out_r, out_c] = q
    return out.astype(np.int32)

# Load weights (real)
l1_raw = read_hex_file("weight_l1_real.txt")
l2_raw = read_hex_file("weight_l2_real.txt")
l3_raw = read_hex_file("weight_l3_real.txt")

w_l1 = np.zeros((8, 1, 9), dtype=np.int32)
for tap in range(9):
    w0 = l1_raw[2*tap]; w1 = l1_raw[2*tap+1]
    for oc in range(4): w_l1[oc, 0, tap] = slot(w0, oc)
    for oc in range(4, 8): w_l1[oc, 0, tap] = slot(w1, oc-4)
bias_l1 = [slot(l1_raw[18], oc) for oc in range(4)] + [slot(l1_raw[19], oc) for oc in range(4)]

w_l2 = np.zeros((4, 8, 9), dtype=np.int32)
for oc in range(4):
    base = oc * 19
    for tap in range(9):
        w0 = l2_raw[base + 2*tap]; w1 = l2_raw[base + 2*tap + 1]
        for ic in range(4): w_l2[oc, ic, tap] = slot(w0, ic)
        for ic in range(4, 8): w_l2[oc, ic, tap] = slot(w1, ic-4)
bias_l2 = [slot(l2_raw[oc*19 + 18], 3) for oc in range(4)]

w_l3 = np.zeros((1, 4, 9), dtype=np.int32)
for tap in range(9):
    for ic in range(4):
        w_l3[0, ic, tap] = slot(l3_raw[tap], ic)
bias_l3 = [slot(l3_raw[9], 3)]

all_in = read_hex_file("input_real.txt")
print(f"Total input pixels: {len(all_in)} (expect {3*NPIX})")
assert len(all_in) >= 3*NPIX, "input_real.txt must hold >=3 images"

with open("golden_3img.txt", "w") as fg:
    for img_idx in range(3):
        raw_in = all_in[img_idx*NPIX:(img_idx+1)*NPIX]
        # per-image input block file for TB BRAM reload
        with open(f"img_block{img_idx}.txt", "w") as fb:
            for v in raw_in:
                fb.write(f"{v & 0xFFFF:04X}\n")
        feat_in = np.array([to_s16(v) for v in raw_in], dtype=np.int32).reshape(1, IMG, IMG)
        print(f"Image {img_idx} input range: [{feat_in.min()}, {feat_in.max()}]")
        feat_l1 = conv_layer(feat_in, w_l1, bias_l1, 8, 1, relu=True)
        feat_l2 = conv_layer(feat_l1, w_l2, bias_l2, 4, 8, relu=True)
        feat_l3 = conv_layer(feat_l2, w_l3, bias_l3, 1, 4, relu=False)
        out = feat_l3[0]
        print(f"Image {img_idx} output range: [{out.min()}, {out.max()}]")
        for v in out.flat:
            fg.write(f"{int(v) & 0xFFFF:04X}\n")
print("Wrote golden_3img.txt (67500 px) + img_block0/1/2.txt")
