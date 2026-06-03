# INV-002: L2 oc1 에서 출력이 정확히 +4 픽셀 시프트

## Observe (Fact)

C1 (INV-001 fix) + C2 (HANDOFF §5 의 URAM `rd_valid` → FIFO `wr_en`) 적용 후 `tb_L2` 실행 결과:

```
=== L2 check: 45000 checked, 22481 errors ===
```

- ch0 (uram_L2[0], oc0): **PASS** 0 errors.
- ch1 (uram_L2[1], oc1): **22481 errors**, 깨끗한 +4 시프트.
- 검증: got[5..19] = exp[1..15] 비트 단위 정확 일치. got[0..4] 는 garbled.

```
MISMATCH ch1 pix0: got=ffce exp=00a3
MISMATCH ch1 pix1: got=00a9 exp=006b
...
MISMATCH ch1 pix5: got=006b exp=0060    ← got[5] = exp[1]
MISMATCH ch1 pix6: got=ff4b exp=ff92    ← got[6] = exp[2]
MISMATCH ch1 pix7: got=00b7 exp=01fe    ← got[7] = exp[3]
...
MISMATCH ch1 pix19: got=feb4 exp=...    ← got[19] = exp[15]
```

관련 코드(Fact):
- `top_multilayer.v` FIFO `srst` 는 `~i_rstn` 만 연결되어 있다 (전역 reset 외엔 안 풀림).
- FSM S_DONE → IDLE 전환 시 `o_dispatch_rst`, `o_IDLE_rst` 가 1clk 펄스로 발사된다 (weight_dispatch, line_buffer 는 받지만 FIFO 는 안 받는다).
- HANDOFF §3.3(a) 의 prefetch 는 매 S_W_READ 진입 시 URAM addr 0 read 1회 발행.

## Hypothesis

- **H1**: oc0 종료 시 FIFO 에 leftover 픽셀이 남는다 (URAM 마지막 read 가 OOB 라 0 이 4픽셀 들어옴). 이게 oc1 시작 전에 안 비워져서, oc1 prefetch 의 word#0 가 그 뒤에 줄을 서고, 첫 4 FIFO pop 이 leftover 0 들 → line_buffer 에 +4 시프트로 데이터 인가.
- **H2**: pack_main 내부 `fifo_64` 잔류가 영향 (oc0 의 마지막 word 가 oc1 의 첫 word 에 섞임).
- **H3**: channel_accumulator 또는 line_buffer 가 oc 전환 시 상태 잔류.

## Experiment Design

1. (H2 검증) `fifo_add_to_uram` 의 시프트 동작 분석: `fifo_64 <= {fifo_64[47:0], i_data}` 는 fifo_cnt==3 의 출력이 항상 *최근 4개 입력* 만으로 구성됨. oc0 종료 시 fifo_cnt=0 (정확히 22500/4=5625 pack) → 잔류 fifo_64 가 다음 oc0 출력에 안 섞임. → **H2 기각**.
2. (H3 검증) line_buffer 는 `i_IDLE_rst` 로 r_line0/1/2 와 r_row/r_col 모두 리셋. channel_accumulator 는 비등록 합 + 1단 register 뿐 (상태 없음). → **H3 기각**.
3. (H1 검증) URAM read 수 카운트:
   - prefetch 1회 + S_I_STREAM 5625회 = 5626 read × 4 픽셀 = 22504 픽셀 FIFO 에 write.
   - S_I_STREAM 동안 fifo_rd_en 펄스 = 비-padding clk = 22500.
   - oc0 종료 시 FIFO 잔량 = 22504 - 22500 = **4 픽셀**.
   - 마지막 read 는 `r_bram_addr=22496` 에서 발생, `addr = (22496>>2) + 1 = 5625` (URAM 유효 영역 [0..5624] 의 OOB). stub URAM 초기값 0 → **leftover 4픽셀 모두 0**.
4. oc1 시작:
   - FIFO 에 0 4개 잔류. prefetch 가 oc1 의 S_W_READ 첫 clk 에 URAM addr 0 read 발행 → word#0 (4 pix) 가 위에 푸시 → FIFO 8 pix.
   - S_I_STREAM 첫 4 pop = leftover 0 → line_buffer ch0..3 에 0 이 +4 시프트로 인가.
   - 결과: image 데이터가 line_buffer 좌표상 +4 컬럼 (행 경계 wrap 포함) 으로 밀림 → conv 출력이 URAM 인덱스상 +4 시프트로 관측.

## Evidence (Proven)

- 사이클 모델에서 leftover = 4 (산술 일치).
- `tb_L2` 에서 ch0 (= 처음 oc0, 빈 FIFO 출발) PASS, ch1 (= leftover 4 위 prefetch) 만 FAIL 이라는 비대칭이 정확히 H1 예측과 일치.
- 시프트 양 = leftover 양 = 4.
- got[0..4] (5 픽셀) 은 garbled 값 (early window 들이 zero-pad + leftover-zero + 일부 shifted img 데이터로 conv) — 깨끗한 +4 시프트가 아니라 "처음 5개는 쓰레기, 그 뒤로 정확히 exp[k-4]" 형태로 관측되는 것도 본 가설로 설명됨.

## Narrowing

H2 / H3 기각. **H1 확정**.

## Root Cause

`top_multilayer.v` 의 FIFO `srst` 가 `~i_rstn` 만 받아서 out_ch (또는 layer) 경계에서 FIFO 가 비워지지 않는다. FSM 의 prefetch 정책은 매 S_W_READ 첫 clk 마다 URAM addr 0 을 한 번 더 읽도록 설계됐는데, 그 prefetch 가 이전 라운드의 FIFO 잔류물 위에 덮인다.

OOB URAM read 가 leftover 0 을 생성하는 메커니즘 자체는 다른 안 (예: 마지막 4개 안 읽기) 으로도 막을 수 있지만, "라운드 경계마다 데이터패스 reset" 이라는 의미적 정합이 더 강함.

## Fix

`commit 8b45917`:
```verilog
wire w_fifo_srst = ~i_rstn | w_dispatch_rst;
// ... 6개 fifo_generator_0 인스턴스의 .srst() 에 연결
```

`w_dispatch_rst` 는 FSM 이 S_DONE → IDLE 시 1clk 펄스로 발사 (weight_dispatch 와 같은 신호). 모든 out_ch / layer 경계에서 FIFO 가 비워져 다음 라운드의 prefetch 가 깨끗한 첫 4 픽셀로 자리잡는다.

## Regression

→ `REG-002-l2-uram-vs-golden.md` (tb_L2.v) 등록. 동일 증상 재발 시 ch1 만 깨끗한 +N 시프트 패턴으로 즉시 드러남 (N = OOB read 4픽셀, 또는 prefetch 정책 변경 시 다른 양).

## Knowledge Graph 환류 (Part 5 후보)

HANDOFF.md §3.3 / §5 spec 은 prefetch + rd_valid 만 명시했고, *out_ch 경계에서 FIFO srst* 가 빠져 있었다. 이 누락이 **사이클 모델이 단일 oc 만 시뮬레이션해서 OOB read leftover 가 다음 oc 에 미치는 영향을 못 본** 결과. PAT 후보:

- **PAT-XX (Cross-Boundary State Residue)**: 사이클 모델이 단일 라운드만 본 경우, 라운드 경계의 stateful 모듈 (FIFO, packer 카운터, address counter) 의 잔류를 놓침. → 사이클 모델은 적어도 2 라운드 시뮬해야 한다.
