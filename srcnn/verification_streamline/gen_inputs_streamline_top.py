#!/usr/bin/env python3
# gen_inputs_streamline_top.py
#
# Generates input/weight files for tb_streamline_top end-to-end identity test.
#
# Weight strategy for output = input (passthrough):
#   L1 (1→8): center tap = 256 (Q8.8 = 1.0), bias = 0
#     product = i * 256; pe_group partial = 256i; >>> 8 = i          → L1_out = i
#   L2 (8→4): center tap = 32, bias = 0  (all 8 in_ch same weight)
#     sum = 8 * i * 32 = 256i; >>> 8 = i                             → L2_out = i
#   L3 (4→1): center tap = 64, bias = 0  (all 4 in_ch same weight)
#     sum = 4 * i * 64 = 256i; >>> 8 = i                             → L3_out = i
#
# Expected streamline output: pixel i = i  (ramp 0..22499)

import sys
IMG = 150
TOT = IMG * IMG  # 22500

def pack_word(slots_lsb_first):
    """slots[0]→bits[15:0], slots[3]→bits[63:48]. Return 16-char hex string."""
    w = 0
    for i, v in enumerate(slots_lsb_first):
        w |= (int(v) & 0xFFFF) << (16 * i)
    return f"{w:016X}"

# ---- input_st.txt: ramp 0..22499 (same as input_l1.txt) ----
with open("input_st.txt", "w") as f:
    for i in range(TOT):
        f.write(f"{i & 0x7FFF:04X}\n")

# ---- weight_l1_st.txt (20 words) ----
# addr 2k   : tap k, out_ch 0~3 (4 slots, LSB=oc0)
# addr 2k+1 : tap k, out_ch 4~7
# addr 18   : bias 0~3
# addr 19   : bias 4~7
# Center tap k=4 -> addr 8 and 9 get w_val=256; others 0.
lines_l1 = []
for tap in range(9):
    wv = 256 if tap == 4 else 0
    lines_l1.append(pack_word([wv, wv, wv, wv]))  # out_ch 0~3
    lines_l1.append(pack_word([wv, wv, wv, wv]))  # out_ch 4~7
lines_l1.append(pack_word([0, 0, 0, 0]))  # bias 0~3
lines_l1.append(pack_word([0, 0, 0, 0]))  # bias 4~7
assert len(lines_l1) == 20
with open("weight_l1_st.txt", "w") as f:
    f.write("\n".join(lines_l1) + "\n")

# ---- weight_l2_st.txt (76 words = 19/out_ch * 4 out_ch) ----
# Layout per out_ch (19 words):
#   addr 2k  : tap k, in_ch 0~3 (slots 0~3)
#   addr 2k+1: tap k, in_ch 4~7 (slots 0~3 used for ch 4,5,6,7 via i[1:0])
#   addr 18  : bias
# Center tap k=4 -> addr 8 and 9 within each block get w_val=32
lines_l2 = []
for oc in range(4):
    for tap in range(9):
        wv = 32 if tap == 4 else 0
        lines_l2.append(pack_word([wv, wv, wv, wv]))  # in_ch 0~3
        lines_l2.append(pack_word([wv, wv, wv, wv]))  # in_ch 4~7
    lines_l2.append(pack_word([0, 0, 0, 0]))  # bias
assert len(lines_l2) == 76
with open("weight_l2_st.txt", "w") as f:
    f.write("\n".join(lines_l2) + "\n")

# ---- weight_l3_st.txt (10 words) ----
# 1 word/tap: 4 in_ch weights in 1 word (slots 0~3 = ch 0~3)
# addr 0~8: tap 0~8, addr 9: bias
lines_l3 = []
for tap in range(9):
    wv = 64 if tap == 4 else 0
    lines_l3.append(pack_word([wv, wv, wv, wv]))
lines_l3.append(pack_word([0, 0, 0, 0]))  # bias
assert len(lines_l3) == 10
with open("weight_l3_st.txt", "w") as f:
    f.write("\n".join(lines_l3) + "\n")

print("Generated:")
print(f"  input_st.txt       : {TOT} lines, ramp 0..{TOT-1}")
print(f"  weight_l1_st.txt   : 20 lines, L1 identity (center tap=256)")
print(f"  weight_l2_st.txt   : 76 lines, L2 identity-chain (center tap=32)")
print(f"  weight_l3_st.txt   : 10 lines, L3 identity-chain (center tap=64)")
print(f"Expected streamline output: pixel[i] = i  (range 0..{TOT-1})")
