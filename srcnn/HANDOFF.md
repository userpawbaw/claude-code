# SRCNN_4_2_1 RTL — Claude Code 인수인계 통합 문서

> 작성 목적: 채팅 환경에서 진행된 SRCNN_4_2_1 멀티레이어 RTL 설계를 Claude Code 작업 환경으로 이관하기 위한 단일 진실 문서(single source of truth).
> 대상 디바이스: AMD/Xilinx KV260 (XCZU5EV)
> 네트워크 흐름: 1→4→2→1, 모든 3×3 conv, stride=1, padding=same(zero), conv-only(ReLU 미적용, 토글 예정)

---

## 0. 이 문서를 먼저 읽어야 하는 이유

진행 내역이 **여러 채팅 세션에 걸쳐 끊겼고**, 그 결과 **메모리(대화 기록)에는 확정·검증됐다고 기록된 수정이 실제 프로젝트 파일에는 반영되지 못한** 항목들이 존재한다. 이 문서는 그 간극을 명시적으로 표시한다.

세 가지 상태를 구분한다:
- **[FILE-OK]** — 프로젝트 파일에 정확히 반영됨
- **[MEM-ONLY]** — 메모리상 확정/검증됐으나 파일 미반영 (Claude Code에서 재적용 필요)
- **[SESSION-NEW]** — 직전 세션(이 문서 작성 세션)에서 새로 작성/검증됨, 프로젝트 미저장

---

## 1. 전체 아키텍처

```
L1 (1→4): input BRAM(16b) → line_buffer[0..3](입력 공유, weight만 out_ch별)
            → pe_group[0..3] (4 out_ch 동시) → 각 partial 16b 정제(+ReLU옵션)
            → pack_L1[0..3] → uram_L1[0..3]           (채널 누적 없음)

L2 (4→2): uram_L1[0..3] → fifo_L1[0..3] → line_buffer[0..3] (4 in_ch 병렬)
            → pe_group[0..3] → channel_accumulator(Σ4ch) → pack_main
            → uram_L2[out_ch_cnt]                       (out_ch 2회 순차)

L3 (2→1): uram_L2[0..1] → fifo_L2[0..1] → line_buffer[0..1] (2 in_ch 병렬)
            → pe_group[0..1] → channel_accumulator(Σ2ch) → pack_main
            → 최종 출력 포트
```

핵심 설계 결정:
- **메모리 뱅킹**: 풀 병렬 6뱅크 (uram_L1×4 + uram_L2×2). LUT가 아닌 URAM 블록이라 자원 부담 적음. 사용자 승인 완료.
- **weight BRAM**: 64bit width. `weight.txt`(32 word, 64bit hex)를 weight_dispatch가 받아 4묶음 9슬롯에 분배.
- **line_buffer**: 정적 LSB 윈도우 + SRL 시프트 구조. (동적 인덱싱 구버전 대비 LUT 약 1/20로 절감 — 단일 line_buffer 합성 시 LUT 10000 → 병렬화 불가 문제를 해결한 핵심 개선)

---

## 2. 모듈별 상태표

| 모듈 | 역할 | 상태 | 비고 |
|------|------|------|------|
| `line_buffer_improved.v` | 정적 윈도우 + o_img_done | **[MEM-ONLY]** | 프로젝트엔 구버전(MSB-in, img_done 없음). 검증본은 LSB-in 시프트 + o_img_done. |
| `pe_group.v` | PE×9 + adder tree | **[MEM-ONLY]** | 프로젝트엔 구버전. 검증본은 i_line_img_done/o_pe_done(delay 3) + PE 입력 비트 역순. |
| `FSM_pad_line_buff_improved.v` | 추론 시퀀스 FSM | **[MEM-ONLY]** | 프로젝트엔 prefetch 미적용(en_cnt==3). 검증본은 prefetch=1 + en_cnt==0 + 주소+1. |
| `weight_dispatch.v` | 64bit→슬롯 분배 | [FILE-OK] | 변경 없음. 사이클 모델 검증 완료. |
| `channel_accumulator.v` | 입력채널 Σ | [FILE-OK] | 변경 없음. L2에서 누적값 자체는 golden과 일치 확인됨. |
| `uram_bank.v` | URAM 라우팅 | [FILE-OK] | 조합 라우팅. 변경 없음. |
| `top_multilayer.v` | 멀티레이어 통합 top | **[SESSION-NEW]** | 직전 세션 작성. L1 통과, L2 정렬 미해결. prefetch/wr_en 미반영. |
| `PE.v` | 곱셈 PE | (외부) | DSP `instruction="A*B"` 단순곱(mreg 1clk). 정제 `{sign,[14:0]}`. |
| `delay_shift.v` | 지연 레지스터 | (외부) | WIDTH/DELAY 파라미터. |
| `fifo_add_to_uram.v` | 16b→64b pack | (외부) | 4픽셀 모아 fifo_cnt==3에 o_uram_we. MSB-first 조립. |
| stub(`stubs.v`) | 검증용 | [SESSION-NEW] | PE/BRAM/URAM/FIFO 모델. 합성 아님, iverilog 검증 전용. |

---

## 3. [MEM-ONLY] 미반영 수정 상세 — Claude Code에서 재적용 필요

### 3.1 line_buffer_improved.v (검증본 기준)

**(a) 시프트 방향 — LSB-in 으로 반전**
```verilog
// 검증본:
r_line0 <= {r_line0[LINE_SIZE-1 - DATA_BIT : 0], i_input_data};         // 새 데이터 LSB
r_line1 <= {r_line1[LINE_SIZE-1 - DATA_BIT : 0], r_line0[LINE_SIZE-1 -: DATA_BIT]};
r_line2 <= {r_line2[LINE_SIZE-1 - DATA_BIT : 0], r_line1[LINE_SIZE-1 -: DATA_BIT]};
```
(프로젝트 구버전은 `{i_input_data, r_line0[LINE_SIZE-1:DATA_BIT]}` = MSB-in — 윈도우 어긋남)

**(b) valid 2단 지연**
```verilog
r_valid      <= w_valid_in_window;   // (r_row>=2)&&(r_col>=2)
o_line_valid <= r_valid;             // 2단: 데이터 안착과 정렬
```

**(c) o_img_done 추가** (프레임 완료 신호)
```verilog
wire w_img_done = (r_row == IMG_WIDTH);
o_img_done <= w_img_done;
```

**(d) 윈도우 출력**: `{ r_line2[47:0], r_line1[47:0], r_line0[47:0] }` (LSB48 = 최근 3픽셀)

### 3.2 pe_group.v (검증본 기준)

**(a) PE 입력 비트 — MSB-first 역순**
```verilog
.i_input (i_line_data[DATA_BUS - 1 - 16*i -: 16]),   // DATA_BUS = 16*9
```
(line_buffer 윈도우 슬롯 순서를 PE에 정합시키는 핵심. 이 역순 + 위 (a) 시프트가 함께 맞아야 conv 정상)

**(b) i_line_img_done 입력 + o_pe_done 출력**
```verilog
input  wire i_line_img_done;
output wire o_pe_done;
...
delay_shift #(.DELAY(3)) d3_pe_en_to_add_valid (
    .clk(i_clk), .rst(~i_rstn), .en(1'b1),
    .din(i_line_img_done), .dout(o_pe_done) );
```
(PE 1단 + adder 2단 = 3clk. img_done을 3clk 지연시켜 마지막 partial이 adder tree를 나오는 시점에 done)

### 3.3 FSM_pad_line_buff_improved.v (검증본 + prefetch — 사이클 모델 검증 완료)

**확정 파라미터 (사이클 모델 결과): prefetch=1, read@en_cnt==0, 주소=(r_bram>>2)+1**
- 한 줄(150px): min_fifo=2
- 2D 전체(22500px): underflow=0, 완벽 정렬
- 줄 경계 padding 끼어도 안전, FIFO는 마지막 픽셀에서만 자연히 비움

**(a) S_W_READ에 prefetch 1회 추가** (L2/L3만, 첫 weight read와 동시)
```verilog
if (r_word_idx == 4'd0) begin
    o_wr_addr_rst <= 1'b1;
    if (layer_cnt != 2'd0) begin           // L2/L3만
        o_intermid_uram_rd_en   <= 1'b1;
        o_intermid_uram_rd_addr <= 0;       // 프레임 첫 word#0
        // uram_en_cnt 는 건드리지 않음 (S_I_STREAM 진입 시 0 유지)
    end
end
```

**(b) S_I_STREAM read 조건/주소 변경**
```verilog
// 변경 전: if(uram_en_cnt == 2'b11) ... addr = r_bram_addr[..:2];
// 변경 후:
o_intermid_uram_rd_addr <= r_bram_addr[MEM_ADDR_WIDTH-1:2] + 1'b1;   // word#1부터
if(uram_en_cnt == 2'b00) begin
    o_intermid_uram_rd_en <= 1'b1;
end
uram_en_cnt <= uram_en_cnt + 1'b1;
```

**(c) S_DONE 완료 판정**: `i_adder_done`(=pe_done) 으로 done. (구 `i_uram_we` 방식 폐기)
**(d) S_DONE에서 uram_en_cnt=0 리셋 확인** (S_I_STREAM 진입 시 0 보장)
**(e) 인스턴스 파라미터**: `O_NUM(150)` 사용 시 I_NUM=152 자동 계산

---

## 4. [SESSION-NEW] top_multilayer.v — 직전 세션 작성본

### 4.1 검증 통과 항목
- **L1 end-to-end: 90000 픽셀(4채널×22500) golden_L1과 비트 단위 0 오류 PASS** (iverilog)
- weight_dispatch L1 슬롯 순서가 기존 자체 카운터와 동치 (회귀 안전)
- weight.txt 역패킹(W1/W2/W3 복원) → conv-only golden 생성, L1 ch0 첫 픽셀=41 손계산 일치

### 4.2 통합 시 발견·해결한 버그
1. **L1 pack_main 오발생**: padding valid로 pe_group[1..3]도 동작 → channel_accumulator가 L1에서도 pack_main_we 발생. → `wr_pulse = (layer_cnt==0)? pack_L1_we[0] : pack_main_we` 로 layer 분기하여 FSM i_uram_we/uram_bank i_wr_en 통일.
2. **L1 4채널 입력 공유 누락**: L1은 입력 1채널을 4 pe_group이 공유(weight만 out_ch별)해야 함. line_buffer MUX를 `layer_cnt==0 → 4채널 모두 i_rd_dout`로 수정.
3. **마지막 출력 그룹 유실**: pe_done(img_done+3)이 S_DONE을 트리거하는 시점이 마지막 pack write보다 빨라 레이어 전환 후 라우팅이 바뀜. → top에서 `i_adder_done`에 delay_shift(2) 추가(`w_pe_done_dly`)하여 마지막 write를 현재 레이어 라우팅으로 보존.

### 4.3 미해결 — L2 정렬 (이 문서 작성 세션에서 막힌 지점)
- **증상**: L2 출력이 golden_L2 대비 약 4픽셀 선행 misalign. 채널 누적값 자체는 정확(ca_data가 golden과 일치). 즉 정렬만 문제.
- **근본 원인**: `top_multilayer.v`가 **prefetch 미적용** + FIFO `wr_en = ub_L1_re`(uram rd_en, 1clk 이른 데이터). 첫 64bit(4픽셀)를 FIFO에 채우기 전에 pop이 시작되어 4픽셀 0 선행.
- **확정 해결책(§3.3 + 아래 §5)**: prefetch=1 FSM + FIFO wr_en을 uram rd_valid로 연결. 이미 사이클 모델로 검증된 조합이나, top_multilayer.v에 아직 미반영.

---

## 5. top_multilayer.v 에 적용해야 할 미반영 사항

1. **FIFO wr_en을 uram rd_valid로 연결** (현재 `ub_L1_re[b]`/`ub_L2_re[b]` → 각 uram의 `rd_valid` 출력)
   - stub/실 URAM 모두 rd_en → +1clk rd_valid+dout. wr_en을 rd_valid로 하면 push 데이터가 같은 clk에 유효 (verification_notes 7.1 해결).
   - 현재 top은 uram 인스턴스의 `.rd_valid()`가 미연결(open)이므로 wire 추가 필요.
2. **§3.1~3.3 의 line_buffer/pe_group/FSM 검증본을 정식 반영** 후 재컴파일.
3. 반영 후 **L2 → L3 순차 검증** (tb_L2.v, 이어서 tb_out 작성).

---

## 6. 가중치 BRAM 레이아웃 (확정, 32 word, 64bit)

표기: `K{out_ch}-{in_ch}-{tap}` (1-based). 슬롯 맨 왼쪽 = MSB[63:48].

- **L1 (1→4) addr 0-8 (9 word)**: word_n = `[K1-1-n][K2-1-n][K3-1-n][K4-1-n]` (in_ch=1)
- **L2 (4→2) addr 9-26 (18 word)**: word당 4 in_ch. oc0=addr 9,11,..25 / oc1=10,12,..26 (stride2)
  - word = `[K{oc}-1-tap][K{oc}-2-tap][K{oc}-3-tap][K{oc}-4-tap]`
- **L3 (2→1) addr 27-31 (5 word)**: word당 2슬롯, 2묶음(in_ch)
  - word_k = `[ic1-(2k)][ic1-(2k+1)][ic2-(2k)][ic2-(2k+1)]`, 마지막 word는 tap8 + 0패딩

레이어별 FSM 파라미터:

| L | in | out(루프) | w_base | w_words | gap(sub_max) | oc_stride | word_stride |
|---|----|-----------|--------|---------|--------------|-----------|-------------|
| L1 | 1 | 4(동시) | 0 | 9 | 1 | 0 | 1 |
| L2 | 4 | 2(순차) | 9 | 9 | 1 | 1 | 2 |
| L3 | 2 | 1 | 27 | 5 | 2 | 0 | 1 |

weight 주소 = `w_base + out_ch*oc_stride + word_idx*word_stride`

---

## 7. 검증 인프라 (iverilog) — 이번 세션 신규

> verification_notes.md는 "시뮬레이터 부재로 Python 모델만"이라 기록돼 있으나, 이번 세션에서 **iverilog 설치 후 실제 RTL 시뮬레이션 가능**해짐.

- **stubs.v**: PE(DSP A*B, mreg 1clk, 정제 {sign,[14:0]}), BRAM/URAM(rd_en→+1clk rd_valid+dout), fifo_generator_0(64→16 MSB-first 4분할, Standard FIFO, Valid_Flag=false → top에서 delay_shift(1)로 valid 생성)
- **gen_golden.py**: weight.txt 역패킹 → W1/W2/W3 복원 → conv-only(또는 `relu` 인자로 ReLU) golden 생성. input.txt/golden_L1/L2/out.txt 출력.
- **tb_L1.v**: uram_L1[0..3] vs golden_L1 (PASS 확인됨)
- **tb_L2.v**: uram_L2[0..1] vs golden_L2 (현재 정렬 실패 — §5 적용 후 재검증 대상)

DSP 사양 확정 (dsp_macro_0.xci): `instruction1="A*B"` (단순 곱), areg/breg=false, **mreg=true(1clk)**, preg=false. → PE는 1clk 레이턴시 순수 곱셈기.
FIFO 사양 확정 (fifo_generator_0.xci): Input 64 / Output 16, Standard FIFO, **Valid_Flag=false**.

---

## 8. 남은 작업 (우선순위 순)

1. **[즉시] §3, §5 미반영 수정을 정식 파일에 반영** (line_buffer/pe_group/FSM 검증본 + top prefetch/wr_en)
2. **L2 정렬 재검증** (tb_L2.v, golden_L2 대조)
3. **L3 + 최종 출력 검증** (tb_out.v 작성, golden_out 대조)
4. **end-to-end** (i_start 1회 → 3레이어 자동 진행)
5. **ReLU 반영** — 현재 conv-only. 설계 프로파일이 ReLU 포함이면 channel_accumulator/L1 정제 출력 뒤 ReLU 단 추가(top에 `USE_RELU` 파라미터 골격 있음) + gen_golden.py `relu` 모드로 golden 재생성.

---

## 9. verification_notes.md PENDING 항목 현황

| 항목 | 현황 |
|------|------|
| 7.1 URAM read→FIFO write 1clk 타이밍 | **실제 문제로 확인됨**(L2 4픽셀 misalign). 해결책 §3.3+§5 확정, 적용 대기. |
| 7.2 fifo_generator_0 IP 사양 | xci 확인: 64→16, Standard, Valid_Flag=false (6 인스턴스 필요: L1×4+L2×2) |
| 7.3 wr_pix_addr 리셋 타이밍 | top에 `o_wr_addr_rst`(S_W_READ 첫 word) + wr_pulse 카운터 반영됨. 마지막 그룹 유실은 §4.2-3으로 해결. |
| 7.4 line_buffer/FIFO depth | prefetch=1 사이클 모델로 underflow=0 검증. depth 여유 확인 권장. |
| 7.5 ReLU 유무 | conv-only 확정 운용 중. 설계 의도 확인 후 §8-5 진행. |

---

## 10. 회귀 안전성 원칙

- L1(layer_cnt==0) 경로는 검증본 단일채널 동작과 동치 유지 (weight_dispatch 슬롯 순서 동치 확인됨).
- 검증본 line_buffer/pe_group은 사용자가 5×5 단일채널로 통과 확인한 것. 멀티레이어 확장 시 이 타이밍 계약(o_valid 3단, o_pe_done = img_done+3)을 보존할 것.
- L2/L3 신규 경로(채널 누적, FIFO prefetch, out_ch 루프)는 L1에 영향 없도록 layer_cnt mux 분기 유지.
