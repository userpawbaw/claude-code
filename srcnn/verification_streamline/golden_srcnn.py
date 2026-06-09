#!/usr/bin/env python3
# golden_srcnn.py  — Q8.8 fixed-point SRCNN (1→8→4→1) golden model
#
# PE:        o = {product[31], product[22:8]}  =  (in * w) >> 8  (Q16.16 → Q8.8)
# tap order: line_buffer o_line_data[16*k +: 16] = tap k
#   tap 0=(r,c), 1=(r,c-1), 2=(r,c-2),
#   tap 3=(r-1,c), 4=(r-1,c-1)[center], 5=(r-1,c-2),
#   tap 6=(r-2,c), 7=(r-2,c-1), 8=(r-2,c-2)
# → output pixel (out_r, out_c) reads padded[out_r+2-dr][out_c+2-dc]
#   where tap k = (r - k//3, c - k%3) relative to fire position
#
# Weight file format (64-bit hex per line, LSB = slot[0]):
#   slot j = bits[16*j +: 16]
#   bias   = bits[63:48] = slot[3]  (for L2, L3)
#
# L1 bias = slot[oc % 4] of bias word (two words: oc 0-3, oc 4-7)

import sys
import numpy as np

INPUT_FILE = "/root/.claude/uploads/9964b73d-8e54-52ab-810e-6254193208bf/334e5d38-input.txt"
W_L1_FILE  = "/root/.claude/uploads/9964b73d-8e54-52ab-810e-6254193208bf/5c5f0b3f-weight_L1.txt"
W_L2_FILE  = "/root/.claude/uploads/9964b73d-8e54-52ab-810e-6254193208bf/d86ee955-weight_L2.txt"
W_L3_FILE  = "/root/.claude/uploads/9964b73d-8e54-52ab-810e-6254193208bf/405f09fd-weight_L3.txt"

IMG  = 150
NPIX = IMG * IMG  # 22500

# ---------------------------------------------------------------------------
# Helper: read hex file, return list of ints
# ---------------------------------------------------------------------------
def read_hex_file(path, width=4):
    """Read hex file. width=4 → 16-bit, width=16 → 64-bit."""
    vals = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if s:
                vals.append(int(s, 16))
    return vals

# ---------------------------------------------------------------------------
# PE: full 32-bit product  (잘라내기 없음 — PU에서만 saturation)
# ---------------------------------------------------------------------------
def pe(in_val, weight):
    """Signed 16-bit inputs → full 32-bit Q16.16 product (no truncation)."""
    if in_val >= 0x8000: in_val -= 0x10000
    if weight >= 0x8000: weight -= 0x10000
    # 32-bit signed product, clamped to int32 range for RTL fidelity
    product = in_val * weight
    # clamp to signed 32-bit (mimics DSP 32-bit output)
    product = max(-2147483648, min(2147483647, product))
    return product

def to_s16(v):
    v = int(v) & 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v

# ---------------------------------------------------------------------------
# pe_group: 9-PE array + 2-stage adder tree → 32-bit partial
# ---------------------------------------------------------------------------
def pe_group(window9, weights9):
    """window9, weights9: lists of 9 signed 16-bit ints → signed 32-bit."""
    pe_out = [pe(window9[i], weights9[i]) for i in range(9)]
    s1 = [pe_out[0]+pe_out[1]+pe_out[2],
          pe_out[3]+pe_out[4]+pe_out[5],
          pe_out[6]+pe_out[7]+pe_out[8]]
    return s1[0] + s1[1] + s1[2]

# ---------------------------------------------------------------------------
# 3×3 convolution with given PE+adder model, zero-pad 1
# ---------------------------------------------------------------------------
# tap k → offset (dr, dc):
#   tap 0-2: row offset 0 (current row), dc = 0,-1,-2
#   tap 3-5: row offset -1, dc = 0,-1,-2
#   tap 6-8: row offset -2, dc = 0,-1,-2
# When output fires at padded position (r, c), center = (r-1, c-1) in padded.
# For output pixel (out_r, out_c) in 0..149:
#   padded r_fire = out_r + 2,  c_fire = out_c + 2
#   tap k pixel = padded[r_fire - k//3][c_fire - k%3]
#               = padded[out_r + 2 - k//3][out_c + 2 - k%3]

def conv_layer(feat_in, weights, biases, num_oc, num_ic, relu=True):
    """
    feat_in : shape (num_ic, IMG, IMG)  — signed int (raw Q8.8)
    weights : shape (num_oc, num_ic, 9) — signed int16
    biases  : list[num_oc]              — signed int16
    Returns  : (num_oc, IMG, IMG)       — signed int16 (Q8.8, ReLU if requested)
    """
    # zero-pad each channel by 1 on all sides → (num_ic, IMG+2, IMG+2)
    padded = np.zeros((num_ic, IMG + 2, IMG + 2), dtype=np.int64)
    for ic in range(num_ic):
        padded[ic, 1:IMG+1, 1:IMG+1] = feat_in[ic]

    out = np.zeros((num_oc, IMG, IMG), dtype=np.int64)

    for out_r in range(IMG):
        for out_c in range(IMG):
            # window: tap k → padded[ic, out_r+2 - k//3, out_c+2 - k%3]
            for oc in range(num_oc):
                # sum partials over all in_ch
                total = 0
                for ic in range(num_ic):
                    w9 = [int(weights[oc, ic, k]) for k in range(9)]
                    p9 = [int(padded[ic, out_r + 2 - k//3, out_c + 2 - k%3]) for k in range(9)]
                    total += pe_group(p9, w9)
                # >>> 8 + bias  (arithmetic shift)
                q = (total >> 8) + int(biases[oc])
                # ReLU + saturation
                if relu:
                    q = max(0, min(32767, q))
                else:
                    q = max(-32768, min(32767, q))
                out[oc, out_r, out_c] = q

    return out.astype(np.int32)

# ---------------------------------------------------------------------------
# Load input (first image = first 22500 pixels)
# ---------------------------------------------------------------------------
raw_in = read_hex_file(INPUT_FILE, width=4)[:NPIX]
assert len(raw_in) == NPIX, f"Expected {NPIX} pixels, got {len(raw_in)}"
# sign-extend 16-bit
feat_in = np.array([to_s16(v) for v in raw_in], dtype=np.int32).reshape(1, IMG, IMG)
print(f"Input range: [{feat_in.min()}, {feat_in.max()}]  first 4: {feat_in.flat[:4].tolist()}")

# ---------------------------------------------------------------------------
# Load L1 weights  (20 words × 64-bit)
# Layer: 1 in_ch → 8 out_ch
# addr 2k   : oc 0-3 weights for tap k  (slots 0,1,2,3)
# addr 2k+1 : oc 4-7 weights for tap k
# addr 18   : bias oc 0-3 (slots 0-3)
# addr 19   : bias oc 4-7 (slots 0-3)
# ---------------------------------------------------------------------------
l1_raw = read_hex_file(W_L1_FILE, width=16)
assert len(l1_raw) == 20, f"L1 weights: expected 20 words, got {len(l1_raw)}"

def slot(word64, s):
    """Extract signed 16-bit slot s from 64-bit word."""
    return to_s16((word64 >> (16 * s)) & 0xFFFF)

w_l1 = np.zeros((8, 1, 9), dtype=np.int32)   # (oc, ic=1, tap)
for tap in range(9):
    w0 = l1_raw[2 * tap]
    w1 = l1_raw[2 * tap + 1]
    for oc in range(4):
        w_l1[oc, 0, tap] = slot(w0, oc)
    for oc in range(4, 8):
        w_l1[oc, 0, tap] = slot(w1, oc - 4)

bias_l1 = [0] * 8
for oc in range(4):
    bias_l1[oc] = slot(l1_raw[18], oc)
for oc in range(4, 8):
    bias_l1[oc] = slot(l1_raw[19], oc - 4)

print(f"L1 center weights (tap4): {[w_l1[oc,0,4] for oc in range(8)]}")
print(f"L1 biases: {bias_l1}")

# ---------------------------------------------------------------------------
# Load L2 weights  (76 words × 64-bit, 4 oc × 19 words)
# Layer: 8 in_ch → 4 out_ch
# Per oc block (19 words):
#   addr 2k   : ic 0-3 weights for tap k (slots 0-3)
#   addr 2k+1 : ic 4-7 weights for tap k
#   addr 18   : bias (slot 3 = bits[63:48])
# ---------------------------------------------------------------------------
l2_raw = read_hex_file(W_L2_FILE, width=16)
assert len(l2_raw) == 76, f"L2 weights: expected 76 words, got {len(l2_raw)}"

w_l2 = np.zeros((4, 8, 9), dtype=np.int32)   # (oc, ic, tap)
bias_l2 = [0] * 4
for oc in range(4):
    base = oc * 19
    for tap in range(9):
        w0 = l2_raw[base + 2 * tap]
        w1 = l2_raw[base + 2 * tap + 1]
        for ic in range(4):
            w_l2[oc, ic, tap] = slot(w0, ic)
        for ic in range(4, 8):
            w_l2[oc, ic, tap] = slot(w1, ic - 4)
    # bias = slot 3 (bits[63:48])
    bias_l2[oc] = slot(l2_raw[base + 18], 3)

print(f"L2 center weights (tap4, oc0): {[w_l2[0,ic,4] for ic in range(8)]}")
print(f"L2 biases: {bias_l2}")

# ---------------------------------------------------------------------------
# Load L3 weights  (10 words × 64-bit)
# Layer: 4 in_ch → 1 out_ch
# addr 0-8 : tap 0-8 weights (slots 0-3 = ic 0-3)
# addr 9   : bias (slot 3 = bits[63:48])
# ---------------------------------------------------------------------------
l3_raw = read_hex_file(W_L3_FILE, width=16)
assert len(l3_raw) == 10, f"L3 weights: expected 10 words, got {len(l3_raw)}"

w_l3 = np.zeros((1, 4, 9), dtype=np.int32)   # (oc=1, ic, tap)
for tap in range(9):
    for ic in range(4):
        w_l3[0, ic, tap] = slot(l3_raw[tap], ic)
bias_l3 = [slot(l3_raw[9], 3)]

print(f"L3 center weights (tap4): {[w_l3[0,ic,4] for ic in range(4)]}")
print(f"L3 bias: {bias_l3}")

# ---------------------------------------------------------------------------
# Run SRCNN pipeline
# ---------------------------------------------------------------------------
print("\nRunning L1 (1→8 ch)…")
feat_l1 = conv_layer(feat_in, w_l1, bias_l1, num_oc=8, num_ic=1, relu=True)
print(f"  L1 output range: [{feat_l1.min()}, {feat_l1.max()}]  ch0 first 4: {feat_l1[0].flat[:4].tolist()}")

print("Running L2 (8→4 ch)…")
feat_l2 = conv_layer(feat_l1, w_l2, bias_l2, num_oc=4, num_ic=8, relu=True)
print(f"  L2 output range: [{feat_l2.min()}, {feat_l2.max()}]  ch0 first 4: {feat_l2[0].flat[:4].tolist()}")

print("Running L3 (4→1 ch)…")
feat_l3 = conv_layer(feat_l2, w_l3, bias_l3, num_oc=1, num_ic=4, relu=False)
output = feat_l3[0]  # shape (150, 150)
print(f"  L3 output range: [{output.min()}, {output.max()}]  first 4: {output.flat[:4].tolist()}")

# ---------------------------------------------------------------------------
# Save output as hex (same format as RTL output stream)
# ---------------------------------------------------------------------------
out_path = "/home/user/claude-code/srcnn/verification_streamline/golden_output.txt"
with open(out_path, "w") as f:
    for r in range(IMG):
        for c in range(IMG):
            v = int(output[r, c]) & 0xFFFF
            f.write(f"{v:04X}\n")
print(f"\nGolden output saved to {out_path}")
print(f"First 10 output pixels (hex): {[f'{int(output.flat[i])&0xFFFF:04X}' for i in range(10)]}")
print(f"Last  10 output pixels (hex): {[f'{int(output.flat[i])&0xFFFF:04X}' for i in range(NPIX-10, NPIX)]}")
