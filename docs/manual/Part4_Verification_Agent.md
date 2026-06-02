# Part 4 — Verification Agent

> **이 문서의 위치**
> 7부작 중 4부. 이 매뉴얼의 **핵심**. Bootstrap이 설계를 확정했다면, Verification Agent는 구현이 그 설계와 맞는지 가설 기반으로 증명한다.
> 본문은 도메인 중립 + Claude Code 설정 예시. 이번 SRCNN 사례는 말미 **[사례 부록]** — 분량이 가장 많다(실제로 가장 많이 일어난 일이므로).

---

## 1. 핵심 아이디어

**AI 코딩 로그의 진짜 강점은 코드 생성이 아니라 검증 루프다.**

코드는 틀릴 수 있다. 중요한 건 틀렸을 때 **체계적으로 좁혀 들어가는 능력**이다. 좋은 엔지니어는 버그를 만나면 무작위로 코드를 고치지 않는다. 관찰하고, 가설을 세우고, 그 가설을 판별할 실험을 설계하고, 증거로 후보를 제거한다. 이 매뉴얼의 Verification Agent는 그 절차를 명시적 상태머신으로 강제한다.

핵심 표어: **"이 변경이 왜 맞는지 증거로 말하라. 느낌으로 고치지 마라."**

> **업계 표준과의 정렬 — 그리고 우리가 더 강한 지점**
> spec-kit는 `/analyze`로 스펙·플랜·태스크의 일관성을 구현 전 검사하고, BMAD는 개발자/QA/PM/보안 페르소나의 자기검토 라운드를 돌린다. 둘 다 "구현 전 정적 검토(review)"에 강하다.
> 그러나 둘 다 **실행 후 동적 검증**은 "테스트를 돌려본다" 수준에 그친다. 우리 Part 4는 여기서 한 단계 더 간다: 증상→가설→실험→증거로 좁히는 **가설 기반 디버깅 상태머신** + **Fact/Hypothesis/Proven 라벨링** + **시뮬레이터 부재 시 검증 위계**까지 명시한다.
> 이 차이가 중요한 이유: 소프트웨어는 "테스트 통과 = 충분"인 경우가 많지만, 하드웨어/수치 도메인(RTL, DSP, 펌웨어)은 **골든 대조와 타이밍 증명**이 필수다. 테스트가 초록불이어도 1clk 어긋난 파이프라인은 통과해버린다. 따라서 RTL류 프로젝트에서는 spec-kit의 정적 리뷰 위에 **이 8단계 동적 검증을 반드시 얹어야 한다.** (소프트웨어 프로젝트라면 자기검토 라운드로 가볍게 가져가도 된다 — 도메인에 맞게 무게를 조절하라.)

---

## 2. 검증 상태머신 (8단계)

```
1. Observe          관찰: 무엇이 어떻게 잘못됐는가 (증상을 사실로 기록)
2. Hypothesis       가설: 원인 후보들 (복수, 배타적으로)
3. Experiment Design 실험 설계: 가설을 판별할 최소 실험
4. Evidence         증거: 실험 결과 (수치/로그)
5. Narrowing        좁히기: 증거로 가설 제거
6. Root Cause       근본 원인: 남은 단일 가설 확정
7. Fix              수정: 원인에 직접 대응하는 변경
8. Regression       회귀: 수정이 기존 동작을 안 깨는지 확인
```

각 단계는 건너뛰지 않는다. 특히 **2(복수 가설)** 와 **3(최소 실험)** 이 핵심이다. 가설을 하나만 세우면 확증편향에 빠지고, 실험이 크면 어느 변수가 원인인지 분리가 안 된다.

---

## 3. 기록 원칙 — Fact / Hypothesis / Proven

검증 과정의 모든 진술에 라벨을 붙인다:

- **Fact** — 직접 관찰했거나 코드에서 확정한 사실. ("FSM은 uram_en_cnt==0에서 read를 건다" — 코드 라인 인용)
- **Hypothesis** — 아직 미검증 추정. ("read@en_cnt==3이면 underflow가 날 것이다")
- **Proven** — 실험으로 검증된 가설. ("사이클 모델 결과 read@en_cnt==3 + prefetch=1은 underflow=1 — Proven")

이 라벨링이 중요한 이유: 라벨 없이 진행하면 가설이 어느새 사실처럼 취급되고, 나중에 그게 틀렸을 때 의존한 모든 결론이 무너진다. (Part 1의 "assumption을 decision으로 착각" 문제의 검증 버전.)

상태 승격: `Fact + Hypothesis → 실험 → Proven`. Part 5의 Knowledge Graph는 이 승격 이력을 추적한다.

---

## 4. 저장소 3종

```
verification/
├── investigations/   # INV-*: 조사 1건당 1파일 (8단계 전 과정 기록)
├── bugs/             # BUG-*: 확정된 버그 + 근본 원인 + 수정
└── regressions/      # REG-*: 회귀 테스트 (한 번 잡은 버그는 다시 안 나게)
```

### Investigation Log 양식

```markdown
# INV-008: L2 입력에서 FIFO underflow 의심

## Observe (Fact)
L2 데이터패스에서 FIFO din이 1픽셀 밀릴 가능성. top의 wr_en=rd_en(현재 clk),
din=rd_dout(1clk 후). [top.v 섹션 3 인용]

## Hypothesis
H1: 현재 구조(prefetch 없음, read@en_cnt==3)는 FIFO가 비는 순간 pop → underflow
H2: FIFO IP가 흡수해서 문제없음 (기존 L1→L2 회귀가 안전했던 이유)

## Experiment Design
RTL 신호를 1:1로 옮긴 Python 사이클 모델. read→+2clk FIFO 도착 반영.
prefetch ∈ {0,1,2} × read@en_cnt ∈ {0,1,2,3} 격자 탐색.
지표: min_fifo, underflow, aligned(픽셀 순서 일치).

## Evidence (Proven)
- prefetch=1, read@en_cnt==3 → underflow=1, aligned=False  (H1 지지)
- prefetch≥2 → 모든 en_cnt에서 min_fifo=2, underflow=0
- prefetch=1 + read@en_cnt∈{0,1} → 안전

## Narrowing
H2 기각(흡수 안 됨). H1 채택.

## Root Cause
4번째 pop 직후 다음 word를 당기면 +2clk 지연 때문에 빈 채로 pop.

## Fix
prefetch 1회(S_W_READ 시작) + read@en_cnt==0 + 주소 (r_bram>>2)+1.
top: FIFO wr_en을 uram rd_valid로 연결.

## Regression
→ REG-003 등록 (L2 첫 라인 픽셀 정렬 검사)
```

### Bug DB / Regression DB
- **bugs/**: INV에서 Root Cause가 확정되면 BUG로 등록. 동일 패턴은 Part 5 Failure Pattern으로 승격.
- **regressions/**: 잡은 버그마다 재발 방지 테스트 1개. "한 번 통과한 검증은 영구히 통과해야 한다."

---

## 5. 검증 도구 전략 — 시뮬레이터가 없을 때

이상적으로는 HDL 시뮬레이터(iverilog/verilator/Vivado)로 RTL을 돌린다. 하지만 환경 제약으로 시뮬레이터가 없을 수 있다. 그럴 때의 대안 위계:

1. **HDL 시뮬레이션** (가능하면 항상 1순위) — 실제 RTL 동작.
2. **사이클 정확 모델** — RTL 신호를 Python 등으로 1:1 모사. 타이밍/제어 로직 검증에 강력.
3. **레퍼런스(golden) 대조** — 수치 정확성 검증. NumPy 등으로 알고리즘 골든 생성 → RTL 출력과 비교.
4. **손 계산 검산** — 첫 몇 개 출력값을 직접 계산해 모델/골든을 교차검증.

2~4는 시뮬레이터 부재 시에도 상당한 신뢰를 준다. 특히 **사이클 모델 + golden 대조 + 손 검산**을 겹치면 타이밍과 수치 양쪽을 커버한다.

> 단, 모델/스텁은 실제 IP와 타이밍이 다를 수 있다. 사이클 모델의 전제(예: "URAM read는 +1clk latency", "FIFO read는 +2clk 도착")를 **명시적으로 stub에 박고 문서화**해야, 나중에 실제 IP와 어긋날 때 어디를 의심할지 안다.

---

## 6. Claude Code 구성 (일반형 예시)

### 6.1 검증 전용 슬래시 커맨드

```markdown
<!-- .claude/skills/investigate/SKILL.md -->
---
name: investigate
description: 버그/이상 증상에 대해 8단계 검증 상태머신을 실행한다
---
주어진 증상에 대해:
1) Observe를 Fact로 기록 (코드 라인 인용 필수)
2) 배타적 가설 2개 이상 (Hypothesis 라벨)
3) 가설을 판별할 최소 실험 설계
4) 실험 실행, 결과를 Evidence로
5) 증거로 가설 제거
6) Root Cause 확정
7) Fix 제안 (원인에 직접 대응)
8) verification/regressions/ 에 회귀 테스트 등록
모든 진술에 Fact/Hypothesis/Proven 라벨을 단다.
결과를 verification/investigations/INV-*.md 로 저장한다.
```

### 6.2 Subagent로 격리 (권장)

검증은 subagent로 격리하기 좋은 대표 작업이다. 이유: 검증은 대량의 실험 출력·로그를 만들어 메인 세션 컨텍스트를 빠르게 채운다. subagent로 돌리면 메인은 깨끗하게 유지하고, 결과 요약(INV 파일 경로 + Root Cause)만 받는다.

```markdown
<!-- .claude/agents/verifier.md -->
---
name: verifier
description: 격리된 컨텍스트에서 검증 상태머신을 수행하는 subagent
---
8단계 검증을 수행하고, 메인 세션에는 INV 요약과 Root Cause만 반환한다.
실험 로그 전문은 verification/ 에 파일로 남기고 본문에 쏟지 않는다.
```

> 이 프로젝트가 컨텍스트 한도로 반복해서 막힌 직접 원인이 바로 이것이다 — 검증 실험의 대량 출력이 메인 대화에 누적됐다. subagent 격리는 단순 권장이 아니라, 이 매뉴얼을 만들게 된 문제의 직접 해법이다.

---

## 7. 검증 순서 원칙

- **단계적 확장.** end-to-end를 한 번에 검증하지 않는다. 가장 작은 단위(단일 채널/단일 모듈)부터 golden과 맞춘 뒤 확장.
- **회귀 먼저.** 모듈을 리팩터/분리할 때는 "기존 동작 동일"을 먼저 증명하고 새 기능을 얹는다.
- **경계에서 의심.** 레이어 경계, 라인 경계, 첫/마지막 픽셀에서 타이밍 버그가 가장 잘 난다. 검증 케이스를 경계에 집중.

---

## [사례 부록] SRCNN 프로젝트의 실제 검증 루프

> 재사용 시 교체. 이 부록은 위 상태머신이 실제로 어떻게 돌았는지의 기록이다.

### 부록 A — URAM→FIFO 타이밍 (가장 모범적인 루프)

이 프로젝트에서 8단계가 가장 깨끗하게 돌아간 사례.

- **Observe**: `verification_notes.md` 7.1에 "fifo.wr_en=rd_en(현재 clk)인데 din=rd_dout(1clk 후)"라는 의심이 Fact로 이미 기록돼 있었음.
- **Hypothesis**: H1=현 구조는 underflow 발생 / H2=FIFO IP가 흡수.
- **Experiment**: RTL 신호 1:1 Python 사이클 모델. read→+2clk 도착 반영. prefetch × read-phase 격자 탐색.
- **Evidence**: `prefetch=1, read@en_cnt==3` → underflow=1, aligned=False (Proven). `prefetch≥2` → 전부 안전. `prefetch=1 + en_cnt∈{0,1}` → 안전.
- **Narrowing→Root Cause**: 4번째 pop 직후 당기면 +2clk 지연으로 빈 pop.
- **Fix (최종 채택안)**: **prefetch 1회**(S_W_READ 시작 시 uram 주소 0 read) + **read@en_cnt==0** + **주소 (r_bram>>2)+1**. top에서 FIFO `wr_en`을 uram `rd_valid`로 연결.

> **주의 — 이 매뉴얼을 만들며 발견한 실제 오류**: 복구 과정에서 한때 "prefetch=2가 가장 견고"라고 정리했었는데, 실제 채택본 코드(`FSM_pad_line_buff_improved.v`)는 **prefetch=1**이었다. 사이클 모델상 prefetch=2가 더 여유롭지만, 실제로는 "prefetch는 시작 시 1회만, 나머지를 read 위상으로 해결"하는 더 단순한 안이 채택됐다. → **교훈**: Fix 결정은 즉시 ADR로 박아야 한다. 안 그러면 재구성 시 "더 안전해 보이는 안"으로 잘못 복원된다. (Part 2 ADR의 존재 이유.)

### 부록 B — pe_group 포트 추가 + 회귀

- **변경**: `i_line_done` 입력 / `o_pe_done` 출력 추가.
- **타이밍 계약 적용**: `o_valid`가 `i_line_valid` 기준 3단(line_valid→pe_valid→adder_val1→o_valid)이므로, done도 동일 3단(`i_line_done→done_d0→done_d1→o_pe_done`)으로 정렬. [module_contracts의 타이밍 계약 직접 적용]
- **회귀 안전성**: `pe_group` 분리가 기존 PE generate + adder tree와 비트/타이밍 동치임을 보존(사용자 Layer1 회귀 확인). `layer_cnt==0`에서 기존과 동일 동작하도록 mux 분기 → 신규 경로가 L1에 영향 없음.

### 부록 C — golden 대조 + 손 검산 (수치 검증)

- weight.txt(64bit 32word)를 notes 레이아웃대로 **역패킹**해 W1/W2/W3 복원 → 같은 weight로 conv-only golden 생성. (ref.py 자체 랜덤 weight와 RTL을 일치시키는 핵심 단계.)
- **손 검산**: L1 ch0 첫 픽셀=41. 좌상단 패딩 윈도우 `[0,0,0; 0,4,14; 0,3,9]` × 커널 `[1,3,-3; -3,0,1; -2,3,2]` = 14+27 = 41. ✓ — golden과 손 계산이 일치하여 골든 신뢰 확보.
- **오버플로 점검**: L2 raw 누적 max |1723| < 32767(15bit) → 정제 규칙 `{sign,[14:0]}`과 정합 (Proven, 더 이상 가정 아님).
- **stub 정합**: stub PE의 곱 결과 정제 위치가 ref(누적 후에만 정제)와 어긋날 수 있어 점검. 곱 결과 |값|<2^15라 16bit 손실 없음 확인.

### 부록 D — 여전히 열린 검증 항목 (PENDING)

검증이 *끝나지 않은* 항목도 정직하게 남긴다(Part 5 Failure Pattern 후보):
- FIFO IP 실제 사양(64→16, 6인스턴스 생성 가능 여부) — 실 IP 확인 필요.
- wr_pix_addr 리셋 타이밍(레이어 경계 마지막 픽셀 보존).
- 4채널 FIFO 동시 동작 시 depth(underflow/overflow).
- ReLU 유무 (설계 프로파일 확정 대기).
- top의 병렬 인스턴스화(weight_dispatch/channel_accumulator/URAM 6뱅크/line_buffer 4병렬)는 아직 단일 경로 골격 — end-to-end 검증 미완.
