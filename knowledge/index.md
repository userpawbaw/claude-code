# Knowledge Graph — Index

> Part 5 §2.3 양식. 산출물 frontmatter 를 수동 수집한 그래프.
> 자동 재생성 (`kg-build` 스킬) 은 도입 전 상태이며, 수동 갱신 중.

---

## 1. Projects

- **SRCNN_4_2_1** (`srcnn/`) — 멀티레이어 1→4→2→1, KV260 (XCZU5EV).
  HANDOFF: `srcnn/HANDOFF.md` (인수인계 단일 진실 문서).

---

## 2. Nodes

### Decisions / ADRs

> 미생성 (Part 1/2 에 대응. 이번 세션은 Part 4/5 만 진행).

### Investigations (INV-\*)

| ID | 제목 | 상태 | Pattern |
|---|---|---|---|
| INV-001 | L1 마지막 8 픽셀/채널 손실 | closed | PAT-01 |
| INV-002 | L2 oc1 +4 픽셀 시프트 | closed | PAT-06, PAT-04 |

→ `srcnn/verification/investigations/`

### Bugs (BUG-\*)

| ID | 제목 | Fixed in | Pattern |
|---|---|---|---|
| BUG-001 | FSM S_DONE 이 첫 wr_pulse 에서 즉시 exit | `20e7845` | PAT-01 |
| BUG-002 | out_ch 경계에서 FIFO 잔류 4픽셀 → +4 시프트 | `8b45917` | PAT-06, PAT-04 |

→ `srcnn/verification/bugs/`

### Regressions (REG-\*)

| ID | tb | Covers | Modes |
|---|---|---|---|
| REG-001 | tb_L1.v | BUG-001 | conv-only, ReLU |
| REG-002 | tb_L2.v | BUG-001, BUG-002 | conv-only, ReLU |
| REG-003 | tb_out.v | BUG-001, BUG-002 (+ end-to-end) | conv-only, ReLU |

→ `srcnn/verification/regressions/`

### Patterns (PAT-\*)

| ID | 이름 | 상태 | 도입 출처 |
|---|---|---|---|
| PAT-01 | Valid Timing | active | manual seed + SRCNN BUG-001 |
| PAT-02 | Window Ordering | listed-only | HANDOFF §3.1 (line_buffer LSB-in 시프트) |
| PAT-03 | Weight Ordering | listed-only | HANDOFF §6 (weight BRAM 레이아웃) |
| PAT-04 | Pipeline Latency | active | manual seed + HANDOFF BUG-014 |
| PAT-05 | FIFO Width Conversion | listed-only | HANDOFF §7 (64→16 MSB-first) |
| **PAT-06** | **Cross-Boundary State Residue** | **active (NEW)** | **SRCNN INV-002 / BUG-002** |

→ `knowledge/patterns/`

`active` = 본 세션에서 정식 레코드 작성됨.
`listed-only` = HANDOFF 부록 / manual §4.2 에 카탈로그 항목으로 언급, 정식 레코드 미작성 (추후 환류 시 작성).

---

## 3. Edges (수동 수집)

### BUG-001 (FSM tail loss)
```
BUG-001
  ├─ caused_by  → (DEC 미생성; HANDOFF §3.3(c) spec)
  ├─ found_in   → INV-001
  ├─ fixed_in   → commit 20e7845
  ├─ tested_by  → REG-001, REG-002, REG-003
  └─ pattern    → PAT-01 (Valid Timing)
```

### BUG-002 (FIFO leftover cross out_ch)
```
BUG-002
  ├─ caused_by  → (HANDOFF spec 누락 — 사이클 모델이 단일 라운드만 봄)
  ├─ found_in   → INV-002
  ├─ fixed_in   → commit 8b45917
  ├─ tested_by  → REG-002, REG-003
  └─ pattern    → PAT-06 (Cross-Boundary State Residue) ← NEW
                + PAT-04 (Pipeline Latency, 인접 패턴)
```

### REFACTOR: pe_group 모듈 분리 (HANDOFF §3.2)
```
REFACTOR
  ├─ contract   → pe_group 타이밍 계약 (o_valid 3단, o_pe_done = img_done+3)
  ├─ tested_by  → REG-001 (L1 회귀 비트 동치)
  └─ pattern    → PAT-01
```

---

## 4. Status 승격 추적

| 신호 / 결정 | 상태 | 근거 |
|---|---|---|
| pe_group o_valid 3단 지연 | Proven | HANDOFF §3.2 + REG-001 PASS |
| FSM done = i_adder_done | Proven | INV-001 Evidence + REG-001/2/3 PASS |
| FIFO srst on dispatch_rst | Proven | INV-002 Evidence + REG-002 PASS |
| prefetch=1 + en_cnt==0 + addr+1 | Proven | HANDOFF §3.3 + REG-002 PASS (단, 라운드 경계 leftover 부작용은 PAT-06 으로 분리 관리) |
| URAM stub +1clk rd_valid | Hypothesis | stub 전제; 실 IP 대조 미수행 (HANDOFF §9 PENDING) |
| FIFO IP 64→16 (Standard, Valid_Flag=false) | Fact | xci 확인 (HANDOFF §7) |
| 6 FIFO 인스턴스 동시 생성 가능 여부 | Hypothesis | 실 IP 확인 미수행 |

---

## 5. 향후 환류 (Part 1/2 로 거슬러 갈 항목)

1. **PAT-06 → Part 1 인터뷰 질문**: "다회 라운드를 도는 데이터패스라면, 라운드 경계에서 어느 모듈이 어떻게 reset 되는가? prefetch 와 drain 의 대칭성은?"
2. **PAT-01 → module_contracts**: 모든 valid/done 의 latency 와 "첫/마지막 펄스 의미" 를 계약으로 박기.
3. **PAT-04 → verification_plan**: 사이클 모델을 최소 2 라운드 시뮬레이션하도록 명시.
4. **PAT-02/03/05 정식 레코드 작성**: HANDOFF 부록의 카탈로그를 정식 PAT-*.md 로 승격.
5. **stub vs 실 IP 검증**: HANDOFF §9 의 PENDING (URAM rd_valid latency, FIFO IP 사양, 6 인스턴스 가능 여부) 을 실 IP 환경에서 측정해 Hypothesis → Proven 승격.
