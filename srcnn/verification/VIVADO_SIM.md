# Vivado XSim 시뮬레이션 가이드

`tb_all_vivado.v` 한 개로 L1 + L2 + L3 + end-to-end 를 한 번에 검증한다. URAM 내부 메모리 peek 없이 top 의 packer 신호를 계층 참조로 캡처하므로, stub URAM 이든 실제 Xilinx URAM IP 이든 동일하게 동작한다.

---

## 1. 사전 준비

### 1.1 골든 데이터 생성

호스트에서 (Python 3 + numpy 필요):

```bash
cd srcnn/work          # 또는 임의 디렉토리
cp ../data/weight.txt .
cp ../verification/gen_golden.py .

# conv-only 모드 (USE_RELU=0 기본)
python3 gen_golden.py

# 또는 ReLU 모드
python3 gen_golden.py relu
```

생성물:
- `input.txt` — 150×150 입력 (16bit hex/line)
- `weight.txt` — 32 word 64bit (이미 있던 그 파일을 사용)
- `golden_L1.txt` — 4ch × 22500 픽셀
- `golden_L2.txt` — 2ch × 22500 픽셀
- `golden_out.txt` — 1ch × 22500 픽셀

### 1.2 Vivado 시뮬레이션 워킹 디렉토리

`$readmemh("golden_L1.txt", ...)` 는 **시뮬레이션 런타임 워킹 디렉토리** 에서 파일을 찾는다. Vivado XSim 의 기본 워킹 디렉토리는:

```
<project>.sim/sim_1/behav/xsim/
```

위 디렉토리에 `input.txt` / `weight.txt` / `golden_L1.txt` / `golden_L2.txt` / `golden_out.txt` 다섯 파일을 복사한다.

대안: 절대 경로로 박기. `tb_all_vivado.v` 의 `$readmemh` 인자에 `"/full/path/golden_L1.txt"` 같이 절대경로 사용 — 단 prj 이동 시 깨짐.

### 1.3 입력 BRAM 초기화 파일

`top_multilayer.v` 의 `i_bram` 인스턴스는 `INIT_FILE("input.txt")` 로 초기화된다.

- 본 stub (`stubs.v`) 의 `simple_dual_port_bram` 은 `$readmemh(INIT_FILE, mem)` 으로 초기화.
- 실 Xilinx BRAM IP 를 쓸 경우, 동일 데이터를 .coe 또는 .mem 형식으로 IP 에 박아두거나, 시뮬용 backdoor 초기화 코드를 추가.

`weight.txt` 도 동일하게 `w_bram` 의 `INIT_FILE` 로 들어간다.

---

## 2. Vivado 시뮬레이션 셋업

### 2.1 Source 추가

**Design Sources (합성 가능):**
```
srcnn/rtl/top_multilayer.v
srcnn/rtl/line_buffer_improved.v
srcnn/rtl/pe_group.v
srcnn/rtl/FSM_pad_line_buff_improved.v
srcnn/rtl/delay_shift.v
srcnn/rtl/weight_dispatch.v
srcnn/rtl/uram_bank.v
srcnn/rtl/channel_accumulator.v
srcnn/rtl/fifo_add_to_uram.v
srcnn/rtl/PE.v                 # 사용자 환경의 실 PE
```

**Simulation Sources (시뮬레이션 전용):**
```
srcnn/verification/tb_all_vivado.v
srcnn/verification/stubs.v     # 사용자 환경에 실 IP 가 없을 때만. PE/BRAM/URAM/FIFO 의 거동 모델.
```

> **stubs.v 포함 여부**:
> - **실 Xilinx IP (BRAM, URAM, FIFO) 를 시뮬셋에 추가했다면**: `stubs.v` 중 `simple_dual_port_bram`, `simple_dual_port_uram`, `fifo_generator_0` 정의가 충돌하니 빼거나 `ifndef` 가드 추가.
> - **실 IP 없이 거동만 보고 싶다면**: `stubs.v` 그대로 포함. PE 도 stub 의 1clk DSP 모델 사용. (단 합성 결과는 stub 과 다를 수 있음 — 합성은 항상 실 PE 로.)

### 2.2 Top 모듈 지정

Simulation Sources 의 top 을 `tb_all_vivado` 로 설정 (`Set as Top`).

### 2.3 시뮬레이션 시간

`tb_all_vivado.v` 가 자체적으로 `$finish` 를 호출하므로 Vivado 의 runtime 은 충분히 크게 (예: `1500 ms` 또는 무제한). Settings → Simulation → xsim.simulate.runtime = `-all` 또는 `1500000us`.

### 2.4 ReLU 모드 검증

기본 `URELU = 0` (conv-only).

ReLU 모드는 두 가지 방법 중 택일:

**(a) Vivado generic 오버라이드 (권장)**

Simulation Settings → xsim.elaborate.xelab.more_options 에:
```
-generic_top URELU=1
```

추가로 `python3 gen_golden.py relu` 로 골든 재생성 후 같은 sim dir 로 복사.

**(b) tb_all_vivado.v 의 `parameter URELU = 0` 을 `1` 로 직접 수정**

빠르지만 git 상에서 보이는 변경이 생기니 (a) 가 깨끗함.

---

## 3. 실행 & 기대 결과

`Run Simulation` → `Run Behavioral Simulation`.

Tcl Console 출력 끝부분에 다음이 나오면 통과:

```
=== L1  : 0 / 90000 errors  (captured 22500/22500)
=== L2  : 0 / 45000 errors  (captured oc0=22500 oc1=22500 / 22500)
=== OUT : 0 / 22500 errors  (captured 22500/22500)
ALL PASS
```

총 시뮬 시간 약 927ms (= clk period 10ns × 약 9270만 cycle, L1+L2+L3 한 번).

---

## 4. 깨질 때 의심 패턴 (Part 4 §7 좁히기)

`tb_all_vivado.v` 가 한 번에 3 레이어를 검증하므로 에러 양상으로 곧장 어디부터 깨졌는지 알 수 있다:

| 증상 | 의심 |
|---|---|
| **L1 errors > 0** AND **L2/OUT 도 깨짐** | L1 layer 의 RTL 회귀 (line_buffer 시프트 방향, pe_group MSB-first, weight_dispatch 슬롯 매핑, FSM 종료 트리거). REG-001 우선 점검. |
| L1 PASS, **L2 oc0 PASS / oc1 만 깨끗한 +N 시프트** | BUG-002 재발 (FIFO srst 가 `o_dispatch_rst` 펄스 못 받음, 또는 prefetch 정책 변경으로 leftover 양 변동). REG-002 + INV-002 참조. |
| L1 마지막 영역 (pix 22492-22499) 만 0 / 누락 | BUG-001 재발 (FSM 완료 트리거가 `i_uram_we` 로 돌아갔거나 `i_adder_done` delay 가 줄어듦). REG-001 + INV-001 참조. |
| captured 값이 22500 미만 | layer 가 정상 종료 못함. line_buffer `o_img_done` 또는 pe_group `o_pe_done` 타이밍 회귀. timeout 메시지의 `layer=` 로 어디서 막혔는지 확인. |
| 전 영역 일관된 비-시프트 mismatch (값만 다름) | 가중치 데이터 경로 (weight_dispatch / weight BRAM 초기화) 회귀. golden vs RTL 의 weight.txt 일치 재확인. |
| URAM `mem` 못 peek (XSim 에러) | (해당 없음 — 본 tb 는 peek 안 함. 만약 기존 tb_L1.v/tb_L2.v 를 Vivado 에 넣었다면 그 tb 는 stub URAM 전제라 실 IP 환경에서 못 씀.) |

---

## 5. iverilog 회귀 (참고)

Vivado 결과와 호스트 iverilog 결과를 교차 검증 가능. 호스트에서:

```bash
cd srcnn/work
python3 gen_golden.py            # 또는 relu

iverilog -g2012 -o tb_all.vvp \
  ../verification/tb_all_vivado.v ../verification/stubs.v \
  ../rtl/top_multilayer.v ../rtl/line_buffer_improved.v ../rtl/pe_group.v \
  ../rtl/FSM_pad_line_buff_improved.v ../rtl/delay_shift.v \
  ../rtl/weight_dispatch.v ../rtl/uram_bank.v ../rtl/channel_accumulator.v \
  ../rtl/fifo_add_to_uram.v
vvp tb_all.vvp | tail -10

# ReLU
iverilog -g2012 -Ptb_all_vivado.URELU=1 -o tb_all_relu.vvp <위와 동일 소스>
vvp tb_all_relu.vvp | tail -10
```

본 세션에서 양쪽 모드 모두 `ALL PASS` 확인 완료.
