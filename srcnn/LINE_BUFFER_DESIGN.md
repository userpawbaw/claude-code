# Line Buffer & Border Padding Convention (SRCNN RTL)

> 작성: 2026-06-08
> 적용: rtl_pu_88_unroll, rtl_pu_42_unroll, 그리고 후속 변종 전반.

이 문서는 SRCNN RTL 구현에서 **모든 layer 입출력이 152×152 zero-padded 이미지** 라는
대원칙과, 이를 위해 L1/L2 vs L3 가 **서로 다른 line buffer 슬라이스 전략** 을 쓰는
이유를 정리한다. 새 변종을 짤 때 참고용.

---

## 1. 대원칙 : 모든 layer = 152×152

- 입력 BRAM, URAM_L1, URAM_L2, (recursive 시) URAM_OUT 모두 **152×152 zero-border** 형태로 저장.
  - row 0 / row 151 : 0
  - col 0 / col 151 : 0
  - 가운데 150×150 = 실제 conv 결과
- word 폭 = 8 px × 16 bit = 128 bit. row 당 152 / 8 = **19 word**.
- image 당 152 × 19 = **2,888 word/ch**.

이 형식을 유지하기 때문에 L1 출력 → L2 입력 → L2 출력 → L3 입력 으로 그대로 흘려보낼 수 있고,
**recursive 적용** 시 L3 출력 → L1 입력으로 되먹임이 가능.

---

## 2. L1 / L2 line buffer : forward-shifted window + PE masking

### 슬라이스 위치
- `line_buffer_wide.v` 의 `WIN_OFFSET = (SHIFT_STEP-1)*DATA_BIT = 112` (8-way 기준).
- 슬라이스 bit range : `[(WIN_COL+SHIFT_STEP-1)*DATA_BIT - 1 : (SHIFT_STEP-1)*DATA_BIT]`
  = `[271:112]` = 10 px × 16 bit = 160 bit per row, ×3 row = 480 bit.
- LSB 쪽 (= 가장 최근 shift in 된 px)을 슬라이스 시작점에서 **1 px 뒤로** 밀어둠.

### Emit 스케줄
- `word_cnt = K` 의 입력이 끝나면, 슬라이스는 cols `((K-1)*8 - 1) .. (K*8)` 를 본다.
- output row r 의 emit 분포 :
  - `word_cnt = 1..18` of input row `r+1` → output cols 0..143.
  - `word_cnt = 0` of input row `r+2` → output cols 144..151.
- ⇒ output row 150 을 끝내려면 **"input row 152" 의 word_cnt=0** 1 word 가 추가로 필요.
  FSM 이 stream 끝에 dummy 1-word 를 1 clk 더 흘려보냄.

### Border 처리 = PE 입력 masking
- `word_cnt = 1` emit (row 시작) 시 슬라이스 [9] (가장 왼쪽 col) 에는 이전 row 의 마지막 col 데이터가 남아있음 → 라이브러리 내부에서 **강제 0** 처리.
- `word_cnt = 0` emit (row 끝) 시 슬라이스 [0] (가장 오른쪽 col) 는 *다음 row 의 col 0* 인데,
  사전 패딩 때문에 자동 0. 추가 mask 불필요.
- ⇒ PE lane 0 의 왼쪽 col 입력 / lane 7 의 오른쪽 col 입력이 자연스럽게 0 → conv 결과도 0 → **zero-border 자동 생성**.

### 결과
- 각 emit 은 **lane 8 개 모두 유효** (lane_valid = `8'b11111111`). border 위치도 "유효" 값이지만 그 값이 0 인 셈.
- packer 가 필요 없음. 128-bit pixel data 를 그대로 URAM 에 write.
- 출력 URAM 은 152×152 zero-border 형태가 자동으로 채워짐.

---

## 3. L3 line buffer : LSB-aligned + lane_valid mask

### 슬라이스 위치
- `line_buffer_wide_l3.v` 의 `WIN_OFFSET = DATA_BIT = 16` (4-way 기준).
- 슬라이스 bit range : `[WIN_COL*DATA_BIT + DATA_BIT - 1 : DATA_BIT]`
  = `[111:16]` = 6 px × 16 bit = 96 bit per row, ×3 row = 288 bit.
- 가장 최근 shift in 된 px 가 슬라이스 LSB 근처.

### Emit 스케줄
- `word_cnt = K` 의 출력 lane k = col `4K - 2 + k`.
  - K=0: lane 0,1 = col -2, -1 (이미지 바깥, 의미 없음) → `o_lane_valid = 4'b1100`.
  - K=1..37: 모든 lane valid → `o_lane_valid = 4'b1111`.
- row 당 emit = 38 (K=0..37). 총 valid px = 2 + 37×4 = 150.

### Border 처리 = lane_valid mask
- PE 입력은 mask 하지 않음. K=0 의 lane 0,1 은 stale 데이터로 conv 결과를 그대로 계산.
  이 값은 **무의미** 하지만 `o_lane_valid` 가 0 으로 표시 → downstream 이 무시.
- 따라서 **출력은 150 px / row** (border 미포함). 152×152 grid 의 col 0/151 자리는 비어있음.

### Packer 가 필요한 이유
- L3 출력을 다음 layer 또는 외부로 보낼 때 word 정렬이 필요.
- 4-way 변종 : K=0 emit 2 px + K=1..37 emit 4 px씩 들어옴 → 4-px word 로 재정렬.
  - row 경계는 짝수/홀수 row alternation 으로 자연 정렬 (150 row 짝수 → 깔끔 종료).
- 8-way 변종 : K=0 emit 6 px + K=1..18 emit 8 px씩 들어옴 → 8-px word 로 재정렬.
  - row 경계 자연 정렬 안 됨 (cnt 가 0→6→4→2→0 사이클).
  - image 경계도 자연 정렬 안 됨 (22500 px / 8 = 2812.5 → 마지막 word 4 px 만 valid).
  - **`i_flush`** 신호로 image 끝에서 save 남은 px 를 emit. 이때 valid count 도 같이 전달.

### Recursive 적용 시 주의
- L3 출력을 URAM_OUT 에 저장한 뒤 L1 입력으로 되먹이려면 **152×152 zero-border 형태로 재배치** 필요.
- 방법 A : packer 가 row 경계마다 col 0/151 위치에 0 을 끼워넣는다 (복잡).
- 방법 B : L3 도 L1/L2 처럼 forward-shifted window + PE masking 방식으로 바꿔 152×152 직접 생성. lane_valid mask 불필요, packer 불필요. **Recursive 가 목적이라면 이 방식이 깔끔.**
- 방법 C (현재 8-way 변종) : 150×150 stream 으로 저장하고, 다음 iteration 의 L1 입력 단계에서 zero-border 를 첨가. URAM_OUT 은 단순 dense 저장, 재사용 시 padding 한번만 처리.

---

## 4. 정리

| 항목 | L1/L2 (line_buffer_wide) | L3 4-way (line_buffer_wide_l3) | L3 8-way (예정) |
|---|---|---|---|
| WIN_COL | 10 | 6 | 10 |
| SHIFT_STEP | 8 | 4 | 8 |
| Slice 위치 | forward-shifted ([271:112]) | LSB-aligned ([111:16]) | LSB-aligned ([175:16]) |
| Border 처리 | PE 입력 mask 0 | lane_valid mask | lane_valid mask |
| 출력 픽셀 | 152 × 152 (zero-border 포함) | 150 × 150 (border 미포함) | 150 × 150 (border 미포함) |
| lane_valid 패턴 | 항상 `8'b11111111` | K=0 → `4'b1100`, else `4'b1111` | K=0 → `8'b11111100`, else `8'b11111111` |
| Packer 필요 | 불필요 | 4-way packer | 8-way packer (+ flush) |
| Row 경계 정렬 | 자연 정렬 | 자연 정렬 (alternate) | 미정렬 (cnt cycle 4 row) |
| Image 경계 정렬 | 자연 정렬 | 자연 정렬 | 미정렬 (마지막 4 px) |

---

## 5. 새 변종 짤 때 체크리스트

1. **출력이 다음 layer/iter 의 입력으로 직결되는가?**
   - Yes → L1/L2 방식 (forward-shifted + PE mask) 권장. packer/mask 모두 불필요.
   - No (final output) → L3 방식 (LSB-aligned + lane_valid) + packer 도 OK.

2. **unroll factor K 가 152 의 약수인가?**
   - Yes (K ∈ {1,2,4,8,19,38,76,152}) → 152 / K 가 정수 → row boundary 깔끔.
   - No → 메모리 폭 / line buffer / FSM 카운터 모두 재설계 필요.

3. **L3 packer 가 필요한 경우, image 끝 flush 처리**
   - cnt 가 짝수만 cycle 한다면 (예: 8-way) `i_flush` 신호 추가.
   - flush 시 `{save, zero-pad}` emit + we 펄스. Downstream 이 valid count 따로 알아야 함.

4. **Recursive 구조라면 L3 출력 포맷 확정**
   - 150×150 dense → 다음 iter 시작 시 152×152 로 재패딩 (BRAM 사전 채우기).
   - 152×152 직접 (PE mask 방식) → packer 제거 가능.
