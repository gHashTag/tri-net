# W7 Collaboration Options — три сценария разделения работы

> phi^2 + phi^-2 = 3

Три варианта, как раскидать работу W7 (см. `docs/W6_WEAK_POINTS_AND_W7_PLAN.md` §3) между cloud sandbox, local macbook и человеком-генералом. Все три предполагают, что PR #42 (W6.2 audit) merged либо остаётся draft — от статуса выбор не зависит.

---

## Option A — «Cloud drives, local verifies, human ratifies»

**Метафора**: cloud — авиапилот, local — приборы, человек — диспетчер.

### Roles

| Actor | Owns | Delivers |
|---|---|---|
| Cloud sandbox | W7.1 (upstream t27c fix), W7.3 (grammar fuzzer v2), W7.6 (anti-anchor CI), W7.7 (trust ledger), W7.8 (PR #42 land) | 5 из 8 workstreams |
| Local macbook | W7.2 (types.zig emission + empirical zig sweep), W7.4 (metamorphic relations) | 2 из 8 |
| Human | W7.5 (paper §4.5 companion phrasing commit) | 1 из 8, но highest-stakes |

### Handoff protocol

Cloud открывает draft PR за workstream, local через `gh api ... contents/` читает full text (не summary), либо `git fetch && git checkout` в local working tree. Approval — inline comment на PR или explicit «approve W7.X» в чате. **Никаких paste review'ов больше**.

### Плюсы

- Максимальная parallelism — 5 cloud + 2 local одновременно.
- Cloud держит все reproducibility scripts (sandbox = single source of truth для чисел).
- Local освобождён от повторной верификации Rust/C (уже сделано в W6.2).

### Минусы

- Local macbook нужен для W7.2 empirical zig sweep (нет zig в sandbox). Если ssdm4 offline на неделю — W7.2 blocks W7.4 (MRs требуют минимум одного compilable backend'а полностью).
- Trust ledger (W7.7) требует cross-env sync policy — иначе становится one-hand fiction.

### Стоимость

Cloud: ~40 tool-часов на всю W7.1-8 minus W7.2/4. Local: ~15 час на W7.2 + W7.4.

---

## Option B — «Divide by concern, not by host»

**Метафора**: два хирурга разной специализации оперируют одного пациента одновременно.

### Roles

Разбиение не по хосту, а по слою:

| Layer | Owner | Workstreams |
|---|---|---|
| Compiler-level (что делает t27c) | Cloud + local (peer review) | W7.1, W7.2 |
| Testing-level (как проверяем t27c) | Cloud primary | W7.3, W7.4, W7.6 |
| Documentation-level (как это подаётся) | Human primary, cloud draft | W7.5, W7.7 |
| Release (W6.2 land) | Cloud | W7.8 |

### Handoff protocol

Каждый layer имеет **свою ветку префиксом**: `w7/compiler/*`, `w7/testing/*`, `w7/docs/*`. Cross-layer PR обязательно линкует parent через `Base:` в description. Human commits только в `w7/docs/*` напрямую или через approve в PR review.

**No-paste-review rule (mandatory для doc-layer, preferred для всех слоёв).** Урок W6.2 weak-point 1.8: draft жил в sandbox, review шёл по paste в chat вместо committed text — это дало почву для anchor'а (agent interpretation слышался как ground-truth). W7 разводит эту связку явно:

- **Doc-layer (`w7/docs/*`) — обязательно**: review производится только против committed text в ветке. Approve возможен только после `git fetch origin <branch> && git show <branch>:<path>` (или эквивалентного `gh api ... /contents/`). Paste в chat допустим как контекст для навигации, но не как объект approve'а.
- **Compiler-layer и testing-layer — preferred**: те же правила, exception возможен для быстрых clarification-циклов (≤10 строк diff), но final approve — против committed text.
- **Enforcement**: reviewer в PR-комментарии явно ссылается на SHA (`Reviewed against <sha>` или `Approved at <sha>`), чтобы approve был воспроизводимо привязан к точному состоянию файла, а не к транзиентному paste'у.

### Плюсы

- Concern-separation даёт естественный CI разбиение — compiler layer прошёл rustc/cc/zig CI до testing layer'а.
- Trust ledger автоматически — каждая ветка имеет свой owner, provenance зашита в branch namespace.
- Human видит только doc-слой в normal flow — меньше context load.

### Минусы

- Overhead branch namespacing и cross-branch dependencies.
- W7.1 compiler fix может влиять на W7.3 fuzz baseline — dependency нельзя разложить полностью параллельно.

### Стоимость

Cloud: ~35 час, но с большим числом веток / PR (5-7 вместо 3-4). Local: ~15 час (только на compiler layer peer review + W7.2 empirical zig).

---

## Option C — «Sequential single-thread with clear gate before each»

**Метафора**: relay race — эстафета с явной передачей палочки, а не одновременный забег.

### Roles

Один host в один момент. Порядок:

1. Cloud — W7.8 (land W6.2) → **gate: PR #42 merged или locked-as-draft explicit**
2. Cloud — W7.1 (upstream t27c fix) → **gate: rustc sweep back to <20 fails**
3. Cloud — W7.2 (emit types.zig — patch) + local — empirical zig sweep → **gate: zig 0.15.2 sweep shows >0 modules compile**
4. Cloud — W7.3 (grammar fuzzer v2 baseline) + W7.4 (MRs) → **gate: at least one disagreement found OR explicit «no disagreement» finding**
5. Cloud — W7.6 (anti-anchor CI) + W7.7 (trust ledger) → **gate: both merged**
6. Human — W7.5 (paper §4.5 commit) → **gate: paper reviewer-ready**

### Plus

- Zero parallelism confusion.
- Каждый gate — очевидный decision point. Никаких overlap-anchor-bias эпизодов.
- Идеально для paper-writing hygiene.

### Минус

- Долго. W7 займёт минимум 3-4 недели вместо 1.5-2 в A/B.
- Cloud часть недели простаивает, если gate не пройден.

### Стоимость

Cloud: ~35 час, но растянуто на 3-4 недели. Local: ~15 час, но в узких окнах.

---

## Рекомендация

**Option B** — по слоям. Три довода:

1. Compiler-slой (W7.1, W7.2) — единственный critical-path блок для остальных. Отделив его в свой namespace, мы делаем dependency явной без введения strict sequencing.
2. Doc-слой (W7.5, W7.7) на human — правильно распределяет ownership там, где ставки peer-review. Anchor-bias эпизоды #1-3 показали: doc-слой требует slower cognition, чем cloud обычно эмитит.
3. Testing-слой (W7.3, W7.4) — там где можно parallelize и где cloud silne. Освобождается от doc-стресса, работает на compiler baseline.

**Option A** — если ssdm4 macbook активен как минимум 3 дня в неделю.
**Option C** — если writing paper §4.5 самый strict deadline и остальное вторично.

---

phi^2 + phi^-2 = 3
