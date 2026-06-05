#!/usr/bin/env python3
# gen_inputs_L2.py
#  L2 검증용 입력:
#    - intermid1_2_init.txt : L1 출력처럼 8ch * ramp 데이터, 128bit packed
#                             word[i] = 8 copies of (i & 0x7FFF), LSB=ch0
#    - weight_l2.txt         : 76 words (19/out_ch * 4 out_ch)
#                              모든 4 out_ch가 identity kernel (tap 4 = 1, 나머지 0). bias 0.
#  기대 출력: intermid2_3 ch 0~3 동일,
#             URAM[i] = (8 * (i & 0x7FFF)) >> 8 = (i & 0x7FFF) >> 5
#             (sum of 8 ch * identity * Q8.8 window output)

IMG = 150
TOT = IMG * IMG  # 22500

def pack_8ch(val):
    """8 copies of 16-bit val packed into 128-bit (LSB=ch0)."""
    w = 0
    for k in range(8):
        w |= (int(val) & 0xFFFF) << (16 * k)
    return f"{w:032X}"

with open("intermid1_2_init.txt", "w") as f:
    for i in range(TOT):
        f.write(pack_8ch(i & 0x7FFF) + "\n")

def pack_word(slots_lsb_first):
    """slots[0] -> bits[15:0], slots[3] -> bits[63:48]. 16-hex string."""
    w = 0
    for i, v in enumerate(slots_lsb_first):
        w |= (int(v) & 0xFFFF) << (16 * i)
    return f"{w:016X}"

lines = []
for oc in range(4):
    # 18 weight words per out_ch
    for tap in range(9):
        w_val = 1 if tap == 4 else 0
        lines.append(pack_word([w_val] * 4))   # in_ch 0~3 tap k
        lines.append(pack_word([w_val] * 4))   # in_ch 4~7 tap k
    # 1 bias word per out_ch (bias=0)
    lines.append(pack_word([0, 0, 0, 0]))

assert len(lines) == 76
with open("weight_l2.txt", "w") as f:
    for ln in lines:
        f.write(ln + "\n")

print(f"intermid1_2_init.txt: {TOT} lines (128-bit packed)")
print(f"weight_l2.txt: {len(lines)} lines")
print(f"Expected ch 0~3 URAM[i] = (i & 0x7FFF) >> 5  (range 0..702)")
