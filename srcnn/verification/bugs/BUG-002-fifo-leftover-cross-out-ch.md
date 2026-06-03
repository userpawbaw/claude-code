# BUG-002: out_ch 경계에서 FIFO 잔류 4픽셀이 다음 라운드 데이터를 +4 시프트

---
id: BUG-002
project: SRCNN_4_2_1
found_in: [INV-002]
fixed_in: [8b45917]
tested_by: [REG-002, REG-003]
pattern: [PAT-06, PAT-04]
status: fixed
---

- **Discovered**: INV-002 (`L2 oc1 출력이 +4 시프트`)
- **Source file**: `srcnn/rtl/top_multilayer.v` (FIFO 인스턴스 섹션)
- **Fixed in**: commit `8b45917` (이번 세션 C2)
- **Regression**: `REG-002-l2-uram-vs-golden.md`
- **HANDOFF spec 누락**: §3.3 / §5 spec 에는 없던 신규 발견. PAT 환류 후보 (INV-002 끝 참조).

## 증상
`tb_L2`: ch0 (oc0) PASS, ch1 (oc1) 22481/22500 errors. got[5..N] = exp[1..N-4] 의 깨끗한 +4 시프트, got[0..4] 는 garbled (zero-padded early window 들의 conv).

## Root Cause
prefetch 정책 (HANDOFF §3.3(a)) 이 매 S_W_READ 첫 clk 마다 URAM addr 0 을 1회 읽고, S_I_STREAM 안에서 `read@en_cnt==0` + `addr = (r_bram>>2)+1` 로 word#1..word#5625 를 추가로 읽는다. 마지막 read 는 `r_bram_addr=22496` 에서 `addr = 5625` (URAM 유효 영역 [0..5624] 의 OOB). stub URAM init=0 이라 OOB read 가 0 4픽셀을 FIFO 에 넣고 oc0 종료.

`top_multilayer.v` 의 FIFO `srst` 가 `~i_rstn` 만 받아서 out_ch 경계 펄스를 못 받음 → oc1 시작 시 FIFO 에 leftover 4픽셀 잔존 → oc1 prefetch 가 그 위에 word#0 4픽셀을 쌓음 → 첫 4 pop = leftover 0 → line_buffer 입력이 +4 시프트로 인가 → conv 출력이 URAM 인덱스상 +4 시프트로 관측.

## Fix
FIFO `srst` 를 FSM 의 `o_dispatch_rst` 펄스로 게이팅:
```verilog
wire w_fifo_srst = ~i_rstn | w_dispatch_rst;
// gen_fifo_L1 / gen_fifo_L2 의 .srst() 에 모두 연결
```

`o_dispatch_rst` 는 FSM 이 S_DONE → IDLE 시 1clk 펄스로 발사 (weight_dispatch 와 같은 신호). 모든 out_ch / layer 경계에서 FIFO 가 비워져 다음 라운드의 prefetch 가 깨끗한 첫 4픽셀로 자리잡는다.

## 영향 범위
- L2 oc0: 영향 없음 (시작 시 FIFO 자체 reset 상태라 leftover 없음).
- L2 oc1: 22481 픽셀 시프트 → fix 후 0 errors.
- L3: 입력은 uram_L2 (2채널) 이고 uram_L2 는 oc 루프가 없어 단 1회 라운드. 다만 L2 → L3 layer 경계에서 fifo_L1 가 leftover 가질 수 있고, 같은 srst 가 layer 경계 펄스도 잡으므로 보호됨. tb_out 으로 검증 완료.

## 확인 명령
```bash
cd srcnn/work && \
iverilog -g2012 -o tb_L2.vvp \
  ../verification/tb_L2.v ../verification/stubs.v \
  ../rtl/*.v && vvp tb_L2.vvp | grep -E "check:|PASS|FAIL"
```
기대: `L2 check: 45000 checked, 0 errors`.

재현 (regression 깨질 때): ch0 PASS / ch1 만 +N 픽셀 깨끗한 시프트 → 본 버그 또는 prefetch 카운팅 변경 의심.

## 일반화 패턴 (Part 5 환류)
사이클 모델이 단일 라운드만 시뮬레이션한 경우, 라운드 경계의 stateful 모듈 (FIFO, packer 카운터, address counter) 의 잔류를 놓친다. 이런 종류의 버그는:

- 사이클 모델은 최소 2 라운드 (또는 out_ch / layer 경계 1회 이상 포함) 시뮬할 것.
- 라운드 경계마다 데이터패스 모듈의 reset 의도를 명시적으로 점검 (어느 모듈이 어느 신호로 리셋되는가 표).

→ PAT-XX (Cross-Boundary State Residue) 등록 후보.
