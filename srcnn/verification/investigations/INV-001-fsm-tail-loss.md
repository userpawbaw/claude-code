# INV-001: L1 마지막 8 픽셀/채널이 0 으로 손실

## Observe (Fact)

`tb_L1` 베이스라인 실행 결과 **31 errors / 90000 pixels, 모두 각 채널의 마지막 8 픽셀 부근에 집중**.

```
MISMATCH ch0 pix22493: got=0000 exp=fff1
MISMATCH ch0 pix22494: got=0000 exp=fffb
...
MISMATCH ch3 pix22499: got=0000 exp=...
=== L1 check: 90000 checked, 31 errors ===
L1 FAIL
```

22500 = 150×150 (= 채널당 픽셀 수). 마지막 픽셀들이 일관되게 `0` (URAM 초기값).
즉 **마지막 ~2개 pack write (8 픽셀) 가 URAM 에 안착하지 않았다.**

관련 코드(Fact):
- `srcnn/rtl/FSM_pad_line_buff_improved.v` S_DONE (구버전):
  ```verilog
  end else begin
      if(i_uram_we) o_done <= 1'b1;   // 첫 wr_pulse 에서 즉시 exit
  end
  ```
- `srcnn/rtl/top_multilayer.v` L141: `wr_pulse = (layer_cnt==0) ? pack_L1_we[0] : pack_main_we`
- 레이어 전환 시 `ub_L1_we = 4'b0000` 으로 라우팅 마스킹 (uram_bank.v).

## Hypothesis

- **H1**: FSM 이 마지막 wr_pulse 보다 일찍 S_DONE → layer_cnt 전환 → 잔여 pack write 가 라우팅에서 마스킹.
- **H2**: pack writer 자체가 마지막 픽셀 group 을 누락 (fifo_cnt 가 4 에 도달 못함).
- **H3**: line_buffer 가 마지막 행 일부를 윈도우로 못 만듦 (`r_row` 가 IMG_WIDTH 에 못 도달).

## Experiment Design

1. (H3 기각) line_buffer 코드에서 `r_row` 증가 조건과 `o_img_done = (r_row == IMG_WIDTH)` 트리거 시점을 트레이스. 23104 (152×152) 유효 입력 후 `r_row` 가 152 로 증가하는지 확인.
2. (H2 기각) `fifo_add_to_uram` 의 `i_fifo_en` 누적: 22500 valid 입력 → fifo_cnt 가 3 도달하는 횟수 = 5625 회 = 정확히 필요한 pack 수. 누락 없음.
3. (H1 검증) S_DONE 진입 시점 (= r_pad_row=151, r_pad_col=151 다음 clk) 과 마지막 pack_L1_we[0] 발생 시점 비교.

타이밍 사이클 모델:
- T_input_last (line_buffer 마지막 입력) ≈ S_last + 1 (FSM o_is_pad → o_is_pad_valid 1clk 지연).
- pe_group o_valid = i_line_valid + 3clk.
- l1_refined_valid = pe_valid + 1clk.
- pack_L1_we = (fifo_cnt==3 시) i_fifo_en 과 동일 clk (non-blocking 으로 다음 clk 가시화).
- 따라서 마지막 pack_L1_we ≈ T_input_last + 7 ≈ S_last + 8.
- 한편 S_DONE 진입 = S_last + 1. 그 후 `if(i_uram_we) o_done<=1` 은 첫 wr_pulse 만 보고 exit → 마지막 -1 ~ -2 pack 만 캐치.

## Evidence (Proven)

- 22500 = 5625 × 4 pack. 마지막 2 pack (pix 22492-22495, 22496-22499) 가 S_DONE 진입 *후* 발생 → layer_cnt 전환 다음 clk 에 `ub_L1_we = 4'b0000` 으로 라우팅 마스킹 → URAM 에 안 들어감.
- HANDOFF.md §3.3(c) 의 spec 그대로: "S_DONE 완료 판정은 `i_adder_done`(=pe_done, top 에서 +2clk 추가 지연) 으로. 구 `i_uram_we` 방식은 첫 pack we 에서 즉시 exit 해 tail pack 을 유실하므로 폐기."

## Narrowing

- H3 기각 (line_buffer 정상 종료).
- H2 기각 (packer 정상).
- **H1 확정**: FSM 의 `i_uram_we` 기반 S_DONE 완료 판정이 첫 wr_pulse 에서 exit.

## Root Cause

`FSM_pad_line_buff_improved.v` S_DONE 의 완료 트리거가 `i_uram_we` (= wr_pulse) 의 *첫* 발생. pe_group 의 출력은 `i_line_img_done + 3clk` 시점에서 마지막 partial 이 나오고, 그 뒤로도 pack writer 가 fifo_cnt 단위로 누적 write 를 발사한다. S_DONE 안에서 wr_pulse 가 여러 번 들어오는데 FSM 은 첫 펄스에 layer_cnt 를 올려버려 후속 write 라우팅이 끊김.

## Fix

`commit 20e7845`:
- S_DONE 완료 판정을 `i_adder_done` (top 에서 `pe_done` 을 `delay_shift(2)` 로 추가 지연한 `w_pe_done_dly`) 으로 교체.
- 이 신호는 마지막 pack write 가 끝난 뒤에 발사되도록 의도된 신호 (pe_done = img_done+3clk → 추가 +2clk → 마지막 packer 출력보다 늦게 도착).

동시에 HANDOFF §3.3(a)(b) 의 prefetch / `(r_bram>>2)+1` / `en_cnt==0` 변경도 같이 적용 (L2/L3 전제 조건).

## Regression

→ `REG-001-l1-uram-vs-golden.md` (tb_L1.v) 등록. 동일 증상 재발 시 ch0..3 의 pix 22492-22499 영역 mismatch 로 즉시 드러남.
