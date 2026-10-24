# 실제 산출물 예시 — AI·수학·코드 혼합 시험

아래는 사용자 제공 강의자료의 **주제 구성**을 모델로 만든 **예시 출력**이다. 퀴즈 수치·답안·학습 로그는 가상의 학습자를 위한 예시로, 실제 시험문항이나 사용자 성취도 기록이 아니다. 출처가 확인되지 않은 개별 원본 페이지는 `verification_pending`으로 둔다.

## 사례 1. 강의 원본 목차를 한 번에 요약하지 않고 분할

```text
Course: Introduction to AI (예시)
Sources:
  W2 Mathematics for AI (probability, inference, linear algebra)
  W3 Supervised Learning (linear / logistic / softmax regression)
  W4 Unsupervised Learning (clustering, PCA)
  W6 Deep Learning (perceptron, MLP, generalization)
  Labs: linear regression, softmax, KMeans, MNIST

P1 (전체 구조 이해)
  U01 확률의 기본 구조                   pending
  U02 확률분포·기댓값/분산              pending
  U03 통계적 추론 MLE/MAP               pending
  U04 선형대수와 기울기                  pending
  ...
  U14 신경망과 일반화                    pending

Now teaching: P1 / U01-A (표본공간·사건·확률)
Next message: P1 / U01-B (조건부확률·독립)
P1 completed?: NO (한 번에 모든 PDF를 요약하지 않음)
```

## 사례 2. '같은 개념'을 회독별로 확장한다

**주제: K-means (W4, 군집화)**

### P1 결과물의 실제 분량/깊이

> **K-means란?** 비슷한 데이터를 K개의 묶음으로 나누는 비지도학습 알고리즘이다. 예를 들어 고객 100명의 구매 특성을 보고 비슷한 고객군 3개를 찾을 수 있다. 이때 각 묶음을 대표하는 **중심점(centroid)**을 잡고, 가까운 중심점으로 데이터를 배정하고, 각 묶음의 평균으로 중심점을 바꾸는 과정을 반복한다. 왜 필요할까? 개별 고객에게 정답 라벨이 없어도 전체 데이터 안의 구조를 탐색하기 위해서다. 전체 지도에서는 '비지도학습 → 군집화'에 속하며, PCA처럼 차원을 줄이는 일과는 목표가 다르다.

**즉시 확인(정답 비공개):**
- Q-P1-01. 고객을 3개 집단으로 묶고 싶지만 정답 라벨이 없다. '지도 분류 / 군집화 / 회귀' 중 어느 접근을 우선 고려하며, 왜인가?
- Q-P1-02. K-means에서 중심점은 데이터 할당 후 어떤 값으로 갱신하는가?

### P2 확장 — 작동 원리/비교

- 거리 척도 선택과 데이터 스케일이 왜 군집에 영향을 주는지.
- 초기 중심점에 따라 결과가 달라질 수 있는 이유.
- K-means와 K-medoids의 대표점 차이(평균 중심 vs 실제 데이터 대표점).
- 비교형 문항: '이상치가 매우 강한 경우 어떤 방법의 대표점이 더 안정적인가? 왜?'

### P3 확장 — 손계산

데이터 `{1, 2, 8, 9}`, K=2, 초기 중심 `μ1=1`, `μ2=9`라면, 각 점을 가까운 중심에 할당 → 군집 `{1,2}`, `{8,9}` → 새 중심 `μ1=1.5`, `μ2=8.5`. 다른 초기값에서 다른 경로가 나오는지 비교한다.

### P4 확장 — 코드

```python
# 교재 원문이 아니라 구조 설명용 의사 코드
for x in points:
    distances = [distance(x, centroid) for centroid in centroids]
    nearest = min(range(len(distances)), key=lambda k: distances[k])
    assignments.append(nearest)
```

- `distance()` 입력·출력과 `nearest` 선택 로직 추적
- 동일한 데이터에서 비교 연산자가 거꾸로 되면 생기는 오류를 설명
- 실제 ipynb 파일이 주어지면 원본 셀 번호 및 구현 차이를 확인한 후 문항 출제

## 사례 3. P1 학습 → 문항 → 채점 → 피드백

```text
[강의 결과]
P1 / U03 — MLE와 MAP
목표: 확률분포의 모수를 '데이터로 추정'한다는 뜻과
      Prior의 유무를 예시로 구별할 수 있다.

[비공개 정답형 질문]
Q-003: 동전 앞면 확률을 추정하는데 이전 실험의 정보를
       추가 반영하려고 한다. MLE와 MAP 중 어느 방법이
       설계상 더 적합한가? 이유도 한 문장으로 설명하라.
출처: W2 통계적 추론 파트 / 정확한 페이지 미검증

[가상 학습자 답변]
"MAP. 데이터와 과거 정보가 같이 반영되니까." 확신도: high.

[채점]
정답: MAP. 중요한 단서인 Prior를 정확히 언급함.
하지만 P1에서 '안다'는 뜻이지 P3의 Posterior 유도를
완료했다는 뜻은 아님.
state: P1/U03 checked, next: W2 다음 concept,
review: 시간차에 바뀐 문항으로 재확인.
```

## 사례 4. 오답의 원인에 따라 다른 보강

- 학습자 A: 'MLE=평균, MAP=중앙값'이라고 답함 → `concept` → **두 방법이 '추정법'이지 특정 통계량 이름은 아니라는 설명** 후 다시 말하게 한다.
- 학습자 B: 정답 MAP을 고르지만 이유가 '언제나 더 정확해서' → `discrimination` → **prior가 잘못되면 오히려 성능이 나빠질 수 있음**을 설명한다.
- 학습자 C: 수식은 맞지만 미분이 틀림 → `math` → P3에서 수식 단계를 분리하고 중간 기호의 의미를 확인한다.
- 학습자 D: 노트북 구현에서 `dim`이 틀림 → `code` → 입력·출력 tensor shape를 먼저 추적한다.

## 사례 5. 상태 파일과 세션 재개

`.agents/skills/spiral-study-coach/assets/session-state.example.json`은 가상 예제다. 실사용에는 동일 구조의 개인별 복사본을 별도 보관한다.

**재개시 AI 응답 예시**

> 현재 P1, 다음 단위는 `U01-B`입니다. `U01-A`의 출처 및 개념 테스트는 완료되었고 조건부확률과 독립성은 아직 미학습 상태입니다. 먼저 이전 오답 `Q-001`의 핵심 개념을 짧게 인출한 뒤, 이번에는 조건부확률이 왜 필요한지 예시로 설명하고 연습 문제를 내겠습니다. 원본 파일을 직접 확인할 수 없으면 페이지 번호를 추측하지 않겠습니다.

## 사례 6. 회독 종료 리포트 (가상)

```text
P1 closure checklist
Source inventory reviewed: 5 PDFs + 4 notebooks (example)
Eligible units: 14
Teaching done at P1 depth: 14 / 14
Questions answered: 38 / 42
High-confidence wrong: 2; low-confidence right: 5
Unverified page refs: 0
Missing / excluded: explicitly documented
Outcome: P1 full-coverage check APPROVED
Next: P2 starts with mechanisms; carry forward 7 flagged topics.
```

이 결과물은 예시일 뿐 실제 파일 5개를 검증했다거나 사용자가 38문항을 풀었다는 기록이 아니다.
