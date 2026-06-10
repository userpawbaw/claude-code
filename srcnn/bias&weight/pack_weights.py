#!/usr/bin/env python3
# pack_weights.py — bias&weight/ 의 trained Q8.8 가중치를 각 설계의 weight.txt 포맷으로 패킹.
#
# 입력 (`srcnn/bias&weight/`):
#   q88_4_2{weight,bias}/  : recursive 4_2  (W1: 4x1x9, W2: 2x4x9, W3: 1x2x9)
#   q88_8_4{weight,bias}/  : streamline 8_4 (W1: 8x1x9, W2: 4x8x9, W3: 1x4x9)
#   q88_8_8{weight,bias}/  : recursive 8_8  (W1: 8x1x9, W2: 8x8x9, W3: 1x8x9)
#
# 가중치 파일 순서 (SRCNN_weight_order.png) :
#   외측 oc → 중간 ic → 내측 3×3 row-major
#
# 출력:
#   srcnn/rtl_pu/work/weight.txt        (4_2 recursive, 64bit × 35 word)
#   srcnn/rtl_pu_88/work/weight.txt     (8_8 recursive, 128bit × 93 word)
#   srcnn/srcnn_streamline/work/weight_L1.txt (8_4 streamline L1, 64bit × 20)
#   srcnn/srcnn_streamline/work/weight_L2.txt (8_4 streamline L2, 64bit × 76)
#   (streamline L3 는 RTL 미존재로 패킹 보류)

import os
import numpy as np

ROOT       = os.path.dirname(os.path.abspath(__file__))
BW_DIR     = ROOT
REPO_ROOT  = os.path.normpath(os.path.join(ROOT, ".."))  # srcnn/

def load_hex(path):
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

def load_layer(preset_tag, oc, ic):
    """파일 순서 (oc 외측, ic 중간, 3x3 내측) → (oc, ic, 9) numpy."""
    wpath = f"{BW_DIR}/q88_{preset_tag}weight/fixed_point_W{{}}_hex.txt"
    bpath = f"{BW_DIR}/q88_{preset_tag}bias/fixed_point_B{{}}_hex.txt"
    Ws = []
    for li in (1, 2, 3):
        arr = load_hex(wpath.format(li))
        expect = oc[li-1] * ic[li-1] * 9
        assert arr.size == expect, f"L{li} {preset_tag}: got {arr.size}, want {expect}"
        Ws.append(arr.reshape(oc[li-1], ic[li-1], 9))
    Bs = []
    for li in (1, 2, 3):
        arr = load_hex(bpath.format(li))
        assert arr.size == oc[li-1], f"B{li} {preset_tag}: got {arr.size}, want {oc[li-1]}"
        Bs.append(arr)
    return Ws, Bs

def u16(v):
    return int(v) & 0xFFFF

def pack64_msb(slots):
    """slot 0 at bits[63:48], slot 1 [47:32], slot 2 [31:16], slot 3 [15:0]. (4_2/recursive)"""
    assert len(slots) == 4
    return "".join(f"{u16(s):04X}" for s in slots)

def pack128_msb(slots):
    """slot 0 at bits[127:112] ... slot 7 [15:0]. (8_8/recursive)"""
    assert len(slots) == 8
    return "".join(f"{u16(s):04X}" for s in slots)

def pack64_lsb(slots):
    """slot 0 at bits[15:0], slot 1 [31:16], slot 2 [47:32], slot 3 [63:48]. (streamline)"""
    assert len(slots) == 4
    return "".join(f"{u16(s):04X}" for s in reversed(slots))

# ============================================================
# 1) recursive 4_2  (srcnn/rtl_pu)
#    W1: (4,1,9), W2: (2,4,9), W3: (1,2,9)
# ============================================================
def pack_recursive_4_2():
    (W1, W2, W3), (B1, B2, B3) = load_layer("4_2", oc=(4,2,1), ic=(1,4,2))
    N_WORDS = 35
    words = [[0,0,0,0] for _ in range(N_WORDS)]
    # L1 weights addr 0..8: slot oc(0..3) = W1[oc,0,n]
    for n in range(9):
        for oc in range(4):
            words[n][oc] = W1[oc, 0, n]
    # L1 bias addr 9: slot oc = B1[oc]
    for oc in range(4):
        words[9][oc] = B1[oc]
    # L2 weights addr 10..27 (oc-interleave stride=2): addr = 10 + oc + tap*2, slot ic = W2[oc,ic,tap]
    for oc in range(2):
        for tap in range(9):
            addr = 10 + oc + tap*2
            for ic in range(4):
                words[addr][ic] = W2[oc, ic, tap]
    # L2 bias addr 28: slots[0,1] = B2, slots[2,3] = 0
    words[28][0] = B2[0]
    words[28][1] = B2[1]
    # L3 weights addr 29..33 (sub_max=2): 5 words pack 9 taps × 2 ic
    for k in range(5):
        addr = 29 + k
        t0, t1 = 2*k, 2*k + 1
        words[addr][0] = W3[0, 0, t0]
        words[addr][1] = W3[0, 0, t1] if t1 < 9 else 0
        words[addr][2] = W3[0, 1, t0]
        words[addr][3] = W3[0, 1, t1] if t1 < 9 else 0
    # L3 bias addr 34: slot 0 = B3[0], rest 0
    words[34][0] = B3[0]
    out = os.path.join(REPO_ROOT, "rtl_pu", "work", "weight.txt")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        for w in words:
            f.write(pack64_msb(w) + "\n")
    print(f"[recursive 4_2] {out}  ({N_WORDS} words)")

# ============================================================
# 2) recursive 8_8  (srcnn/rtl_pu_88)
#    W1: (8,1,9), W2: (8,8,9), W3: (1,8,9)
# ============================================================
def pack_recursive_8_8():
    (W1, W2, W3), (B1, B2, B3) = load_layer("8_8", oc=(8,8,1), ic=(1,8,8))
    N_WORDS = 93
    words = [[0]*8 for _ in range(N_WORDS)]
    # L1 weights addr 0..8: slot oc(0..7) = W1[oc,0,n]
    for n in range(9):
        for oc in range(8):
            words[n][oc] = W1[oc, 0, n]
    # L1 bias addr 9
    for oc in range(8):
        words[9][oc] = B1[oc]
    # L2 weights oc-block: base = 10 + k*9, k=0..7. addr base+n, slot ic = W2[k,ic,n]
    for k in range(8):
        base = 10 + k*9
        for n in range(9):
            for ic in range(8):
                words[base + n][ic] = W2[k, ic, n]
    # L2 bias addr 82
    for s in range(8):
        words[82][s] = B2[s]
    # L3 weights addr 83..91: slot ic = W3[0,ic,n]
    for n in range(9):
        for ic in range(8):
            words[83 + n][ic] = W3[0, ic, n]
    # L3 bias addr 92: slot 0 = B3[0], rest 0
    words[92][0] = B3[0]
    out = os.path.join(REPO_ROOT, "rtl_pu_88", "work", "weight.txt")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        for w in words:
            f.write(pack128_msb(w) + "\n")
    print(f"[recursive 8_8] {out}  ({N_WORDS} words)")

# ============================================================
# 3) streamline 8_4  (srcnn/srcnn_streamline)
#    W1: (8,1,9), W2: (4,8,9), W3: (1,4,9)
#    L1 layout (PU_L1.v): 20 words = 18 weight + 2 bias.
#      tap n × oc_half : addr = 2*n + half
#        half=0 → slots (LSB-first) 0..3 = W1[oc 0..3, 0, n]
#        half=1 → slots 0..3            = W1[oc 4..7, 0, n]
#      addr 18: slots 0..3 = B1[0..3]
#      addr 19: slots 0..3 = B1[4..7]
#    L2 layout (L2_PU.v, time-partitioned by oc, 4 pass): per-oc 19 words.
#      per-oc:
#        addr (oc*19 + 2n + half): half=0 slot 0..3 = W2[oc, ic 0..3, n]
#                                  half=1 slot 0..3 = W2[oc, ic 4..7, n]
#        addr (oc*19 + 18): bias word, slot 3 (MSB-side) = B2[oc]
#      → total 4 × 19 = 76 words.
# ============================================================
def pack_streamline_8_4():
    (W1, W2, W3), (B1, B2, B3) = load_layer("8_4", oc=(8,4,1), ic=(1,8,4))

    # ---- L1 ----
    L1_WORDS = 20
    words = [[0,0,0,0] for _ in range(L1_WORDS)]
    for n in range(9):
        for half in range(2):
            addr = 2*n + half
            for j in range(4):
                oc = half*4 + j
                words[addr][j] = W1[oc, 0, n]
    for j in range(4):
        words[18][j] = B1[j]
        words[19][j] = B1[4 + j]
    out1 = os.path.join(REPO_ROOT, "srcnn_streamline", "work", "weight_L1.txt")
    os.makedirs(os.path.dirname(out1), exist_ok=True)
    with open(out1, "w") as f:
        for w in words:
            f.write(pack64_lsb(w) + "\n")
    print(f"[streamline 8_4 L1] {out1}  ({L1_WORDS} words)")

    # ---- L2 (4 oc × 19 = 76) ----
    L2_WORDS = 4 * 19
    words = [[0,0,0,0] for _ in range(L2_WORDS)]
    for oc in range(4):
        for n in range(9):
            for half in range(2):
                addr = oc*19 + 2*n + half
                for j in range(4):
                    ic = half*4 + j
                    words[addr][j] = W2[oc, ic, n]
        # bias at addr (oc*19 + 18), slot 3 (LSB-first index 3 = bits[63:48])
        words[oc*19 + 18][3] = B2[oc]
    out2 = os.path.join(REPO_ROOT, "srcnn_streamline", "work", "weight_L2.txt")
    with open(out2, "w") as f:
        for w in words:
            f.write(pack64_lsb(w) + "\n")
    print(f"[streamline 8_4 L2] {out2}  ({L2_WORDS} words)")

    # ---- L3 (PR 후 추가됨) ----
    # L3_PU.v: 64-bit × 10 word, 1 word/tap (out_ch=1, no time-partition).
    #   addr n (n=0..8): slot ic(0..3) LSB-first = W3[0, ic, n]
    #     (i_weight_bram_data[16*ic +: 16])
    #   addr 9 (bias): slot 3 (MSB-side, bits[63:48]) = B3[0]
    L3_WORDS = 10
    words = [[0,0,0,0] for _ in range(L3_WORDS)]
    for n in range(9):
        for ic in range(4):
            words[n][ic] = W3[0, ic, n]
    words[9][3] = B3[0]
    out3 = os.path.join(REPO_ROOT, "srcnn_streamline", "work", "weight_L3.txt")
    with open(out3, "w") as f:
        for w in words:
            f.write(pack64_lsb(w) + "\n")
    print(f"[streamline 8_4 L3] {out3}  ({L3_WORDS} words)")

# ============================================================
# 4) unroll 4_2  (srcnn/rtl_pu_42_unroll)
#    W1: (4,1,9), W2: (2,4,9), W3: (1,2,9)
#    Layout (128-bit × 30 words, slot 0 = MSB) :
#      addr 0..8  : L1 weight tap n. slot 0..3 = oc 0..3, slot 4..7 = 0
#      addr 9     : L1 bias.         slot 0..3 = B1[0..3]
#      addr 10..18: L2 weight tap n. slot 0..3 = oc=0 ic 0..3,
#                                    slot 4..7 = oc=1 ic 0..3
#      addr 19    : L2 bias.         slot 0 = B2[0], slot 1 = B2[1]
#      addr 20..28: L3 weight tap n. slot 0..1 = ic 0..1, slot 2..7 = 0
#      addr 29    : L3 bias.         slot 0 = B3[0]
# ============================================================
def pack_unroll_4_2():
    (W1, W2, W3), (B1, B2, B3) = load_layer("4_2", oc=(4,2,1), ic=(1,4,2))
    N_WORDS = 30
    words = [[0]*8 for _ in range(N_WORDS)]
    # L1
    for n in range(9):
        for oc in range(4):
            words[n][oc] = W1[oc, 0, n]
    for oc in range(4):
        words[9][oc] = B1[oc]
    # L2 : slot 0..3 = oc=0 ic 0..3, slot 4..7 = oc=1 ic 0..3
    for n in range(9):
        for ic in range(4):
            words[10 + n][ic]     = W2[0, ic, n]   # oc=0
            words[10 + n][4 + ic] = W2[1, ic, n]   # oc=1
    words[19][0] = B2[0]
    words[19][1] = B2[1]
    # L3 : slot 0..1 = ic 0..1
    for n in range(9):
        for ic in range(2):
            words[20 + n][ic] = W3[0, ic, n]
    words[29][0] = B3[0]
    out = os.path.join(REPO_ROOT, "rtl_pu_42_unroll", "work", "weight.txt")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        for w in words:
            f.write(pack128_msb(w) + "\n")
    print(f"[unroll 4_2] {out}  ({N_WORDS} words)")

# ============================================================
# 5) unroll 8_8  (srcnn/rtl_pu_88_unroll)
#    레이아웃은 recursive 8_8 과 동일 (128-bit × 93 word). 파일 경로만 다름.
# ============================================================
def pack_unroll_8_8():
    (W1, W2, W3), (B1, B2, B3) = load_layer("8_8", oc=(8,8,1), ic=(1,8,8))
    N_WORDS = 93
    words = [[0]*8 for _ in range(N_WORDS)]
    for n in range(9):
        for oc in range(8):
            words[n][oc] = W1[oc, 0, n]
    for oc in range(8):
        words[9][oc] = B1[oc]
    for k in range(8):
        base = 10 + k*9
        for n in range(9):
            for ic in range(8):
                words[base + n][ic] = W2[k, ic, n]
    for s in range(8):
        words[82][s] = B2[s]
    for n in range(9):
        for ic in range(8):
            words[83 + n][ic] = W3[0, ic, n]
    words[92][0] = B3[0]
    out = os.path.join(REPO_ROOT, "rtl_pu_88_unroll", "work", "weight.txt")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        for w in words:
            f.write(pack128_msb(w) + "\n")
    print(f"[unroll 8_8] {out}  ({N_WORDS} words)")

if __name__ == "__main__":
    pack_recursive_4_2()
    pack_recursive_8_8()
    pack_streamline_8_4()
    pack_unroll_4_2()
    pack_unroll_8_8()
