# Wave Report FULL — неделя 2026-06-29 → 2026-07-05 (расширенный, все треки)

> phi^2 + phi^-2 = 3

**Кто говорит**: cloud-агент Perplexity, из sandbox. Пишу для генерала (Vasilev D.) через 7 дней после старта репозитория tri-net на GitHub, за час до pivot'а на M2-M4 hardware track.

**Скоп этого отчёта**: полная неделя (27 коммитов на main, 22 merged PR, три автора). Дополняет [WAVE_REPORT_2026-07-05.md](WAVE_REPORT_2026-07-05.md) — тот был про W5-W7 (кодогенерация, δ-paper, fuzz baseline), этот покрывает всё: hardware track (M1 hw graduation, board-1, image-bake blocker), discipline chain (PR #43/#45), W7.3 grammar-expansion (#47), §4.5.6 companion (#36 merge), competitor-watch spec (#34). Один канонический документ на неделю с образами по каждой фиче.

---

## Глава 0. Одна картина всей недели

**Образ**: ювелир, который делал одно кольцо, а на седьмой день собрал ещё три и понял, что дело было не в кольце, а в станке.

Стартовали в понедельник (07-01) с одной задачей — доказать M1 crypto на реальном железе (X25519 + ChaCha20-Poly1305 на Zynq-7020). Кончили в воскресенье (07-05) с семью артефактами, из которых M1-hw был только один — остальные шесть это инфраструктура: spec-drift-guard (3-backend byte-identity CI), 68/68 SSOT specs, W5 real-bench, W6.1 structural fuzz, W6.2 codegen audit, W7.3 grammar-expansion + три formal-review-правила (no-paste, SHA-advance, external-dep timer). Плюс DePIN pivot: репозиторий из «MANET vendor» переклонился в «reproducibility-first DePIN infrastructure».

Что произошло на самом деле: **мы потратили 5 из 7 дней на инструментальный слой** (компилятор t27c, три backend'а, differential testing, review discipline). Это **не** отклонение от M2-M4 hardware track. Это его **предусловие**. Без spec-drift-guard любой M2 патч в `wire.rs` может молча разъехаться с `specs/wire.t27`, и paper-претензия «spec-first + reproducible-HDL» становится дырявой. Без review-rules любой M2 approve может уплыть под silent SHA-swap на shared branch и человек утверждает не то, что видел.

**Дисциплинарный контекст**: три anchor-bias эпизода за неделю (Vec<> narrative, C-silently-accepts, Zig-under-any-mode) и один predicate-confusion эпизод на PR #36 (§4.5.6 companion). Все зафиксированы документально, ни один не остался в скрытом виде. Это отдельный научный результат — не про Rust/C/Zig, а про то, как static-token grep обманывает human judgement в компиляторной работе.

---

## Глава 1. Hardware track — то, что реально произошло на железе

### 1.1 M1 crypto graduation (два hw datapoint'а)

**Образ**: врач, который два раза измеряет пульс — не потому, что не верит первому измерению, а потому, что второй пациент важен сам по себе.

**Datapoint 1** ([`smoke/M1_RESULTS.md`](../smoke/M1_RESULTS.md), 2026-07-01):
- P201Mini · Zynq-7020, 2× Cortex-A9, armv7l
- Static binary `smoke-m1` 534 604 B, sha256 `e5abc335…7290a`
- Cross-built из macOS: `rustup rustc + rust-lld`, `-C target-feature=+crt-static`, target `armv7-unknown-linux-musleabihf`
- Run: X25519 handshake ✅, ChaCha20-Poly1305 AEAD round-trip ✅ (44 B pt → 79 B on-wire), tamper rejected ✅ (Auth error), replay rejected ✅ (Replay error), RC=0.

**Datapoint 2** ([`smoke/M1_BOARD1_2026-07-04.md`](../smoke/M1_BOARD1_2026-07-04.md), 2026-07-04):
- Второй P201Mini (обозначен как board-1)
- Другой binary sha256 `a17e88e6…` (перерезали после смены toolchain на rustup-stable + `-C linker=rust-lld` — Homebrew rust толкнул нас на false LLD path, откатили)
- Тот же test-set, RC=0

**Что было бы, если бы board-2 и board-3 не запустились**: image-bake blocker (см. §1.3) остановил параллельный smoke. Boards 2/3 физически присутствовали, залогинились, но identity collision (IP + hostname коллизии из-за identical Xilinx OUI MAC `00:0a:35:00:01:22`) не дал их запустить одновременно. Ложная гипотеза от 07-04: «runtime MAC-spoof через `ip link set` + `ethtool` разрулит». Реальность (5/5 paths falsified 2026-07-04): не разрулит, потому что stock rootfs — ramfs, все `/etc` изменения испаряются при cold-boot. Единственный путь вперёд — baked-image milestone.

**Научный контекст**: Zynq-7020 (Xilinx 7-series) — это классический heterogeneous SoC (dual Cortex-A9 hard-core + FPGA fabric). Мы используем только PS (processing system, ARM-часть) для M1. PL (programmable logic, FPGA) не тронут. Это — важный факт для главы 3 (FPGA-attestation): у нас на каждом узле уже есть неиспользуемая FPGA-фабрика с device-DNA (57-bit unique per die, Xilinx UG470 §32) и eFUSE-registers для non-volatile keys. См. [Xilinx UG470 — 7-Series Configuration User Guide](https://docs.amd.com/v/u/en-US/ug470_7Series_Config), device DNA описан в разделе «Device DNA and User eFUSE».

### 1.2 AD9361 5.8 GHz PHY (radio confirmation)

**Образ**: настройщик пианино, который дунул в камертон и увидел иглу вибрирующую строго на «ля»-440 — но в закрытой комнате, без публики.

Один datapoint ([`radio/README.md`](../radio/README.md), 2026-07-01):
- LO 5.8 GHz, sample rate 30.72 MHz, capture 65 536 samples
- FFT peak +0.999 MHz (target 1.0 MHz digital-loopback tone)
- SNR 108.6 dB over noise floor

**Что это значит и не значит**: 108.6 dB — это цифровая петля (TX → RX через digital loopback внутри AD9361). Это НЕ over-the-air SNR. Реальная эфирная SNR на 5.8 GHz с 20 MHz BW и типичной антенной 6 dBi будет в порядке 20-40 dB при коротких дистанциях. Разница материальная — три порядка. Мы этот факт держим в honest ledger paper §5.7, не в headline. Anchor-bias здесь был бы: цитировать 108.6 dB как «эфирную характеристику», когда это lab-bench digital-loopback число.

### 1.3 Image-bake milestone (single hard blocker для M2)

**Образ**: три одинаковых близнеца в одинаковых футболках заходят на день рождения — родственники не могут раздать разные подарки, пока близнецы не разошьют на футболках имена.

`docs/IMAGE_BAKE_MILESTONE.md` фиксирует единственный hard-blocker M2 real-network smoke:
- Все три P201/P203 Mini имеют identity-image (одинаковый MAC, hostname, IP настройки в `/etc/network/interfaces`, root SSH keys)
- Stock rootfs — ramfs → любые изменения `/etc` теряются при power-cycle
- Falsified 5/5 runtime workarounds (07-04): MAC-spoof через `ip link`, `ethtool`, dhcpcd hooks, systemd-networkd-wait-online, cloud-init none — все не переживают reboot

Единственный путь: **пересобрать rootfs с persistent identity** (baked image). Это включает:
1. Petalinux или buildroot rootfs generation
2. Уникальный MAC per-board (записать в SD-card overlay)
3. Уникальный hostname per-board
4. Static IP из подсети `10.42.0.0/24` (согласно `mesh_ip(node_id)` в `router.rs`)
5. SD-card image flash procedure (см. [`docs/LOCAL_FLASH.md`](LOCAL_FLASH.md))

Пока этого нет, любые M2 претензии — только host-only pure-logic. Что и сделал PR #32 (25 pure-logic tests) — тактическое решение: не сидеть и не ждать image-bake, а тем временем зафиксировать всю логику, которая НЕ требует TUN/UDP/радио.

### 1.4 M2 pure-logic tests ([PR #32](https://github.com/gHashTag/tri-net/pull/32))

**Образ**: скульптор, который до заливки бронзы вылепил каждый узел из воска — если восковой не держит форму, бронза точно провалится.

25 тестов в [`tests/m2_routing_pure_logic.rs`](../tests/m2_routing_pure_logic.rs) — все host-only, no `/dev/net/tun`, no UDP, no radios. Пять групп:

1. **TUN allocation math** (`mesh_ip` / `node_of` над `10.42.0.0/24`): full 1..=254 roundtrip, rejection network/broadcast, wrap на out-of-range NodeId.
2. **Wire header boundaries**: все `FrameKind` roundtrip, unknown kind byte reject, truncation at every offset, TTL extremes, `Header::LEN` pin.
3. **HELLO wire boundaries**: 33-byte empty floor, linear length scaling, max n=255, silent truncation of oversized `heard[]`, per-byte truncation reject.
4. **ETX ordering / arithmetic**: deterministic pick under identical ETX, `compute_path_etx` overflow saturation to `+inf`, NaN/inf advertised reject, `force_dead` idempotence, `neighbors()` sorted-by-id.
5. **Cross-module invariant**: HELLO body >  `Header::LEN` (нельзя confused).

**Findings, поднятые самим тестированием**:
- `is_feasible` accepts `+inf` as first metric — асимметрия, любой финитный adver instantly её shadow'ит, поэтому impact bounded, но flagged.
- `Hello::to_bytes` silently truncates `heard[]` at 255 — intentional (u8 length prefix), но caller не может знать. Кандидат на `Result<Vec<u8>, HelloTooLarge>` future revision.

**Научный контекст**: это классический defensive-testing подход [John Regehr, «It's Time for a Modern Synthesis in the Compiler Debugging Literature»](https://blog.regehr.org/) — тестировать boundaries ДО первого real integration'а. Если boundaries нестабильны в host-only, они точно нестабильны в M2 stack.

### 1.5 Три board'а физически на столе (User confirmation 2026-07-04)

**Образ**: три радиста в бункере, все три микрофона включены, но общий эфир ещё не согласован.

Три P203 Mini подключены, запитаны, все три ARM-Linux буты в norm. Board-1 прошёл M1 hw smoke. Board-2/3 — идентичные реплики + identity-collision → нужен image-bake. Это база для будущего triangle P2 DEMO GATE (M4).

---

## Глава 2. Инфраструктурный слой — тот, что мы построили за 5 из 7 дней

### 2.1 T27-first flip — что это вообще

**Образ**: раньше у нас был чертёж, нарисованный мелом на трёх разных досках; теперь одна доска — оригинал, две — фотокопии, а надзиратель проверяет каждую фотокопию побайтово.

**Было** (до понедельника): `src/wire.rs` — рукописный Rust, `specs/wire.t27` — второстепенный документ, три backend'а не существовали.

**Стало** (после `dc1bebb`): `specs/wire.t27` — SSOT (single source of truth), `t27c` компилирует его в:
- `gen/rust/wire.rs`
- `gen/c/wire.c`
- `gen/zig/wire.zig`

Все три эмиссии — byte-identical при regeneration. CI (spec-drift-guard) проверяет каждый PR, касающийся `specs/`, на предмет `gen/*/X != t27c(specs/X.t27)` — fail и PR не мержится.

**Пожалуйста, обратите внимание на слово «byte-identical»**. Это НЕ formal correctness. Это НЕ semantic equivalence between backends. Это output-stream determinism единственного codegen'а на трёх выходах. Слабейшая, но реальная форма translation validation. Ближайший научный ориентир — [Xavier Leroy, CompCert](https://xavierleroy.org/publi/compcert-CACM.pdf) — там верифицирована semantics preservation, у нас только output determinism. Мы это признаём в §4.5 paper-delta.

### 2.2 Wire flip #1 (PR #33, `77a9a49`) — первая волна

Portированный `wire.rs` → `specs/wire.t27`, добавлен `t27c gen-rust` path. Первый artifact — Rust-only, ещё без C/Zig. Первая попытка также запустила первый anchor-bias эпизод недели: initial framing «bit-shift lowering fails» → real cause «missing ExprCast in t27c parser» (найдено позже, `daeae62`, `880954e`).

### 2.3 Wire flip #2 (post-audit) — фикс через ExprCast

После `t27c` получил `Expr::Cast` node — regenerated `wire.rs` без Vec<> hack'ов. `78c29ba` — regenerate с real ExprCast lowering.

### 2.4 Spec-drift-guard v1 → v2 (PRs #35 → #38)

- **v1 (PR #35, `f126dca`)**: CI job, который на PR trigger'е делает `t27c gen-rust specs/wire.t27` и `diff gen/rust/wire.rs $(t27c ...)`. Fail → block merge. Только Rust.
- **v2 (PR #38, `dc1bebb`)**: расширили на Zig + C. Три backend'а × 68 spec'ов = 204 drift checks на push. Byte-identity enforcement.

**Важное отличие от formal verification**: spec-drift-guard не гарантирует correctness. Он гарантирует, что gen/ файлы **не разошлись** с `t27c(specs/*.t27)`. Если сам `t27c` эмиссии bogus код (что и оказалось в W6.2), drift-guard молча пропустит. Он ловит tampering в gen/, не bugs в t27c.

### 2.5 68/68 SSOT (Волна 5, batch flip)

За одну ночь (07-04→07-05): 16 commit'ов, все 68 t27-specs пропущены через `t27c` в три backend'а. Одна из самых громких headline недели.

**Reality-check** (W6.2 audit, глава 2.6): 68/68 SSOT true, но:
- 24 spec-функции имеют stub'ы **в трёх backend'ах с ТРЕМЯ разными policy of failure**:
  - Rust: `panic!("todo: X")` — runtime fail
  - Zig: `@compileError("todo: X")` — compile-time fail
  - C: `// TODO: X` + падение в undefined behavior — silent
- Симметрия 24:24:24 — это НЕ decorative. Это policy divergence под одинаковой оболочкой. То есть один spec функция ведёт себя тремя разными способами при вызове.

### 2.6 W6.2 codegen quality audit ([PR #42](https://github.com/gHashTag/tri-net/pull/42))

**Образ**: три ученика получили одну и ту же задачу, все написали работы одинакового объёма, а учитель обнаружил, что два ученика сдали пустые страницы и один — с ошибками, но всё выглядело как «100% сдали работы».

Tri-backend compile matrix ([`docs/W6_CODEGEN_AUDIT_2026-07-05.md`](W6_CODEGEN_AUDIT_2026-07-05.md)):

| Backend | OK | WARN | FAIL | Cross-env verified |
|---|---|---|---|---|
| Rust (rustc 1.93.1 --emit=metadata) | 19 | 0 | 49 | ✅ sandbox |
| C (cc -c -std=c11 -Wall -Wextra) | 2 | 66 | 68 (all fail-hard если -Werror) | ✅ sandbox |
| Zig (zig test --test-no-exec, cross-env only) | 0 | 4 | 64 | ✅ macbook ssdm4 |
| **Cross-backend OK ∩** | — | — | — | **∅ (пусто)** |

Ни один из 68 модулей не собирается **во всех трёх backend'ах**. W6.2-B (runtime differential testing) — structurally infeasible, cancelled.

**8-class defect taxonomy** (найдена аудитом):
1. Missing type declarations (E0412 Rust, unresolved import Zig)
2. Missing function declarations (E0425 Rust)
3. Vec<> unparameterised (E0107 Rust, 159 sites)
4. Missing lifetime bounds
5. Missing trait impls
6. Zig `@import` module missing
7. **NEW-CLASS discovered**: 867 `assert(cond, msg)` calls (C uses only 1-arg assert.h — Rust/Zig semantics leaked into C codegen)
8. Bit-shift semantic mismatch (mixed integer widths)

**Anchor-bias records** (все три эпизода недели):
- **Anchor #1** — «grep Vec<> = главный Rust defect»: static count 132 (5.6%), real E0425 undeclared = 2609 (93%). Static grep пропустил доминирующую ошибку в 16 раз.
- **Anchor #2** — «C silently accepts what Rust rejects»: реально C 2/68 хуже Rust 19/68, оба разделяют один корень (undeclared из t27c codegen), плюс C дополнительно ломается на 867 assert-2arg.
- **Anchor #3** — «Zig fails under any mode»: precise version — 64 hard-fail + 4 soft (lazy analysis может пропустить `@compileError` в dead function под `zig build-obj` без `--test-no-exec`), 0 pass под `zig test --test-no-exec`.

### 2.7 W7.3 grammar-directed fuzz baseline ([PR #46](https://github.com/gHashTag/tri-net/pull/46), `3272583`)

**Образ**: старый механик, который заметил, что все его тесты — на одной и той же лестнице, а надо на десяти разных.

E1 generator: рандомный корпус 1000 t27-модулей из grammar rules, каждый пропускается через `t27c` в три backend'а, затем round-trip test. Baseline: 100/100/100 pass (N=100 initial), затем N=1000, 1000/1000 pass.

**Что мерит**: acceptance under shared parser. **Что НЕ мерит**: semantic correctness — все три backend разделяют один t27c parser.

### 2.8 W7.3 grammar-expansion #1 ([PR #47](https://github.com/gHashTag/tri-net/pull/47), `fb23de5`)

**Образ**: тот же механик добавил в тесты 10-й класс лестниц, которые он раньше не тестировал.

Первый expansion: collection-typed parameters `[u32; NAMED_CONST]` через `gen_const_decls` + `NAMED_CONST_POOL` (top-10 audit names). Path-confirmation: N=1000 seed 0xC0FFEE, 100/100/0, `t27c gen-rust` на все 1000 = 1924 `[u32; NAMED_CONST]` → 1924 Vec<> exact match (dominant emission pattern сохранился).

**Диспозиция GLM**: initial BLOCKING (Zig-style syntax mismatch с corpus), revision дала MERGE APPROVED. Merged под user autonomy override («мержи сам»).

### 2.9 Paper-delta v0 (§4.5 + §4.5.6 companion, [PR #36 merged](https://github.com/gHashTag/tri-net/pull/36), `dd83ea4`)

**Образ**: художник дописал на подписи к картине «холст 1.2м × 0.8м» — цифры правильные. Потом заметил, что забыл упомянуть, что на холсте есть надрыв 3 см в углу — не отменяет цифру, но её обязательно указать рядом.

arXiv paper draft «tri-net delta» skeleton с §4.5 empirical bench matrix (spec-first + reproducible-HDL positioning) + §4.5.6 downstream compilability companion.

**§4.5.6 companion** — это ответ на predicate-confusion anchor эпизод недели: initial framing paper §4.5 «100% cross-backend agreement» технически true для §4.5.1 clean-predicate (byte-determinism из shared codegen), но **omission** — не упомянута compile-success rate из W6.2 (Rust 19/68, C 2/68, Zig 0/68, cross ∅). Не fabrication, а omission. §4.5.6 добавляет companion статистику (26 insertions, 0 deletions, все прежние claims сохранены).

Это — **Anchor #5** записан в agent memory: predicate-confusion. Разница между «применил compile-success predicate к byte-determinism claim» и «численный factivity error» — материальная. Fix через companion, а не через «correct false numbers».

### 2.10 Три formal review-правила ([PR #43](https://github.com/gHashTag/tri-net/pull/43), [PR #45](https://github.com/gHashTag/tri-net/pull/45))

**Образ**: три правила игры, все три записаны на стене над столом — можно проверить в любой момент, кто нарушил.

1. **No-paste-review rule** (PR #43): approve только против committed текста; в approval цитировать SHA. Против уплывающего draft'а approve невалиден.
2. **SHA-advance rule** (PR #45): approve связывается с cited SHA; branch advance требует explicit `Re-reviewed at <new_sha>: delta <bullet-list>`. Silent SHA-swap запрещён.
3. **External-dep timer rule** (PR #45): PR, заблокированный внешней зависимостью, должен иметь terminal-event triggers + backstop timer (default 14 дней). Не мержим и не забываем — блокируем формально с deadline.

Applied 4× total across #44/#46/#47/#36 в течение недели. Из pending state в шабашки перешли — сейчас это hard-обязательные правила.

### 2.11 Competitor-watch spec ([PR #34](https://github.com/gHashTag/tri-net/pull/34), `91a5b63`) + cron `64822c1c`

**Образ**: сторож в маяке, который каждую пятницу в 09:00 бангкокского времени включает бинокль на 5 минут, смотрит на 10 определённых кораблей + 4 научных полки, и записывает в судовой журнал только то, что достойно записи. Без событий — тишина.

Спецификация в [`docs/COMPETITOR_WATCH_SPEC.md`](COMPETITOR_WATCH_SPEC.md) — портируемый протокол:
- 10 продукт-запросов (TERASi RU1, Elistair, AT&T Flying COW, Persistent MPU5 Wave Relay, Rajant Kinetic Mesh, Doodle Labs Mesh Rider, Fraunhofer IIS UASFeed, Meshmerize 8devices, goTenna Pro X2m, World Mobile HAPS)
- 4 академических запроса (mesh routing FANET, ternary NN inference, silicon-bound DePIN, Noise protocol IoT)
- Relevance filter: 6 триггеров + exclusion list
- Source discipline: Reddit/X/LinkedIn никогда не цитируются; преследуем first-party
- Filing: draft PR на `feat/competitor-watch-<YYYY-MM-DD>`, ярлык `documentation,drone-mesh`
- Silence-on-nothing: если 0 находок — no file, no branch, no notification

Executor: cron id `64822c1c` (Fridays 02:00 UTC = 09:00 Asia/Bangkok). Ближайший запуск: 2026-07-10 (пятница).

---

## Глава 3. DePIN pivot (07-04) — стратегический сдвиг

### 3.1 Что изменилось

**Образ**: физик, который переключил PhD с квантовой оптики на quantum sensing — не потому, что оптика неинтересная, а потому, что sensing получает 10× больше грантов. Все инструменты остались те же — интерференция, лазеры, детекторы. Только позиционирование другое.

`c66d7cc` — README pivot. Раньше: «tri-net = MANET vendor для drone-mesh». Теперь: «tri-net = reproducibility-first DePIN infrastructure с mesh-radio arm'ой».

### 3.2 Четыре плеча supply-side (WAVE_DEPIN_2026-07-04.md)

Одна P203 Mini коробка = один DePIN узел с четырьмя arm'ами:

| Плечо | Что делает | proof-payload | chip sigs |
|---|---|---|---|
| Transport | mesh-relay bandwidth | (from, to, bytes, ts_start, ts_end) | 2-of-3 Phi |
| Compute | ternary edge inference (BitNet) | (model_hash, input_hash, output_hash, ops) | 3-of-3 Phi+Euler+Gamma |
| Coverage | 5.8 GHz PoC beacon challenge-response | (challenger, responder, witness, rssi, tof) | 3-of-3 cross-die φ |
| Sensor | RF spectrum atlas + GPS-jam detection | (snapshot_hash, gps_time, location_hash) | 1-of-3 any |

Все четыре оседают в `MiningPool.claimReward()` — 7 проверок, ни одна не обходится. TRI supply 3^27, 0% premine, 9 halvings 2026-2066.

### 3.3 Ключевая уязвимость pivot'а (открытый вопрос, ведёт к главе 5)

**«Compute» arm'а требует 3-of-3 Phi+Euler+Gamma sigs. Silicon TT SKY26b tape-out — 2026-12-16.** Между сегодня (07-05) и tape-out'ом ~24 недели. Плюс ~12-16 недель на bring-up и первый live BitNet-ternary benchmark. Итого ~40 недель до полноценного Compute-arm proof'а.

**Что делать 40 недель**? Здесь и появляется идея «Proof of FPGA» — использовать неиспользуемую FPGA-фабрику (Zynq-7020 PL) как interim identity/attestation source, пока silicon не приехал. Об этом — глава 5.

### 3.4 arXiv δ-paper (PR #26, `6f508db`)

**Образ**: научная работа, которая описывает не «наш продукт», а «дыру в чужих продуктах».

`docs/paper-delta-v0` — draft статьи «MANET vendor-field auditability gap»: MPU5 / Rajant / Silvus все публикуют benchmarks, но ни один не публикует SSOT-код с byte-drift CI. Tri-net этот gap закрывает (spec-drift-guard). Позиционирование: не «мы быстрее», а «мы аудируемее».

---

## Глава 4. Дисциплинарные результаты (научные, не про Rust/C/Zig)

### 4.1 Пять anchor-эпизодов недели

**Образ**: пятикратный отчёт о том, как glaza обманывают. Каждый раз мы шли в одну сторону, потом останавливались, откручивали, шли в другую.

1. **Anchor #1** (grep Vec<>): static-token grep ≠ compiler verdict. 16× underestimate.
2. **Anchor #2** (C silently accepts): оба tool показывают проблемы разных типов, root cause один и глубже обоих.
3. **Anchor #3** (Zig under any mode): overclaim в компиляторных verdict'ах — особый вид bias. «under any mode» ≠ «under mode X».
4. **Anchor #4** (corpus-scope error, PR #47): workspace-wide grep включил `../t27/specs/`, должен был `tri-net/specs/` only. Fixed at revision.
5. **Anchor #5** (predicate-confusion, PR #36): applied compile-success predicate к byte-determinism claim. Fix через companion §4.5.6, не через «correct false numbers».

**Ключевая формулировка** (это уже не про эту неделю, это на весь проект): статические indicators (grep, LOC, file count) — это **не** substitute для dynamic verdict (compiler, test suite, on-device run). Даже приближённого. И это правило применимо не только к нашему codegen'у — оно применимо к любому inference'у из static evidence в dynamic behavior.

### 4.2 Три formal rules как долгосрочный infra

- `no-paste-review` — рекурсивно применимо к любому review-workflow.
- `SHA-advance` — рекурсивно применимо к любому shared-branch flow.
- `external-dep timer` — рекурсивно применимо к любому blocking-on-upstream PR.

Все три уже applied 4× за 3 дня. Это infra не устарела через неделю.

---

## Глава 5. Что готово для следующего лупа — pivot в M2-M4 hardware + FPGA-monetization

**Что мы имеем в конце этой недели**:

- ✅ M1 crypto на реальном железе (2 board datapoints)
- ✅ 3 board'а физически подключены
- ✅ AD9361 5.8 GHz радио с digital-loopback verified
- ✅ 25 M2 pure-logic тестов (host-only, boundaries)
- ✅ 68/68 t27 SSOT + 3-backend byte-drift CI
- ✅ Три formal review-правила applied
- ✅ Bench harness с real numbers (не спекуляции)
- ✅ DePIN pivot README + four-arm whitepaper
- ✅ Competitor-watch protocol + cron
- ✅ arXiv paper draft §4.5 + §4.5.6 companion

**Что заблокировано**:

- ⛔ M2 real-network smoke — hard blocker image-bake (persistent identity)
- ⛔ M3 iperf3 over 2 hops — downstream image-bake
- ⛔ M4 triangle P2 DEMO GATE — downstream image-bake
- ⛔ M5 self-heal convergence — downstream + spec still `-sim`
- ⛔ Compute arm proof — silicon SKY26b tape-out 2026-12-16 (+24 недели)

**Открытый исследовательский вопрос** (пивот следующего лупа):

> Можно ли использовать неиспользуемую FPGA-фабрику Zynq-7020 (уже стоит на каждом узле) как **interim attestation source** для DePIN identity — до появления silicon SKY26b? Если да, это:
> - Сокращает time-to-first-DePIN-node с 40 недель до сегодня
> - Даёт цитируемое «Proof of FPGA» — новая категория PoPW
> - Открывает второй монетизационный канал: **FPGA-bitstream attestation as a service**

Ответ на этот вопрос — задача следующего Wave-лупа. См. отдельные документы:
- `docs/W7_WEAK_POINTS_STRUCTURAL.md` — что структурно слабо в текущей работе
- `docs/W7_FPGA_LITERATURE.md` — научная база (FPGA-attestation, PUFs, Proof of Physical Work)
- `docs/M2_M4_FPGA_DECOMPOSED_PLAN.md` — план на M2-M4 + FPGA-proof параллельный трек

---

## Глава 6. Reproducibility — как проверить каждое утверждение этого отчёта

Все цифры имеют либо script (reproducible в sandbox), либо PR (linked SHA), либо cross-env marker (macbook ssdm4 zig).

| Цифра | Метод | Reproducibility |
|---|---|---|
| M1 binary size 534604 B | `ls -la target/armv7-unknown-linux-musleabihf/release/smoke-m1` | На host после `cargo build --release --target=...` |
| M1 sha256 e5abc335…7290a | `sha256sum` on device 2026-07-01 | one-time datapoint |
| M1 board-1 sha256 a17e88e6… | `sha256sum` on board-1 2026-07-04 | one-time datapoint |
| AD9361 SNR 108.6 dB | `radio/README.md` script | Digital loopback, `capture_65536_samples.py` |
| Rust 19/68 OK | `bash scripts/audit/rust_compile_sweep.sh` | sandbox verified |
| C 2/68 OK | `bash scripts/audit/c_compile_sweep.sh` | sandbox verified |
| Zig 0/68 empirical | `zig test --test-no-exec` | cross-env (macbook ssdm4, zig 0.15.2) |
| W5 bench 1.2μs / 8% CoV | `cargo bench --package wire` | sandbox verified |
| W7.3 fuzz 1000/1000 | `python scripts/fuzz/run_fuzz.py --n 1000 --seed 0xF1F1F1F1` | sandbox verified |
| W7.3 expansion 1924 Vec<> | see PR #47 path-confirmation section | sandbox verified |
| 68/68 SSOT | spec-drift-guard CI on every PR | CI verified per-PR |
| Applied review rules 4× | grep merged PR bodies for `Reviewed at <SHA>:` | GitHub API |

---

## Глава 7. Одна фраза для нового читателя

> Мы за неделю превратили одну недоказанную crypto-функцию в семь bedrock артефактов (M1-hw × 2, 3-backend byte-drift CI, 68 SSOT specs, W5 bench, W6.1 fuzz, W6.2 codegen audit, W7.3 grammar-expansion + 3 review-rules), закрыли **пять** anchor-bias эпизодов документально, сделали DePIN pivot и открыли новый исследовательский вопрос — «Proof of FPGA как interim до silicon SKY26b». Плюс cron для weekly competitor-watch. Хардварная стена — image-bake milestone; ломается на следующем лупе.

phi^2 + phi^-2 = 3
