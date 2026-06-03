# REG-003: tb_out — L3 최종 출력 스트림 vs golden_out (end-to-end)

---
id: REG-003
project: SRCNN_4_2_1
covers: [BUG-001, BUG-002]
file: srcnn/verification/tb_out.v
modes: [conv-only, ReLU]
status: passing
---

- **Tracks**: BUG-001 / BUG-002 의 L2→L3 layer 경계 변종 + L3 전구간.
- 또한 **i_start 1펄스 → L1→L2→L3 자동 진행** 의 end-to-end 정합.
- **Test bench**: `srcnn/verification/tb_out.v`
- **Mode**: conv-only / ReLU 양쪽 통과 기준.

## 검증 대상
L3 결과는 URAM 에 저장되지 않고 `o_output` (64b, 4 픽셀 MSB-first 패킹) / `o_output_valid` (= `ub_final_we`, layer_cnt==2 에서만 활성) 로 스트림 출력. tb 가 매 valid 펄스마다 4픽셀씩 캡처해 22500 픽셀 골든과 대조.

부차적으로:
- L1 → L2 → L3 자동 전환 (한 번의 `i_start` 후 layer_cnt 가 0→1→2→3 까지 진행).
- 모든 레이어 경계에서 데이터 손실 / 시프트 없이 통과.

## 실행
```bash
cd srcnn/work
python3 gen_golden.py            # 또는 relu

iverilog -g2012 -o tb_out.vvp \
  ../verification/tb_out.v ../verification/stubs.v \
  ../rtl/top_multilayer.v ../rtl/line_buffer_improved.v ../rtl/pe_group.v \
  ../rtl/FSM_pad_line_buff_improved.v ../rtl/delay_shift.v \
  ../rtl/weight_dispatch.v ../rtl/uram_bank.v ../rtl/channel_accumulator.v \
  ../rtl/fifo_add_to_uram.v
vvp tb_out.vvp | grep -E "check:|PASS|FAIL|captured"

# ReLU
iverilog -g2012 -Ptb_out.URELU=1 -o tb_out_relu.vvp <동일 소스>
```

## 통과 기준
```
=== OUT check: 22500 checked, 0 errors, captured=22500 ===
OUT PASS
```

## 깨질 때 의심 패턴
- captured ≠ 22500 → L3 가 정상 종료 못함 (FSM `i_adder_done` 게이팅 / layer_cnt 전환 회귀).
- 마지막 픽셀 영역 0 / 누락 → BUG-001 의 L3 변종 (final-we 라우팅 마스킹).
- 첫 픽셀 영역 garbled 후 시프트 → BUG-002 의 L2→L3 layer 경계 변종 (fifo_L2 leftover, 본 fix 로 보호되어야 함).
- 시뮬레이션이 타임아웃 (`TIMEOUT layer=...`) → FSM done 조건이 fire 못함, line_buffer 의 `o_img_done` / pe_group 의 `o_pe_done` 타이밍 회귀.
