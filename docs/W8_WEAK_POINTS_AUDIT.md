# W8 — аудит слабых мест (rank + cycle-fit)

> phi^2 + phi^-2 = 3

Дата: 2026-07-05. Основано на: [W7_WEAK_POINTS_STRUCTURAL.md](W7_WEAK_POINTS_STRUCTURAL.md) + audit-tail из session log W7.5.

Формат: одна строка на находку. Severity — из W7-документа. Cost-to-fix — оценка человеко-часов и/или $. Cycle-fit — можно ли закрыть в W8 (7 дней) при текущей команде.

## Ранжирование

| # | Weakness | Sev | Cost | Cycle-fit W8 | Owner tier |
|---|---|---|---|---|---|
| 1 | Silicon timeline slip (single date 2026-12-16, no slip contingency doc) | CRIT | 0.5 дня (написать `docs/SILICON_SLIP_CONTINGENCY.md`, 3 сценария) | **YES** | cloud+human |
| 2 | Compute arm blocked pre-silicon, no interim TPM/HSM attestation path documented | CRIT | 1 день (design doc, не реализация) | partial — только design doc | cloud |
| 3 | 3-node triangle не показывает self-heal (path diversity ≥ 2) | MAJOR | 2-3 дня (rename M4/M5 в док-ах) ИЛИ $2-3k (4-я плата) | rename **YES**, hardware **NO** | cloud+human |
| 4 | codegen tri-backend ∩ = ∅, ценность архитектуры не эмпирична | MAJOR | 3-5 дней (fix E0425 root cause, PR #44 в процессе) | partial — attach measurable gate, реализация не в W8 | cloud |
| 5 | 108.6 dB SNR — digital loopback, не эфир; SMA RF loopback не сделан | MAJOR | 0.3 дня (disclaimer в Metrics table) + hardware experiment (human) | disclaimer **YES** | cloud |
| 6 | Regulatory 5.8 GHz — знание разбросано, нет единого `REGULATORY_STATUS.md` | MAJOR | 0.5 дня | **YES** | cloud |
| 7 | Экономика: 0% premine + Compute blocked → нет капитала для bootstrap operators | CRIT | 1 день (design bootstrap operator program без нарушения 0%) | design doc **YES**, execution нет | cloud |
| 8 | Bus factor — один человек: hardware + merge + legal | MAJOR | 0.5 дня (`CONTRIBUTING.md` + delegate docs-only merge) | **YES** | cloud+human |
| A1 | Audit-tail v1.2: paper-delta `141 tests` в 3 местах, реальность 137 | MINOR | 15 минут (3 sed) | **YES** | cloud |

## Итог по cycle-fit W8

Закрываются в этом лупе документами (без hardware, без $):
- **A1** — paper-delta 141→137 (тривиальный audit-tail)
- **1** — SILICON_SLIP_CONTINGENCY doc
- **5** — SNR disclaimer в Metrics table
- **6** — REGULATORY_STATUS.md (сбор существующего знания в один файл)
- **8** — CONTRIBUTING.md (15-мин quick-start для человеческого контрибьютора)

Требуют design-work (можно в W8 как ONE design doc, exec позже):
- **2** — Compute interim attestation path
- **7** — Bootstrap operator program без 0%-premine нарушения

Не в W8 (нужно железо / деньги / внешние люди):
- **3** hardware — покупка 4-й платы
- **4** реализация — фикс E0425 root cause через PR #44 (уже отдельный трек)

## Приоритет реализации в W8

Порядок (по «cost / risk-reduction» ratio):
1. **A1** paper-delta fix (15 мин, closes audit-tail from W7.5)
2. **6** REGULATORY_STATUS.md (0.5 дня, single-file синтез)
3. **1** SILICON_SLIP_CONTINGENCY (0.5 дня)
4. **8** CONTRIBUTING.md (0.5 дня, снижает bus factor)
5. **5** SNR disclaimer правка (15 мин)

Один DRAFT PR `feat/w8-weak-points-mitigations-2026-07-05` содержит все пять правок — они мелкие, документные, тематически связаны, review одним куском проще чем пять отдельных.

phi^2 + phi^-2 = 3
