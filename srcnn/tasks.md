# tasks.md — SRCNN_4_2_1 top 병렬 통합

> **상태**: 단일 채널 경로(FSM_pad_line_buff_improved / line_buffer_improved / pe_group / 타이밍)는 확정·검증 완료. 본 tasks.md는 `top.v`의 **병렬 인스턴스화 + 레이어 통합 + end-to-end 검증**을 다룬다.
> **기준 파일**: 정적 윈도우 개선본(`FSM_pad_line_buff_improved.v`, `line_buffer_improved.v`, `pe_group.v`(i_line_done/o_pe_done 포함), `top_improved_applied.v`), 보조: `weight_dispatch.v`, `channel_accumulator.v`, `uram_bank.v`, `stubs.v`.
> **검증 기준 데이터**: `srcnn_ref.py` → `golden_L1.txt`(4ch) / `golden_L2.txt`(2ch) / `golden_out.txt`(1ch), `input.txt`, `weight.txt`(64bit 32word).
> **진행 규율**: 의존성 순서로 1태스크씩. 각 태스크 `done-when` 통과 전 다음 진행 금지. 회귀 먼저. 한 태스크 = 한 커밋. (Part 6 §5)

---

## 선행 확정 사항 (구현 전 Analyze 게이트에서 확인)

- [ ] **A-1** prefetch 정책 = **prefetch 1회**(S_W_READ 시작 시 uram 주소 0 read) + **read@uram_en_cnt==0** + **주소 (r_bram>>2)+1**. (FSM에 이미 반영됨 — 코드 확인)
- [ ] **A-2** top FIFO `wr_en` ← uram **`rd_valid`** 로 연결 (현재 `top_improved_applied.v`는 `w_intermid_uram_rd_en`에 연결 → 교체 필요). prefetch +2clk 모델의 전제.
- [ ] **A-3** pe_group 타이밍 계약: `o_valid`/`o_pe_done` 모두 `i_line_valid`/`i_line_done` 기준 **3단 지연**. channel_accumulator는 입력 valid 기준 **+1단**.
- [ ] **A-4** ReLU: 현재 **conv-only로 확정**(USE_RELU=False). 설계 의도가 ReLU면 본 tasks 전체 검증 기준을 USE_RELU=True로 재생성해야 함 → **결정 필요(PENDING)**. 미결 시 conv-only로 진행하고 DEC 기록.
- [ ] **A-5** weight BRAM: 현재 top은 단일 `w1_bram`(16bit). 신 레이아웃은 **64bit 32word + weight_dispatch** 경로. 통합 시 weight read 폭/주소 정합 확인.

---

## Phase A — 메모리 / 인터페이스 (선행, 서로 일부 병렬)

### T-01  URAM 6뱅크 인스턴스화
- **deps**: 없음
- **files**: `top.v` (메모리 섹션), `uram_bank.v`(라우팅, 기존)
- **do**: 단일 `u_uram_block`을 `uram_L1[0..3]`, `uram_L2[0..1]` 6뱅크로 확장. `uram_bank.v`의 we/re/addr 라우팅 출력에 결선.
- **done-when**: 6뱅크가 `uram_bank` 라우팅 신호(o_L1_we/re, o_L2_we/re, o_final_we)와 정확히 연결되고, layer_cnt별 타겟이 module_contract와 일치. 합성/elaborate 통과.
- **verify**: 포트 정합 + L1=4뱅크 동시 we, L2=out_ch_cnt 1뱅크 we, L3=final we 확인.

### T-02  FIFO 6인스턴스 + wr_en ← rd_valid  ⚠️(A-2)
- **deps**: T-01
- **files**: `top.v` (FIFO 섹션)
- **do**: `fifo_generator_0`을 6인스턴스(L1 4 + L2 2)로. **각 FIFO `wr_en`을 해당 URAM `rd_valid`(1clk 지연)에 연결** (현재 rd_en 직결을 교체). URAM 인스턴스의 비어있던 `.rd_valid()` 포트를 빼내 사용.
- **done-when**: prefetch +2clk 모델 전제(read→rd_valid→FIFO push)가 결선으로 성립. 6인스턴스 명명 충돌 없음.
- **verify**: 사이클 모델(이미 검증됨)과 동일 타이밍인지 파형/모델 대조. underflow=0.
- **PENDING 연계**: 7.2(FIFO IP 64→16, 6인스턴스 생성 가능 여부) 실 IP 확인.

### T-03 [P]  weight_dispatch 통합 (L1 경로부터)
- **deps**: 없음 (T-01·02와 병렬 가능)
- **files**: `top.v` (weight 섹션), `weight_dispatch.v`(기존)
- **do**: top의 임시 `weight_en` one-hot 생성 로직을 `weight_dispatch`로 이관. L1 weight를 dispatch 경유로 pe_group에 공급. weight BRAM을 64bit word 경로로(A-5).
- **done-when**: L1 weight가 dispatch를 통해도 기존 Layer1 결과와 **동일**(회귀).
- **verify**: golden_L1 ch0 첫 픽셀=41 등 회귀 확인. (Part 4 부록 C 손검산 기준)

---

## Phase B — 데이터패스 병렬화 (Phase A 후)

### T-04  line_buffer 4병렬 인스턴스
- **deps**: T-01, T-02
- **files**: `top.v` (line buffer 섹션)
- **do**: `line_buffer_improved`를 입력 채널 병렬용 4인스턴스로. L2는 4 in_ch 병렬, L3는 2 in_ch 병렬, L1은 1개 사용. 입력 소스 mux(layer_cnt 기준: L1=input BRAM, L2/L3=FIFO).
- **done-when**: 각 인스턴스가 독립 채널 윈도우를 정확히 출력. `i_IDLE_rst` 정합.
- **verify**: 단일 채널 회귀(T-03 통과분) 유지 + 4채널 윈도우 동시성 점검.
- **PENDING 연계**: 7.4(4채널 FIFO 동시 depth, under/overflow).

### T-05  pe_group 4병렬 + channel_accumulator(Σ)
- **deps**: T-04
- **files**: `top.v` (PE/누적 섹션), `channel_accumulator.v`(기존)
- **do**: `pe_group` 4인스턴스. 각 partial(21bit signed)을 `channel_accumulator`(MAX_CH=4)에 `i_partial[21*c +: 21]`로 묶어 입력, `i_active_ch`를 layer_cnt로(L2=4, L3=2). L1은 누적 우회(4 out_ch 독립).
- **done-when**: channel_accumulator 인터페이스가 contract(21bit×MAX_CH, +1단 valid, {sign,[14:0]} 정제)와 일치. L1 우회 경로 보존.
- **verify**: L2 한 픽셀 누적값을 golden_L2 손검산과 대조.

### T-06  uram_bank write/read 라우팅 결선
- **deps**: T-01, T-05
- **files**: `top.v`, `uram_bank.v`(기존)
- **do**: pack writer(`fifo_add_to_uram`) 출력을 uram_bank write 라우팅에. L1=4채널 동시 write(같은 주소, 독립 데이터), L2=uram_L2[out_ch_cnt], L3=final. read 라우팅: L2 입력=uram_L1 4동시, L3 입력=uram_L2 2동시.
- **done-when**: 라우팅이 contract와 일치, wr_pix_addr 리셋 타이밍 보존(레이어 경계 마지막 픽셀 안 덮임).
- **PENDING 연계**: 7.3(wr_pix_addr 리셋 타이밍).

---

## Phase C — 통합 / 레이어 루프 (Phase B 후)

### T-07  out_ch 루프 + 레이어 전환 mux
- **deps**: T-06
- **files**: `top.v`, `FSM_pad_line_buff_improved.v`(기존 LUT/루프)
- **do**: 출력 경로 mux(L1=병렬4 / L2·L3=누적1), URAM write 타겟 mux, URAM read 소스 mux를 layer_cnt/out_ch_cnt로 분기. FSM의 out_ch 루프(L2 2회) 정합.
- **done-when**: L1→L2(oc0,oc1)→L3 자동 진행. dispatch_rst/IDLE_rst/wr_addr_rst 경계 정합.

### T-08  L3 + 최종 출력 경로
- **deps**: T-07
- **files**: `top.v`
- **do**: L3(2→1) 누적 → 최종 출력 포트(o_output/o_output_valid). uram write 없음.
- **done-when**: L3 출력이 포트로 정상 방출, o_done 시퀀스 정합.

---

## Phase D — 검증 (단계별 golden 대조; 각 done-when의 종합)

### T-09  L1 4채널 → golden_L1
- **deps**: T-03, T-06
- **do**: i_start 후 L1 4 out_ch가 uram_L1[0..3]에 저장된 값을 `golden_L1.txt`(채널·행·열 순)와 비교.
- **done-when**: 4채널 전부 비트 일치.

### T-10  L2 → golden_L2
- **deps**: T-05, T-09
- **do**: L2 oc0 완료 후 uram_L2[0], 이어 oc1→uram_L2[1]. `golden_L2.txt` 대조.
- **done-when**: 2채널 일치. (여기서 prefetch/FIFO 타이밍이 실제로 맞는지 최종 확인 — A-1/A-2의 실증)

### T-11  L3 → golden_out + end-to-end
- **deps**: T-08, T-10
- **do**: L3 최종 출력을 `golden_out.txt`와 대조. 그 후 i_start 1회로 3레이어 자동 진행 end-to-end.
- **done-when**: 최종 출력 비트 일치 + end-to-end 통과.

---

## 검증 환경 노트

- HDL 시뮬레이터 가용 시: `stubs.v`로 PE/BRAM/URAM/FIFO/delay_shift/pack writer 대체해 iverilog 회귀. 실제 합성은 사용자 환경 IP.
- 시뮬레이터 부재 시: RTL 1:1 사이클 모델 + golden 대조 + 손검산(Part 4 §5 위계). 단 stub 전제(URAM read +1clk, FIFO 도착 +2clk)를 실제 IP와 대조 확인.

## 이 tasks 완료 후 남는 것 (Part 5 환류)
- ReLU 결정(A-4)이 conv-only가 아니었다면 golden 재생성 + T-05/T-08 재검증.
- 실 IP 사양(7.2) 확정 후 stub 전제 검증.
- 추출 패턴: PAT-01(Valid Timing), PAT-04(Pipeline Latency), PAT-05(FIFO Width) → knowledge/patterns 갱신.
