# W8 — decomposed plan (weak-points × competitor threats)

> phi^2 + phi^-2 = 3

Дата: 2026-07-05, main @ `13e4692`.

**Синтез двух источников**:
- [`W8_WEAK_POINTS_AUDIT.md`](W8_WEAK_POINTS_AUDIT.md) — ранжирование 8 W7-находок + audit-tail A1
- [`W8_COMPETITOR_WATCH_2026-07-05.md`](W8_COMPETITOR_WATCH_2026-07-05.md) — 10 конкурентов по 2 осям

## 0. Одна фраза

Слабые места и конкуренты **сходятся на одной точке давления**: Tri-Net должен показать *реальную денежную* или *реальную функциональную* легитимность до 2026-12-16 tape-out, потому что (a) экономика без Compute-arm 6+ месяцев уязвима (finding #7), (b) PUF-identity commodifиzируется через Synopsys/eMemory/PUFsecurity быстрее чем Trinity ASIC приезжает ([W8_COMPETITOR_WATCH](W8_COMPETITOR_WATCH_2026-07-05.md#axis-b-fpga--puf--silicon-attestation-vendors) Axis B read-out), (c) GEODNET/Helium/XNET уже показывают "real revenue + tier-1 listing" стандарт по которому будет судиться fair-launch модель Tri-Net ([W8_COMPETITOR_WATCH](W8_COMPETITOR_WATCH_2026-07-05.md#axis-a-depin-mesh--decentralized-wireless) Axis A read-out).

## 1. Матрица давления — weakness × threat

| Weakness (W7) | Совпадающий competitor threat | Приоритет |
|---|---|---|
| #1 Silicon single-date | eMemory PUF-PQC на Intel 18A уже сегодня; PUFsecurity PSA-L4 сегодня; Trinity — только в декабре | **CRITICAL** |
| #2 Compute arm blocked pre-silicon | Синопсис/PUFsecurity могут licence PUF-attestation любому конкуренту-DePIN, тот придёт с "рабочим silicon-anchor" раньше | **CRITICAL** |
| #3 3-node self-heal не работает | Helium 100k+ hotspots, XNET 1300+ locations, GEODNET 20k+ базовых станций — 3 узла на этом фоне выглядят как lab experiment, не network | MAJOR (нет денег на 4-й узел) |
| #4 Tri-backend ∩ = ∅ | Не пересекается с competitor threat напрямую | MAJOR (структурный, не рыночный) |
| #5 108.6 dB — digital loopback | XNET/Pollen уже имеют реальную OTA-передачу с carriers; наши цифры без OTA — не сопоставимы | MAJOR |
| #6 Regulatory 5.8 GHz TH closed | Helium имеет FCC licensed spectrum + carrier deals; мы ещё не в Hub71+ | MAJOR |
| #7 Экономика 0% premine + Compute blocked | GEODNET показывает эталон "real revenue → buyback burn" (80% revenue → burn), нам нечего показать; DIMO/WeatherXM subsidize deployment через NFT/token — у нас нет subsidy механизма | **CRITICAL** |
| #8 Bus factor | Не совпадает с прямой competitor threat, но при появлении внешнего contributor это будет первый вопрос | MAJOR |

**Верхняя тройка (совпадение weakness+threat, оба critical)**: #1, #2, #7. Все три — экономика/timeline, не код.

## 2. Что закрыто в этом лупе (W8, уже реализовано в PR #51)

Один DRAFT PR [#51](https://github.com/gHashTag/tri-net/pull/51) `feat/w8-weak-points-mitigations-2026-07-05` `ea8f4db`:

1. **A1** paper-delta `141 → 137` в трёх местах + errata note (audit-tail из W7.5 закрыт)
2. **#1 mitigation** — `docs/SILICON_SLIP_CONTINGENCY.md`: явные сценарии slip 3/6/12 мес, trigger dates 2027-05-01 и 2027-09-01, три развилки (3A pure FPGA / 3B partner PUF / 3C kill Compute clean)
3. **#5 mitigation** — README Metrics disclaimer: 108.6 dB помечен `digital loopback only, not over-the-air`
4. **#6 mitigation** — `docs/REGULATORY_STATUS.md`: single source of truth, таблица TH/SG/UAE/US/EU, contingency chain если Hub71+ не примут
5. **#8 mitigation** — `CONTRIBUTING.md`: 15-минутный quickstart для человеческого контрибьютора

Verified: 137 tests pass on `ea8f4db`; gate v2 N=5 → 5/5 PASS on branch.

## 3. Что декомпозировано на W9 (design docs, ещё не реализовано)

Два design doc'а, оба сходятся на critical-triangle #1+#2+#7:

### W9-D1 — Compute-arm interim attestation path (finding #2)

**Motivation** ← competitor threat: eMemory PUF-PQC + Intel 18A + PSA-L4 доступны конкуренту-DePIN уже сегодня. Мы теряем окно "silicon-anchor moat" быстрее чем закрывается tape-out.

**Deliverable**: `docs/COMPUTE_INTERIM_ATTESTATION.md` — дизайн уровня "level 2 TPM/HSM attestation" (по собственной шкале M7) как временного, помеченного `low-security` пути для Compute arm до silicon. Ссылки на:
- TPM 2.0 spec для generic TPM attestation
- PUFsecurity PUFrt as licensable interim option (buy vs build анализ)
- Помеченный `-sim` disclaimer: этот путь не даёт полной sybil-resistance, только "лучше чем ничего"

**Non-goal**: implementation. Только design doc + explicit trade-off table.

**Effort**: 1 день cloud agent, 0.5 дня human review.

### W9-D2 — Bootstrap operator program (finding #7)

**Motivation** ← competitor threat: GEODNET показывает эталон real revenue + buyback burn; WeatherXM показывает NFT-crowdfunded station deployment; DIMO subsidize через partnership с automakers. У нас — 0% treasury, значит нет капитала для subsidy P203 Mini boards, но нельзя нарушать 0% premine принцип.

**Deliverable**: `docs/BOOTSTRAP_OPERATOR_PROGRAM.md` — дизайн "first-N-operators получают повышенный Era-0 reward multiplier без нарушения 0% premine". Curve скошена в начале, эмиссия всё ещё через proof. Явно контрастирует с Helium equity-based subsidy (Nova Labs) и WeatherXM NFT-crowdfunding. Экономический моделирование: если N=100 operators получают 3x multiplier в первые 6 месяцев, сколько это TRI, какая dilution против long-term supply.

**Non-goal**: governance vote. Только design doc + calibration table.

**Effort**: 1-2 дня cloud agent + human review.

## 4. Что НЕ в W8/W9 (структурные, не документные)

- **#3 hardware** — 4-я плата: $2-3k, procurement, не в этом квартале.
- **#4 execution** — E0425 root cause: отдельный трек, PR #44 in-flight.
- **Sensor/Coverage arms operational**: требует железа и regulatory.

## 5. Дисциплина применения (напоминание для W9)

- **v1.2 numbers-without-realm-check**: любое число в W9-D1/W9-D2 → команда + SHA
- **v1.3 aspiration-vs-property**: если появится regression gate — тестировать инвариант, не асимптоту, N=5 обязательно
- **v1.4 stacked-PR-after-squash-check**: W9-D1 и W9-D2 — независимые PRs, оба base=main. Никаких стеков.

## 6. Что-если сценарии для W9

**Если Hub71+ 2026-08-02 не принят**: W9-D2 (bootstrap operator program) становится **обязательным** — без grant и без treasury единственный путь bootstrap это правильная кривая emission.

**Если PR #44 (E0425 root cause) сходится**: измеримый gate для #4 (tri-backend) становится achievable → добавляется как W10 item.

**Если competitor watch cron (Friday 2026-07-10) поймает новую angle**: adaptive re-prioritization для W9 findings.

---

phi^2 + phi^-2 = 3
