# BUG-001: FSM S_DONE 이 첫 wr_pulse 에서 즉시 exit → 마지막 pack write 손실

- **Discovered**: INV-001 (`L1 마지막 8 픽셀/채널이 0`)
- **Source file**: `srcnn/rtl/FSM_pad_line_buff_improved.v`
- **Fixed in**: commit `20e7845` (이번 세션 C1)
- **Regression**: `REG-001-l1-uram-vs-golden.md`

## 증상
`tb_L1` 90000/90000 검증에서 31 errors. 모든 미스매치가 각 채널 마지막 8 픽셀 부근 (`pix 22492-22499`), got = 0 (URAM 초기값), exp = 정상값.

## Root Cause
S_DONE 의 완료 트리거가 `i_uram_we` (= wr_pulse) 의 *첫* 발생이었다:
```verilog
end else begin
    if(i_uram_we) o_done <= 1'b1;   // 첫 wr_pulse 에서 exit
end
```
S_DONE 진입 후에도 pack writer 가 fifo_cnt 단위로 ~2개의 추가 wr_pulse 를 발사하는데, FSM 이 첫 펄스에 layer_cnt 를 올려 후속 write 가 `uram_bank` 라우팅 마스킹 (`ub_L1_we = 4'b0000`) 으로 사라진다.

타이밍:
- S_DONE 진입 시점 ≈ S_last + 1.
- 마지막 pack_L1_we ≈ S_last + 8.
- 첫 pack_L1_we (S_DONE 안) ≈ S_last + 4 → 이게 잡혀서 즉시 exit.
- S_last + 5 부터 layer_cnt = 1, ub_L1_we = 0 → S_last + 8 의 마지막 pack 은 마스킹.

## Fix
완료 트리거를 `i_adder_done` (= top 에서 `pe_done` 을 `delay_shift(2)` 로 추가 지연한 `w_pe_done_dly`) 으로 교체. 이 신호가 마지막 packer 출력보다 늦게 도착하도록 설계됨 (pe_done = img_done+3clk → +2clk = packer 의 마지막 we 보다 뒤).

```verilog
end else begin
    if(i_adder_done) begin
        o_done <= 1'b1;
    end
end
```

(이 fix 는 HANDOFF.md §3.3(c) 에 spec 되어 있었으나 ship 된 파일에는 미반영 — [MEM-ONLY] 였다.)

## 영향 범위
- L1: 마지막 8 픽셀 손실 (직접 관측). 4 채널 동시 write 라 채널당 손실 동등.
- L2: out_ch 경계 + 레이어 경계 모두 동일 메커니즘이 적용되므로 잠재적으로 마지막 픽셀 영역 손실 가능. 단 BUG-002 의 시프트가 더 큰 영향을 가려서 별도 관측 안 됨.
- L3: 동일 메커니즘. tb_out 에서도 같이 검증됨.

## 확인 명령
```bash
cd srcnn/work && \
iverilog -g2012 -o tb_L1.vvp \
  ../verification/tb_L1.v ../verification/stubs.v \
  ../rtl/*.v && vvp tb_L1.vvp | grep -E "check:|PASS|FAIL"
```
기대: `L1 check: 90000 checked, 0 errors` + `L1 PASS`.
