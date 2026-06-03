#!/usr/bin/env python3
# gen_inputs_simple.py
#  L1 검증용 최소 입력 생성:
#    - input_l1.txt : 150x150 ramp (X[r][c] = r*150 + c, 15-bit positive)
#    - weight_l1.txt: identity kernel (tap 4 = 1, 나머지 0). bias 0. 8 out_ch 전부 동일.
#  예상 L1 출력: 모든 out_ch에 대해 입력 값 그대로 패스스루 (identity conv)
#  intermid1_2 URAM[i] = {8개 동일 픽셀 값의 packed} = 8 copies of X[i] in 128-bit

import sys

IMG = 150
TOT = IMG * IMG  # 22500

# ---- input_l1.txt: ramp 0..22499 ----
with open("input_l1.txt", "w") as f:
    for i in range(TOT):
        f.write(f"{i & 0x7FFF:04X}\n")

# ---- weight_l1.txt: identity kernel per out_ch ----
# Layout (20 words):
#   addr 2k    : tap k, out_ch 0~3 (each in LSB lane / 16bit slots, LSB=oc0, MSB=oc3)
#   addr 2k+1  : tap k, out_ch 4~7 (LSB=oc4, MSB=oc7)
#   addr 18    : bias 0~3 (LSB=b0, MSB=b3)
#   addr 19    : bias 4~7 (LSB=b4, MSB=b7)
# Tap 4 = center -> weight 1, 나머지 0. bias all 0.
#
# hex string format (16 chars per line, MSB-first display):
#   "MMMM IIII JJJJ KKKK"  where MMMM = slot[3] (bits[63:48]), KKKK = slot[0] (bits[15:0])
def pack_word(slots_lsb_first):
    """slots_lsb_first[0] -> bits[15:0], slots_lsb_first[3] -> bits[63:48].
    Return 16-hex string (MSB-first display)."""
    w = 0
    for i, v in enumerate(slots_lsb_first):
        w |= (int(v) & 0xFFFF) << (16 * i)
    return f"{w:016X}"

lines = []
for tap in range(9):
    w_val = 1 if tap == 4 else 0  # identity at center
    # addr 2*tap: out_ch 0~3, all same w_val
    lines.append(pack_word([w_val, w_val, w_val, w_val]))
    # addr 2*tap+1: out_ch 4~7, all same w_val
    lines.append(pack_word([w_val, w_val, w_val, w_val]))
# addr 18: bias 0~3 = all 0
lines.append(pack_word([0, 0, 0, 0]))
# addr 19: bias 4~7 = all 0
lines.append(pack_word([0, 0, 0, 0]))

assert len(lines) == 20
with open("weight_l1.txt", "w") as f:
    for ln in lines:
        f.write(ln + "\n")

print("input_l1.txt  (22500 lines, 16-bit hex ramp)")
print("weight_l1.txt (20 lines, 64-bit hex, identity kernel + zero bias)")
print("Expected L1 output: 입력 값 8채널로 passthrough (intermid1_2 URAM[i] = 8 copies of i)")
