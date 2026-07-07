# W7 Collab options v2 — три варианта на следующий Wave-луп

> phi^2 + phi^-2 = 3

**Дата**: 2026-07-05. **Основано на**: [M2_M4_FPGA_DECOMPOSED_PLAN.md](M2_M4_FPGA_DECOMPOSED_PLAN.md), [W7_WEAK_POINTS_STRUCTURAL.md](W7_WEAK_POINTS_STRUCTURAL.md), [WAVE_REPORT_2026-07-05_FULL.md](WAVE_REPORT_2026-07-05_FULL.md).

**Дополняет**: предыдущий [`docs/W7_COLLAB_OPTIONS.md`](W7_COLLAB_OPTIONS.md) (от 07-05 утра, до pivot'а на M2-M4 hardware). Тот был про кодогенерацию / W7.3 fuzz options. Этот — про M2-M4 hardware + FPGA-attestation.

---

## 0. Роли и trust classes

- **Human (Vasilev D.)**: hardware ops, Vivado, JTAG, merge-права, юр. решения.
- **Cloud agent (Perplexity Computer, sandbox)**: код, тесты, документация, PRs draft, литература, планирование.
- **Local macOS agent (ssdm4, GLM)**: cross-env verification (Zig, Vivado на macOS), on-device evidence sync, peer-review.

Все три уже отлажены за неделю. Coordination protocol работает (mbox handoff, no direct push от local).

---

## Опция A — «Split-brain: cloud pushes Track A, local pushes Track B»

**Образ**: два хирурга оперируют одного пациента с разных сторон стола, каждый в своей ране, координируются между собой через одного анестезиолога.

### Разделение

- **Cloud agent**: полностью ведёт Track A (M2 → M3 → M4). Пишет `daemon.rs`, TUN userspace, HELLO smoke, iperf3 harness, triangle test scripts. Draft PR'ы, human merge'ит после smoke.
- **Local agent**: полностью ведёт Track B (Proof of FPGA). Vivado projects, bitstream builds, device-DNA reader, PUF measurement. Local физически ближе к железу (тот же mac ssdm4 держит Vivado licence, JTAG-cable).
- **Human**: image-bake M2.0 (single blocker обоих треков), физический flash, merge-права, финальные review.

### Плюсы
- Ясное разделение: cloud не трогает Vivado (её нет в sandbox), local не трогает Rust код который cloud уже знает.
- Параллелизм максимальный — оба agent работают одновременно, оба треугольника завершаются к W15.
- Discipline chain (no-paste-review + SHA-advance + external-dep timer) уже отработана между двумя agent'ами.

### Минусы
- **Bus factor** (W7 finding #8) не решён — если local agent недоступен, Track B стоит. Cloud не может Vivado.
- Требует ежедневного mbox sync между agent'ами (сейчас работает, но 30 min/day human overhead).
- Ошибки в разделении: если Track B нуждается в userspace Rust код, а local его не пишет — bottleneck.

### Ratcheting rules для этой опции
1. Cloud не пишет Vivado .tcl без предварительного согласия local (не наш инструмент)
2. Local не merges в `main` (правило репозитория)
3. mbox handoff every 24h, verified with SHA references

### Cost
- Human: 2ч/день (image-bake + merge + hardware ops)
- Cloud: 8ч/день sandbox time
- Local: 4-6ч/день (Vivado не 24/7, но нужно живое присутствие для JTAG)
- **Total**: ~10 недель до end-state (per plan §5)

---

## Опция B — «Cloud-lead + human-executor: одна голова, две руки»

**Образ**: шахматист играет партию, а секундант передаёт ходы по телефону кому-то, кто расставляет фигуры на реальной доске.

### Разделение

- **Cloud agent**: ведёт **оба** трека. Пишет весь код (Rust userspace + Vivado .tcl scripts + M2 daemon + FPGA attestation), готовит step-by-step run books для каждого on-device experiment'а.
- **Human**: тактический executor — flash SD-cards, запускает Vivado GUI под .tcl scripts из cloud, копирует логи назад, merges PR.
- **Local agent**: minor role — cross-env verification (Zig, second-opinion review), не lead ни одного трека.

### Плюсы
- Single point of design coherence — cloud agent видит оба трека, минимизирует cross-track drift.
- Bus factor снижен — если local исчезнет, Track B продолжается (cloud пишет всё, human executes).
- Cost lower по общему human-time — human делает механические ops, не проектирует.

### Минусы
- Cloud agent НЕ имеет hands-on Vivado experience — .tcl scripts могут быть неоптимальны, требуют iteration через human feedback.
- Все hardware learning сохраняется в cloud memory (durable через memory tool), но НЕ в персональном опыте local agent'а — long-term project resilience страдает.
- Cloud agent throttled на context — 60 дней active work в одной session может hit context limits, требуется session-handoff discipline.

### Ratcheting rules
1. Все Vivado .tcl scripts должны пройти dry-run на local machine перед flash
2. Cloud agent обязательно оставляет skill files (task 7) для session-continuity
3. Каждый M2/M3/M4/A2/A3/A4 milestone finishes with `docs/M<n>_RESULTS.md` со всеми числами

### Cost
- Human: 4-6ч/день (hardware ops + executes cloud instructions)
- Cloud: 8ч/день sandbox
- Local: 1-2ч/день (only cross-env verify, no lead)
- **Total**: ~12 недель до end-state (per plan §5, +2 недели overhead за iteration через human executor)

---

## Опция C — «External embedded engineer + revenue-first FPGA-track»

**Образ**: строим два корабля. Первый (Track A) — рабочий, экономичный, для перевозки грузов. Второй (Track B) — parade корабль, для продажи и грантов. Нанимаем на второй специализированного мастера-корабельщика.

### Разделение

- **Cloud agent**: держит оба трека документально, но **фокусируется на Track B (FPGA)** как revenue-first монетизационный вектор.
- **Human**: image-bake + M2 basic smoke (2-3 недели), потом делегирует M3-M4 внешнему embedded engineer'у (contract work, Nova Labs alumni или Xilinx forum expert, ~$5-10k budget за 2 месяца).
- **Local agent**: cross-env + FPGA support на Vivado.
- **External embedded engineer**: M3 iperf3 + M4 triangle + M5 self-heal (если 4-5 boards procured).

### Плюсы
- **Solves W7 finding #7 (экономика)**: external engineer оплачивается из grant/consulting budget, не из token supply. Совместим с 0% premine.
- Track B (Proof of FPGA) — cloud-lead — публикуется быстрее (~6-8 недель до whitepaper), даёт **раннее revenue-signal** через:
  - Hub71+ submission (2026-08-02 deadline)
  - PoFPGA arXiv publication (2026-08-15 target)
  - FPGA-attestation-as-a-Service pilot pitch (target: Helium, Akash, Bittensor, DIMO — 2026-09-01)
- Bus factor снижается: три independent contributors (human, cloud, external).

### Минусы
- **Requires cash/credits/grant NOW**. External engineer $5-10k — no source of funds identified. Hub71+ не дает cash, даёт residency и mentorship. NSF/EU Horizon grants — 6-12 месяцев процесс.
- Hiring/vetting embedded engineer занимает 2-4 недели, что сжимает M3-M4 timeline с 5 недель до 3-4.
- Track B риск-нагружен revenue-expectation — если PoFPGA не публикуется как first-in-class (W7 literature finds prior art), monetization vector #2 (FPGA-attestation-as-a-Service) может быть занят более крупным конкурентом (Intrinsic ID, PUFsecurity).

### Ratcheting rules
1. External engineer подписывает NDA + open-source contribution CLA — код идёт в public repo с MIT/Apache
2. Cloud agent ежедневно drafts weekly progress для grant reporting (Hub71+ требует progress reports)
3. Proof of FPGA whitepaper — cloud lead, external может contribute measurement data не design decisions

### Cost
- Human: 2ч/день (управление + merge)
- Cloud: 8ч/день
- External engineer: 40ч/неделя × 8 недель = 320ч @ $30-50/hr = **$10k-16k**
- Local: 1-2ч/день
- **Total time**: ~8-10 недель до end-state (external accelerates M3-M4)
- **Total cash**: $10-16k required upfront

---

## Сравнение по 4-м измерениям

| Dimension | Option A (split-brain) | Option B (cloud-lead) | Option C (external + revenue-first) |
|---|---|---|---|
| Time-to-end-state | 10 нед | 12 нед | 8-10 нед |
| Cash required | $0 | $0 | $10-16k |
| Bus factor risk | HIGH (local критичен) | MEDIUM (human executor) | LOW (3 independents) |
| Revenue channel opens | ~W15 | ~W15 | ~W10 (Hub71 + arXiv) |
| Silicon-slip resilience | MEDIUM | MEDIUM | HIGH (revenue не завязан на TT SKY26b) |
| Cognitive load on human | 2ч/день | 4-6ч/день | 2ч/день |

---

## Рекомендация

**Option A** — если cash-constrained, приоритет — hardware ready к 2026-09-15, не готовы платить $10k+.

**Option B** — если хотим минимизировать local dependency (например, local machine потенциально unavailable), готовы жертвовать 2 недели за bus-factor снижение.

**Option C** — если приоритет — revenue-signal ДО silicon (Hub71+ дедлайн 08-02, PoFPGA публикация 08-15), готовы искать grant/consulting funding $10-16k.

Мой (cloud agent'а) читаемый совет — **гибрид A + партиал C**: начать с Option A на 3-4 недели (image-bake + M2 через cloud lead), проверить, что коллаборация с local работает. Затем принять решение по external engineer к W10 в зависимости от Hub71+ status. Так минимизируется upfront cash, сохраняется опция C на будущее.

Финальный выбор — за human. Все три опции совместимы с проектной дисциплиной (spec-drift-guard, no-paste-review, SHA-advance, external-dep timer).

---

phi^2 + phi^-2 = 3
