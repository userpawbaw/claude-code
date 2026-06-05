#!/usr/bin/env python3
# gen_inputs_L3.py
#  L3 검증용 입력:
#    - intermid2_3_init_ch0.txt, ch1, ch2, ch3 (16bit, 22500 lines each)
#        각 채널마다 ramp pattern: mem[i] = i & 0x7FFF
#    - weight_l3.txt: 10 words (9 weight + 1 bias)
#        identity kernel (tap 4 = 1 for all 4 in_ch), bias=0
#  기대 출력: 4 in_ch의 합 = 4 * input, Q8.8 windowing -> (4*i) >> 8 = i >> 6

IMG = 150
TOT = IMG * IMG

# 4 separate intermid2_3 ch URAMs (each 16-bit, ramp 0..22499)
for ch in range(4):
    with open(f"intermid2_3_init_ch{ch}.txt", "w") as f:
        for i in range(TOT):
            f.write(f"{i & 0x7FFF:04X}\n")

def pack_word(slots_lsb_first):
    w = 0
    for i, v in enumerate(slots_lsb_first):
        w |= (int(v) & 0xFFFF) << (16 * i)
    return f"{w:016X}"

lines = []
for tap in range(9):
    w_val = 1 if tap == 4 else 0
    # 1 word/tap: 4 in_ch in 1 word
    lines.append(pack_word([w_val] * 4))
# bias word (out_ch 0 bias = 0)
lines.append(pack_word([0, 0, 0, 0]))

assert len(lines) == 10
with open("weight_l3.txt", "w") as f:
    for ln in lines:
        f.write(ln + "\n")

print(f"4x intermid2_3_init_ch*.txt: {TOT} lines each (16-bit ramp)")
print(f"weight_l3.txt: {len(lines)} lines")
print(f"Expected L3 output stream: pixel i = (4*i) >> 8 = (i & 0x7FFF) >> 6")
print(f"Range: 0..{22499 >> 6} (=351)")
