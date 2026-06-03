# REG-002: tb_L2 — uram_L2[0..1] vs golden_L2

- **Tracks**: BUG-002 (FIFO leftover cross out_ch).
- 또한 BUG-001 의 layer 경계 변종을 같이 커버 (L1→L2 전환).
- **Test bench**: `srcnn/verification/tb_L2.v`
- **Mode**: conv-only / ReLU 양쪽 통과 기준.

## 검증 대상
- L2 의 2 출력 채널 (`uram_L2[0]`=oc0, `uram_L2[1]`=oc1) 각 22500 픽셀, golden_L2.txt 와 비트 단위 일치.
- 부차적: L1 가 정상 종료해서 uram_L1[0..3] 에 올바르게 안착했음을 전제.

## 실행
```bash
cd srcnn/work
python3 gen_golden.py            # 또는 relu

iverilog -g2012 -o tb_L2.vvp \
  ../verification/tb_L2.v ../verification/stubs.v \
  ../rtl/top_multilayer.v ../rtl/line_buffer_improved.v ../rtl/pe_group.v \
  ../rtl/FSM_pad_line_buff_improved.v ../rtl/delay_shift.v \
  ../rtl/weight_dispatch.v ../rtl/uram_bank.v ../rtl/channel_accumulator.v \
  ../rtl/fifo_add_to_uram.v
vvp tb_L2.vvp | grep -E "check:|PASS|FAIL"

# ReLU
iverilog -g2012 -Ptb_L2.URELU=1 -o tb_L2_relu.vvp <동일 소스>
```

## 통과 기준
```
=== L2 check: 45000 checked, 0 errors ===
```

## 깨질 때 의심 패턴
- **ch0 PASS / ch1 만 깨끗한 +N 시프트 (N≈4)** → BUG-002 재발 (FIFO srst 가 dispatch_rst 펄스를 못 받음, 또는 prefetch 카운팅 변경으로 leftover 양 변동).
- ch0/ch1 모두 마지막 픽셀 영역에서 0 → BUG-001 변종 (L1→L2 전환 시 마지막 L1 pack 손실 → L2 입력 일부 누락).
- 전 영역 시프트 (양 채널) → channel_accumulator / pe_group 의 valid 타이밍 회귀.
