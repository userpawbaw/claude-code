# REG-001: tb_L1 — uram_L1[0..3] vs golden_L1

- **Tracks**: BUG-001 (FSM tail loss)
- **Test bench**: `srcnn/verification/tb_L1.v`
- **Mode**: conv-only (URELU=0, 기본) / ReLU (URELU=1) 양쪽 모두 통과해야 함.

## 검증 대상
L1 의 4 출력 채널이 URAM (`uram_L1[0..3]`) 에 정확히 22500 픽셀씩, golden_L1.txt 와 비트 단위 일치.

## 실행
```bash
cd srcnn/work
# golden 준비
python3 gen_golden.py        # conv-only
# python3 gen_golden.py relu # ReLU

# conv-only
iverilog -g2012 -o tb_L1.vvp \
  ../verification/tb_L1.v ../verification/stubs.v \
  ../rtl/top_multilayer.v ../rtl/line_buffer_improved.v ../rtl/pe_group.v \
  ../rtl/FSM_pad_line_buff_improved.v ../rtl/delay_shift.v \
  ../rtl/weight_dispatch.v ../rtl/uram_bank.v ../rtl/channel_accumulator.v \
  ../rtl/fifo_add_to_uram.v
vvp tb_L1.vvp | grep -E "check:|PASS|FAIL"

# ReLU
iverilog -g2012 -Ptb_L1.URELU=1 -o tb_L1_relu.vvp <동일 소스>
vvp tb_L1_relu.vvp | grep -E "check:|PASS|FAIL"
```

## 통과 기준
```
=== L1 check: 90000 checked, 0 errors ===
L1 PASS
```

## 깨질 때 의심 패턴
- 마지막 픽셀 영역 (pix 22492-22499) mismatch + got=0 → BUG-001 재발 (FSM 완료 트리거 회귀).
- 전 영역 일관된 시프트 → line_buffer / pe_group 타이밍 계약 위반 (HANDOFF §3.1, §3.2).
- 채널 한 개만 mismatch → weight_dispatch 슬롯 매핑 또는 pe_group 인덱싱 회귀.
