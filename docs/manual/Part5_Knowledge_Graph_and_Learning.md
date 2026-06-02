# Part 5 — Knowledge Graph & Learning Layer

> **이 문서의 위치**
> 7부작 중 5부. Part 1~4 위에 얹는 상위 계층. 개별 프로젝트의 결정·버그·검증을 **연결**하고, 프로젝트를 넘나드는 **반복 패턴을 학습**하는 구조를 정의한다.
> 본문은 도메인 중립. 이번 SRCNN 사례는 말미 **[사례 부록]**.

---

## 1. 추가 개념

Part 1~4는 "한 프로젝트를 잘 수행하는" 구조였다. Part 5는 두 가지를 더한다:

1. **Knowledge Graph** — 한 프로젝트 안의 산출물(결정/버그/조사/테스트)을 연결해, "이 버그가 어느 결정에서 왔고 어떤 테스트로 막혔는가"를 추적 가능하게.
2. **Learning Layer (Failure Pattern DB)** — 여러 프로젝트에서 반복되는 실패 유형을 추출해, 다음 프로젝트의 인터뷰·검증 체크리스트로 환류.

목표 한 줄: **"프로젝트를 기억하는 AI"를 넘어 "프로젝트에서 학습하는 AI".**

---

## 2. Knowledge Graph

### 2.1 연결 대상 (노드)

- **Decision** (DEC-*) — Part 1
- **ADR** (ADR-*) — Part 2
- **Bug** (BUG-*) — Part 4
- **Investigation** (INV-*) — Part 4
- **Test / Regression** (REG-*, tb_*) — Part 4
- (선택) **Module Contract** — Part 2

### 2.2 연결(엣지) 예시

```
BUG-014 (FIFO underflow)
  ├─ caused_by  → DEC-007 (중간 FM을 URAM 64bit 저장 + FIFO 16bit 분해)
  ├─ found_in   → INV-008 (사이클 모델 격자 탐색)
  ├─ decided_by → ADR-005 (prefetch=1 + read@en_cnt==0)
  ├─ tested_by  → tb_linebuffer / REG-003 (L2 첫 라인 정렬)
  └─ pattern    → PAT-04 (Pipeline Latency)
```

이 그래프가 있으면, 나중에 누군가 DEC-007(URAM+FIFO 구조)을 바꾸려 할 때 "이 결정에 BUG-014와 REG-003이 매달려 있다"를 즉시 본다 → 무지성 변경 방지.

### 2.3 구현 (Claude Code)

거창한 그래프 DB가 필요 없다. 각 산출물 파일의 frontmatter에 링크를 박고, 인덱스 파일 하나로 모은다.

```markdown
<!-- verification/bugs/BUG-014.md frontmatter -->
---
id: BUG-014
caused_by: [DEC-007]
found_in: [INV-008]
decided_by: [ADR-005]
tested_by: [REG-003]
pattern: [PAT-04]
---
```

```markdown
<!-- knowledge/index.md — 슬래시 커맨드로 자동 재생성 -->
프로젝트의 모든 DEC/ADR/BUG/INV/REG/PAT를 스캔해 엣지를 모아 출력.
```

슬래시 커맨드 예:
```markdown
<!-- .claude/skills/kg-build/SKILL.md -->
---
name: kg-build
description: 산출물 frontmatter를 스캔해 knowledge/index.md 그래프를 재생성한다
---
design/ docs/ verification/ 의 모든 *.md frontmatter를 읽어
노드/엣지를 수집하고 knowledge/index.md 로 정리한다.
끊긴 링크(존재하지 않는 ID 참조)는 경고로 표시한다.
```

---

## 3. 상태 승격 (Fact → Hypothesis → Proven)

Part 4의 라벨링을 프로젝트 전체에 일관 적용하고, 그 승격 이력을 그래프가 추적한다.

```
Fact (관찰/코드 인용)
  → Hypothesis (추정)
    → [실험/검증]
      → Proven (확정)
```

승격이 추적되면 "이 결론이 어떤 증거 위에 서 있나"를 역추적할 수 있다. 반대로, 어떤 Proven의 근거 실험이 나중에 무효화되면(예: stub 전제가 실제 IP와 다름이 밝혀지면), 그에 매달린 결론들을 그래프로 찾아 재검증한다.

---

## 4. Failure Pattern DB (학습 계층)

### 4.1 개념

개별 버그(BUG-*)는 프로젝트 고유다. 하지만 그 **유형**은 프로젝트를 넘어 반복된다. 반복 유형을 PAT-*로 추출해, 다음 프로젝트의 체크리스트로 쓴다.

### 4.2 반복 패턴 카탈로그 (RTL/하드웨어 도메인 예)

이 카탈로그 자체가 도메인 의존적이므로, 다른 도메인으로 가면 교체한다. RTL 프로젝트에서 거듭 나타나는 유형:

1. **Valid Timing** — valid/ready 신호의 지연 단수 불일치. 모듈 경계에서 1clk 어긋남.
2. **Window Ordering** — 슬라이딩 윈도우(line buffer 등)에서 픽셀/탭 순서 뒤바뀜.
3. **Weight Ordering** — 가중치 메모리 레이아웃과 분배 로직의 순서 약속 불일치.
4. **Pipeline Latency** — 파이프 단수 누적 오차. prefetch/버퍼링 깊이 부족으로 인한 under/overflow.
5. **FIFO Width Conversion** — 폭 변환(예: 64bit→16bit) 시 분해/조립 순서(MSB-first 등) 불일치.

### 4.3 패턴 레코드 양식

```markdown
# PAT-04: Pipeline Latency

## Symptom
파이프라인 지연(특히 메모리 read latency + FIFO 도착 지연)을 과소평가해
버퍼가 비는 순간 pop → underflow, 또는 데이터 정렬 어긋남.

## Root Cause Family
read 요청 시점과 데이터 도착 시점의 clk 차이를 설계에 반영 안 함.

## Detection (다음 프로젝트 체크리스트)
- 모든 메모리/FIFO의 read→data 도착 latency를 명시했는가?
- 소비측이 비는 최악 시점에 prefetch/buffer가 충분한가?
- 사이클 모델로 min_buffer ≥ 1, underflow = 0을 증명했는가?

## Prevention
- module_contracts에 latency를 계약으로 박는다.
- 폭/위상 조합을 격자 탐색으로 검증한다.

## Seen In
- SRCNN_4_2_1 / BUG-014 (URAM→FIFO, prefetch=1로 해결)
```

### 4.4 환류 (Learning Loop)

```
프로젝트 N에서 BUG 발생
  → PAT로 추출/갱신
    → PAT의 Detection 항목이 프로젝트 N+1의 인터뷰(Part 1) 체크리스트에 추가
      → 같은 유형의 버그가 N+1에서는 설계 단계에서 차단
```

이게 "학습하는 AI"의 실체다. 모델 가중치를 바꾸는 게 아니라, **프로젝트 산출물(PAT DB)을 다음 프로젝트의 입력으로 환류**시키는 구조적 학습이다.

---

## 5. 전체 7부작 연결 요약

```
Part 0 개요/세션규율 ──→ 컨텍스트 60%룰, 덤프 후 clear, 단계 진입점
Part 1 인터뷰 ──→ design/decisions, assumptions, unresolved_questions
Part 2 문서화 ──→ docs/adrs, architecture, module_contracts, verification_plan
Part 3 부트스트랩 에이전트 ──→ 위 둘을 수행 + BUILD 게이트
Part 6 Plan→Tasks→Implement ──→ plan.md, tasks.md, 태스크별 구현(+analyze 게이트)
Part 4 검증 에이전트 ──→ verification/investigations, bugs, regressions
Part 5 지식그래프/학습 ──→ knowledge/index (연결) + patterns/PAT-* (학습 환류)

실행 순서: 0 → 1 → 2 → [3 게이트] → 6 → 4 → 5
순환: Part 5의 PAT → Part 1의 체크리스트로 되돌아감
```

---

## [사례 부록] SRCNN 프로젝트에서 추출되는 지식

> 재사용 시 교체.

### 부록 A — 이 프로젝트의 Knowledge Graph (실제)

```
BUG-014 (L2 FIFO underflow)
  ├─ caused_by  → DEC: 중간 FM URAM 64bit 저장 + FIFO 16bit 분해
  ├─ found_in   → INV: RTL 1:1 사이클 모델 격자 탐색
  ├─ decided_by → ADR: prefetch=1 + read@en_cnt==0 + 주소(r_bram>>2)+1
  │               + top FIFO wr_en ← uram rd_valid
  ├─ tested_by  → REG: L2 첫 라인 픽셀 정렬, golden_L2 대조
  └─ pattern    → PAT-04 (Pipeline Latency), PAT-05 (FIFO Width Conversion)

REFACTOR: pe_group 모듈 분리
  ├─ contract   → pe_group 타이밍 계약(o_valid 3단 지연)
  ├─ tested_by  → Layer1 회귀 (비트/타이밍 동치)
  └─ pattern    → PAT-01 (Valid Timing)
```

### 부록 B — 이 프로젝트에서 실제로 부딪힌 패턴 매핑

| PAT | 이번 프로젝트에서의 발현 |
|-----|-------------------------|
| PAT-01 Valid Timing | pe_group o_valid 3단, done 패스스루를 동일 3단으로 정렬 |
| PAT-02 Window Ordering | line_buffer 정적 윈도우 `{r_line2[47:0],r_line1[47:0],r_line0[47:0]}` LSB 고정 + valid를 "3행3열~152열"로 재정의 |
| PAT-03 Weight Ordering | weight BRAM 32word 레이아웃(K{oc}-{ic}-{tap}) ↔ weight_dispatch 분배 약속. 왕복(패킹→분배→복원) 비트 일치로 검증 |
| PAT-04 Pipeline Latency | URAM read +1clk, FIFO 도착 +2clk → prefetch=1로 underflow 차단 |
| PAT-05 FIFO Width Conversion | 64bit→16bit MSB-first 4분할, fifo_add_to_uram 조립도 MSB-first로 정합 |

### 부록 C — 다음 프로젝트로 환류할 체크리스트 (이 프로젝트가 남긴 학습)

1. **자원 예산을 Constraints DEC로 먼저 박아라.** (line_buffer LUT 폭증을 사후 발견한 교훈 → Part 1 Constraints 강화)
2. **메모리/FIFO latency를 module_contract에 명시하라.** (prefetch 누락이 underflow를 낳음 → Part 2)
3. **Fix 결정은 즉시 ADR로.** (prefetch=2/1 혼선 → 결정의 맥락 미문서화가 재구성을 흔듦 → Part 2/4)
4. **검증 실험은 subagent로 격리하라.** (대량 실험 출력이 메인 컨텍스트를 채워 세션이 반복 중단됨 → Part 4 6.2)
5. **PENDING을 조용히 넘기지 마라.** (ReLU 유무 미결을 명시적 항목으로 → Part 1 unresolved_questions)

이 5개가 바로 이 매뉴얼 전체를 관통하는 "이번 프로젝트가 가르쳐준 것"이다.
