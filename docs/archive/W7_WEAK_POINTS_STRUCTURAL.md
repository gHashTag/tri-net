# W7 — структурный аудит слабых мест Tri-Net DePIN

> phi^2 + phi^-2 = 3

Дата: 2026-07-05. Роль: критический peer-reviewer, внешний по отношению к команде.
Скоуп: только СТРУКТУРНЫЕ риски — архитектура, зависимости, экономика, регуляторика,
bus factor. Языковые/anchor-bias проблемы уже задокументированы отдельно
([`docs/W6_WEAK_POINTS_AND_W7_PLAN.md`](https://github.com/gHashTag/tri-net/blob/main/docs/W6_WEAK_POINTS_AND_W7_PLAN.md),
[`docs/W6_CODEGEN_AUDIT_2026-07-05.md`](https://github.com/gHashTag/tri-net/blob/main/docs/W6_CODEGEN_AUDIT_2026-07-05.md))
и здесь не повторяются.

Метод: каждое утверждение проверено по файлу в репозитории `gHashTag/tri-net`
(branch `main` @ `dd83ea4`) или по номеру PR. Где подтверждения нет — сказано прямо.

---

## Резюме на одну фразу

Проект честно документирует собственную слабость лучше, чем большинство стартапов
документируют свою силу, — но честность аудита не отменяет того, что **пять из
восьми найденных проблем — это hard-блокеры, которые не решаются кодом**, а решаются
деньгами, юристами и человеко-часами, которых пока не видно в плане.

---

## Находка 1 — Timeline risk: весь compute-arm висит на одной дате в календаре

**Severity: CRITICAL**

Tape-out TT SKY26b Trinity назначен на 2026-12-16 — это `projected`, не `hw`
([README.md:26](https://github.com/gHashTag/tri-net/blob/main/README.md)). Между
сегодня (2026-07-05) и tape-out — более 5 месяцев, и это ещё не «кремний на столе»,
а «кремний ушёл в фаб». Между tape-out и «returned silicon» на реальных ASIC-проектах
обычно ещё 8-16 недель. `docs/AGENT_ONBOARDING.md:198` фиксирует прямо: «4 dies
SKY26b — submitted, returned silicon отсутствует. Никогда не заявляй returned без
пруфа» — то есть команда сама признаёт, что резервный сценарий «а что если кремний
задержится» нигде не прописан в виде дат/чисел.

Roadmap (`README.md:167`) вставляет весь compute-anchor arm в один пункт P6 —
«Trinity silicon back → BitNet benchmark → `[Open conjecture]` закрывается» — без
промежуточных milestone'ов на случай трёхмесячной, полугодовой или годовой задержки.
Единственная явная страховка найдена в `docs/BENCHMARK_VS_MANET_2026-07-04.md`
(шкала M7 «Silicon-anchor score»): уровень 3 — «FPGA bitstream anchor + signed
measurement», уровень 2 — «TPM/secure-element attestation», против уровня 5 —
«custom ASIC returned + on-chain verifier». Это ХОРОШАЯ рамка, но она существует
только как **система оценки конкурентов**, а не как **план перехода собственного
проекта** с уровня 2/3 на уровень 5. Ни один документ не говорит: «если 2026-12-16
проходит без tape-out, мы автоматически остаёмся на FPGA-anchor N месяцев, вот
экономические последствия».

**Evidence:** [`README.md:26,167`](https://github.com/gHashTag/tri-net/blob/main/README.md); [`docs/AGENT_ONBOARDING.md:198`](https://github.com/gHashTag/tri-net/blob/main/docs/AGENT_ONBOARDING.md); [`docs/BENCHMARK_VS_MANET_2026-07-04.md` §M7](https://github.com/gHashTag/tri-net/blob/main/docs/BENCHMARK_VS_MANET_2026-07-04.md).

**Митигация:** зафиксировать в отдельном документе (`docs/SILICON_SLIP_CONTINGENCY.md`)
три явных сценария — slip 3/6/12 месяцев — с указанием, какой arm остаётся на
FPGA-bitstream-anchor (уровень 3 по своей же шкале M7) на каждый период, и что это
значит для эмиссии токена (см. находку 7). Без этого документа единственный сигнал
рынку — «увидим 16 декабря» — это не план, это ставка.

---

## Находка 2 — Compute proof arm заблокирован полностью, softfallback не описан

**Severity: CRITICAL**

Whitepaper-таблица в `README.md:51` требует для Compute arm **3-of-3 Phi+Euler+Gamma
sigs** — то есть подписи трёх *разных* кристаллов Trinity. Ни один из них ещё не
существует в железе (`README.md:26`, «projected»). README сам констатирует это в
строке 70: «Compute proof требует silicon back» — это прямое признание, что данный
arm при текущей архитектуре **не может выдавать proof вообще**, ни в каком
software-signed режиме, в отличие от Transport/Coverage/Sensor, которые по
`README.md:67-70` уже могут работать «software-signed level».

Разрыв между «software-signed» и «silicon-signed» с точки зрения sybil resistance —
конкретный и большой: software-подпись проверяет, что *какой-то* приватный ключ
подписал сообщение; она не проверяет, что подписант — уникальный физический чип,
которого нельзя виртуализировать/склонировать N раз на одном сервере. Именно
поэтому `MiningPool.claimReward()` в `README.md:112` требует «unique PUF» и
«φ-anchor 0x47C0 cross-die» отдельными строками — команда явно понимает разницу,
но нигде не описан промежуточный механизм (например, TPM/HSM-based
attestation — уровень 2 по собственной шкале M7 из
`docs/BENCHMARK_VS_MANET_2026-07-04.md`), который позволил бы Compute arm выдавать
хоть какой-то proof до кремния, пусть с более слабой sybil-гарантией.

**Evidence:** [`README.md:51,67-70,112`](https://github.com/gHashTag/tri-net/blob/main/README.md).

**Митигация:** явно объявить Compute arm «disabled by design pre-silicon» (не
пытаться обойти это программной заглушкой — README и так формулирует принцип «No
chip, no TRI» правильно), но добавить TPM/HSM-based interim attestation как
*опциональный, помеченный ниже-уровня-безопасности* путь, если экономика без
Compute-arm окажется нежизнеспособной за 6 месяцев ожидания (см. находку 7).

---

## Находка 3 — 3-node triangle не может продемонстрировать содержательный self-heal

**Severity: MAJOR**

Математика тут элементарная, и сама команда её частично видит: `docs/STRENGTHEN.md:23`
формулирует «Triangle beats chain… precondition for R6 (2 next-hop candidates per
node)». Это верно **пока все три узла живы**. В момент, когда один узел или одна
связь падает, треугольник с 3 вершинами вырождается в прямую линию из 2 оставшихся
узлов — единственный путь между ними один, никакого «выбора маршрута» нет физически.
"Self-healing" в интересном смысле (система выбирает ДРУГОЙ путь в обход отказа)
на 3 узлах продемонстрировать нельзя — можно продемонстрировать только «обнаружение
отказа + переключение на единственный оставшийся линк», что является detection
latency, а не rerouting.

`README.md:23` и `README.md:162` формулируют M4 (P2 DEMO GATE) именно как
«3-node triangle, shared uplink», и M5 как «self-healing convergence measured» —
но при всего 3 узлах M5 способен измерить только время до переключения на
единственно возможный оставшийся линк, не качество выбора между альтернативами.
Тесты в [`tests/m2_routing_pure_logic.rs:251`](https://github.com/gHashTag/tri-net/blob/main/tests/m2_routing_pure_logic.rs)
сами это признают комментарием «3-node mesh can validate it» — в контексте
ограниченной проверки, не полноценного path-diversity сценария.

**Evidence:** [`README.md:23,162`](https://github.com/gHashTag/tri-net/blob/main/README.md); [`docs/STRENGTHEN.md:23`](https://github.com/gHashTag/tri-net/blob/main/docs/STRENGTHEN.md); [`tests/m2_routing_pure_logic.rs:251`](https://github.com/gHashTag/tri-net/blob/main/tests/m2_routing_pure_logic.rs).

**Митигация:** либо (a) переименовать M4/M5 честно — «single-failover convergence
demo», не «self-healing» — пока стенд из 3 узлов, либо (b) добавить 4-й/5-й узел
к P2 DEMO GATE как обязательное условие для заявления «self-heal» в
маркетинговых/научных материалах. Вариант (b) дороже (ещё 1-2 платы Zynq), но это
единственный способ показать реальный path-diversity choice.

---

## Находка 4 — codegen intersection = ∅: реформулировка «determinism под общим парсером» закрывает claim, но не отменяет архитектурный вопрос «зачем три бэкенда»

**Severity: MAJOR**

Матрица из [`docs/W6_CODEGEN_AUDIT_2026-07-05.md`](https://github.com/gHashTag/tri-net/blob/main/docs/W6_CODEGEN_AUDIT_2026-07-05.md)
(Rust 19/68, C 2/68, Zig 0/68, cross-backend ∩ = ∅, PR #42) и reality-check #4 в
[`docs/WAVE_REPORT_2026-07-05.md:73`](https://github.com/gHashTag/tri-net/blob/main/docs/WAVE_REPORT_2026-07-05.md)
корректно снимают claim «независимость через избыточность» — это была
переоценка, и её честно откатили. Но реформулировка «determinism под общим
парсером» ([`docs/W6_WEAK_POINTS_AND_W7_PLAN.md:13`](https://github.com/gHashTag/tri-net/blob/main/docs/W6_WEAK_POINTS_AND_W7_PLAN.md))
сама по себе не отвечает на структурный вопрос: **если три бэкенда не являются
независимыми oracles друг для друга (общий front-end `t27c`), а ни один модуль не
компилируется во всех трёх — какую практическую ценность несёт сама по себе
tri-backend архитектура прямо сейчас**, кроме будущего опциона? [`PAPER_DELTA_v0.md:230`](https://github.com/gHashTag/tri-net/blob/main/docs/PAPER_DELTA_v0.md)
сам формулирует это честно: «byte-determinism… much weaker property today than…
downstream compilability» — то есть авторы признают, что нынешняя ценность —
это гарантия воспроизводимости *вывода генератора*, а не гарантия работоспособности
кода. Пока это так, «tri-backend» как маркетинговый и архитектурный тезис не имеет
эмпирической опоры — только опору «когда-нибудь заработает».

**Evidence:** [`docs/W6_CODEGEN_AUDIT_2026-07-05.md`](https://github.com/gHashTag/tri-net/blob/main/docs/W6_CODEGEN_AUDIT_2026-07-05.md) (таблица + PR #42); [`docs/PAPER_DELTA_v0.md:230,251,253`](https://github.com/gHashTag/tri-net/blob/main/docs/PAPER_DELTA_v0.md).

**Митигация:** не отказываться от tri-backend, но явно установить измеримый gate —
например «минимум 1 модуль (`wire`) компилируется во всех трёх backend'ах к дате X»
(в PR #44 уже идёт investigation E0425 root cause — «dropped let statements in t27c
Rust emitter», это правильный первый шаг) — и до достижения gate не использовать
tri-backend как argument силы проекта ни в статьях, ни в питчах.

---

## Находка 5 — 108.6 дБ SNR — это digital loopback, эфирная цифра неизвестна и не тестируема без денег/разрешения

**Severity: MAJOR**

[`radio/README.md:7-14`](https://github.com/gHashTag/tri-net/blob/main/radio/README.md)
прямым текстом: «Uses the AD9361 **internal digital loopback** so nothing is
radiated», «SNR 108.6 dB over noise floor», и раздел «Next (still greenfield)»
перечисляет **RF loopback через SMA-кабель** как ещё не сделанный шаг, не говоря
уже об открытом эфире. 108.6 дБ — это, по сути, SNR внутренней цифровой петли ЦАП→АЦП
без единого метра пространства, без атмосферного затухания, без интерференции,
без реального фронтенда. Экстраполировать эту цифру на «5.8 GHz mesh работает» —
логическая ошибка того же типа, что уже зафиксирована как anchor-bias #1-3 в
[`docs/W6_CODEGEN_AUDIT_2026-07-05.md`](https://github.com/gHashTag/tri-net/blob/main/docs/W6_CODEGEN_AUDIT_2026-07-05.md),
только в радио-домене, а не в кодогене.

Честная эфирная оценка уже частично посчитана в [`docs/STRENGTHEN.md`](https://github.com/gHashTag/tri-net/blob/main/docs/STRENGTHEN.md)
(строка P8): «FSPL 108 dB@1 km / 128 dB@10 km; sensitivity ~−93.8 dBm (BPSK½)» —
то есть на 1 км при слабом бортовом PA (10-15 dBm) link budget уже close to the
edge, задолго до учёта fading, multipath, doppler от дрона. Это не то же самое,
что «SNR 108.6 dB», и путать эти две цифры в публичной коммуникации — прямой
путь повторить anchor-bias.

**Evidence:** [`radio/README.md:7-14,26-29`](https://github.com/gHashTag/tri-net/blob/main/radio/README.md); [`docs/STRENGTHEN.md` P8](https://github.com/gHashTag/tri-net/blob/main/docs/STRENGTHEN.md); [`README.md:19,91-93`](https://github.com/gHashTag/tri-net/blob/main/README.md).

**Митигация:** везде, где 108.6 дБ фигурирует в публичных материалах (README,
paper draft), рядом ставить явный disclaimer «digital loopback only, not
over-the-air» — это уже частично сделано в README таблице статуса, но не в
Metrics-таблице (`README.md:92`), где цифра стоит голой. Плюс: SMA-кабель + аттенюатор
RF loopback (уже запланирован в `LOCAL_FLASH.md` §9.3) — следующий обязательный шаг
до любых заявлений про «5.8 GHz mesh», и он тестируем без FCC/regulatory allowance
(замкнутая цепь, ничего не излучается).

---

## Находка 6 — регуляторная экспозиция 5.8 GHz: Таиланд уже явно закрыт для OTA, но это не выделено как отдельный, самостоятельный блокер верхнего уровня

**Severity: MAJOR**

Хорошая новость: команда это знает и написала прямым текстом —
[`docs/WAVE_REPORT_2026-07-03.md:145`](https://github.com/gHashTag/tri-net/blob/main/docs/WAVE_REPORT_2026-07-03.md):
«Cannot run 5.8 GHz OTA in Thailand — regulatory; keep the UDP transport for dev».
[`docs/LOCAL_FLASH.md:413`](https://github.com/gHashTag/tri-net/blob/main/docs/LOCAL_FLASH.md)
уточняет: «Внешний PA+LNA + разрешение — только после юридической подготовки
(ADGM/DIFC или локальный test license). До этого — все RF-эксперименты внутри
лаборатории на SMA/loopback». `docs/STRENGTHEN.md` (P8, строка «BVLOS / spectrum
regulatory») формулирует лимит «≤100 mW (TH/SG) licensed-by-rule ceiling» для
свободного полёта.

Плохая новость: эта информация разбросана по трём разным doc'ам второго уровня
(wave report, local flash checklist, strengthen backlog) и нигде не собрана в один
«regulatory go/no-go» документ верхнего уровня рядом с README hardware-матрицей.
Пользователь базируется в Пхукете (Таиланд) — то есть основной физический адрес
разработки находится в юрисдикции, где OTA-излучение на 5.8 GHz для mesh уже
прямо запрещено без лицензии, и путь к легальному тестированию идёт либо через
ADGM/DIFC (UAE, см. `docs/LOCAL_FLASH.md:413` и Hub71 заявку в `README.md:169`),
либо через локальный test license, которых в репозитории нет ни одной ссылки/статуса.
Это значит, что весь путь от «digital loopback подтверждён» до «5.8 GHz mesh
летает» физически не может продвинуться дальше SMA-кабеля до появления
регуляторного разрешения — и этого разрешения сейчас нет ни в одной юрисдикции,
где команда имеет физическое присутствие.

**Evidence:** [`docs/WAVE_REPORT_2026-07-03.md:145`](https://github.com/gHashTag/tri-net/blob/main/docs/WAVE_REPORT_2026-07-03.md); [`docs/LOCAL_FLASH.md:413`](https://github.com/gHashTag/tri-net/blob/main/docs/LOCAL_FLASH.md); [`docs/STRENGTHEN.md` P8 / BVLOS row](https://github.com/gHashTag/tri-net/blob/main/docs/STRENGTHEN.md); [`README.md:169`](https://github.com/gHashTag/tri-net/blob/main/README.md) (Hub71 UAE ADGM/DIFC track).

**Митигация:** свести всё регуляторное знание в один `docs/REGULATORY_STATUS.md`
с таблицей «юрисдикция × статус (закрыто/тест-лицензия в процессе/чисто) × дата
следующего шага», и явно пометить его в README рядом с hardware-матрицей — этот
риск того же порядка важности, что и tape-out дата, но сейчас видим только по
фрагментам в трёх разных файлах.

---

## Находка 7 — экономическая модель токена: кто платит за первые 6+ месяцев без кремния, ответа нет

**Severity: CRITICAL**

Токеномика в [`README.md:99-112`](https://github.com/gHashTag/tri-net/blob/main/README.md):
supply 3²⁷ = 7 625 597 484 987, 0% premine, 0% VC, 0% treasury, 9 халвингов
2026-2066, Era 0 (2026-2030) reward 1000 TRI/proof. Модель «честная» в смысле
отсутствия инсайдерского распределения — но именно из-за 0% premine/treasury у
проекта **нет собственного капитала для субсидирования раннего предложения**.
Compute arm заблокирован до кремния (находка 2), Transport/Coverage/Sensor arms
пока software-signed и, по логике находки 2, имеют более слабую sybil-защиту —
то есть именно в этот переходный период (минимум до 2026-12-16, реалистично
дольше) экономика максимально уязвима к тому, что либо (a) слабый спрос на
проверку (нет операторов, нет смысла майнить) либо (b) слабая sybil-защита
делает software-signed арки лёгкой мишенью для фарма.

Мы искали в репозитории сравнение с моделью Helium — прямым текстом её нет ни в
одном файле (`docs/BENCHMARK_VS_MANET_2026-07-04.md`, `docs/PAPER_DELTA_v0.md`,
`docs/_recon/*`, README — во всех grep по «Helium»/«hotspot»/«subsidy» дал
только косвенные структурные аналогии в позиционировании README: «DePIN-узел
(Helium-style + edge compute)», [README.md:42](https://github.com/gHashTag/tri-net/blob/main/README.md)).
То есть Helium упомянут как референс модели ("Helium-style"), но **экономический
механизм** Helium — hotspot-производитель (Nova Labs) продавал субсидированное
железо и авансировал HNT под сделки с производителями — нигде не разобран и не
адаптирован. У Tri-Net нет аналога Nova Labs: нет производителя железа, который
взял бы на себя субсидию P203 Mini плат в обмен на будущую эмиссию, и нет
раздела treasury/VC, откуда можно было бы профинансировать subsidy-программу
самостоятельно. Формально это архитектурно чистая позиция («честный старт»), но
практически это означает, что единственный источник капитала на 3 платы сейчас —
личные средства/время фаундера, что не масштабируется на следующие 10-100 узлов
без внешнего финансирования, для которого структура 0% premine/VC/treasury прямо
закрывает стандартный путь (нечего продать инвестору).

**Evidence:** [`README.md:42,99-112`](https://github.com/gHashTag/tri-net/blob/main/README.md); отсутствие Helium-subsidy разбора подтверждено отсутствием совпадений по `grep -i helium/hotspot/subsidy` в `docs/BENCHMARK_VS_MANET_2026-07-04.md`, `docs/PAPER_DELTA_v0.md`, `docs/_recon/`.

**Митигация:** явно решить и задокументировать (не обязательно нарушая
0%-premine принцип): (a) grant/hackathon-путь — Hub71+ AI Cohort 20 заявка
(`README.md:169`, дедлайн 2026-08-02) уже является частичным ответом, но нужно
явно прописать, что произойдёт, если грант не будет получен; (b) явный,
опубликованный «bootstrap operator program» — например, first-N-operators получают
повышенный Era-0 reward multiplier без нарушения 0% premine (эмиссия всё ещё идёт
через proof, просто curve скошена в начале) — это ближе к духу проекта, чем
Helium's equity-based subsidy, и стоит явно так и сформулировать вместо тишины.

---

## Находка 8 — bus factor: один человек держит физическое железо, мерж-права и юридические решения

**Severity: MAJOR**

`git log` по репозиторию за неделю 06-29→07-05 показывает 3 разных author-имени:
`Vasilev Dmitrii` (20 коммитов), `Perplexity Computer` (5 коммитов, cloud-агент),
`gHashTag` (2 коммита, вероятно локальный macOS-агент под тем же человеком).
Формально «три автора», но фактически — **один человек** (Dmitrii Vasilev /
gHashTag), плюс два AI-агента, которые действуют строго под его надзором. Это
прямо подтверждается собственными правилами онбординга:
[`docs/AGENT_ONBOARDING.md:188-190`](https://github.com/gHashTag/tri-net/blob/main/docs/AGENT_ONBOARDING.md)
— «Не флеши железо... human-only», «Не мержь PR — human-only», и
[`docs/BENCHMARK_VS_MANET_2026-07-04.md` §6](https://github.com/gHashTag/tri-net/blob/main/docs/BENCHMARK_VS_MANET_2026-07-04.md)
— «Cannot flash Zynq… needs Vivado + physical cable», «Cannot procure PA/LNA…
needs a human with a budget», «Cannot merge PRs — human-only per repo policy».

Это значит: **все hardware-операции, все юридические/регуляторные решения и
единственная точка мержа PR завязаны на одного физического человека**. AI-агенты
могут писать код, тесты, документацию и открывать draft PR — но ни один из
22 PR за неделю не может попасть в `main` без ручного merge этим человеком, и
ни одна из трёх плат не может быть перепрошита без его физического присутствия
с JTAG-кабелем. Если этот человек станет недоступен (болезнь, форс-мажор, смена
приоритетов) — репозиторий продолжит накапливать draft PR (сейчас их уже 8 в
статусе DRAFT по данным `gh pr list`), но ни один не будет смержен, и ни одна
физическая операция с платами не продолжится.

Проверка onboarding-скорости для нового человека: `docs/AGENT_ONBOARDING.md`
(286 строк) написан для AI-агента, а не для человека-контрибьютора — весь его
контент про git push proxy, mbox handoff, agent-to-agent coordination protocol.
Не найдено ни одного `CONTRIBUTING.md` файла в репозитории (проверено —
отсутствует). Человеку с улицы, который хочет контрибьютить в код (`src/`,
`specs/*.t27`), негде за 10 минут прочитать «как собрать, как тестировать, как
предложить PR» — придётся реконструировать это из README + AGENT_ONBOARDING.md +
AUTONOMOUS.md.

**Evidence:** `git log --since="2026-06-29" --pretty=format:"%an"` (3 имени, де-факто 1 человек); [`docs/AGENT_ONBOARDING.md:188-190`](https://github.com/gHashTag/tri-net/blob/main/docs/AGENT_ONBOARDING.md); [`docs/BENCHMARK_VS_MANET_2026-07-04.md` §6 «Boundary»](https://github.com/gHashTag/tri-net/blob/main/docs/BENCHMARK_VS_MANET_2026-07-04.md); `gh pr list` (8 open draft PRs на момент аудита); отсутствие `CONTRIBUTING.md` в дереве репозитория.

**Митигация:** (1) написать отдельный `CONTRIBUTING.md` для человеческих
контрибьюторов (не агентов) — сборка, тесты, code style, PR-процесс, 15-минутный
quick-start; (2) делегировать хотя бы merge-права на docs-only PR (не тронущие
`src/`, `specs/`, hardware) второму доверенному человеку, оставив hardware/`main`-critical
merge за собой; (3) явно записать в issue tracker процедуру «если Dmitrii
недоступен N дней — что происходит с открытыми draft PR» — сейчас такой записи нет.

---

## Что УЖЕ сильно — не трогать

1. **Честная маркировка `-sim` / `hw` по всей кодовой базе.** [`README.md`](https://github.com/gHashTag/tri-net/blob/main/README.md)
   статус-таблица и [`smoke/M1_RESULTS.md`](https://github.com/gHashTag/tri-net/blob/main/smoke/M1_RESULTS.md)
   держат жёсткую дисциплину: ни одна непроверенная цифра не выдаётся за
   аппаратный факт. Это структурная защита от собственного anchor-bias, и три
   зафиксированных anchor-эпизода в [`docs/W6_CODEGEN_AUDIT_2026-07-05.md`](https://github.com/gHashTag/tri-net/blob/main/docs/W6_CODEGEN_AUDIT_2026-07-05.md)
   были пойманы именно благодаря этой дисциплине, а не вопреки ей.

2. **spec-drift-guard CI (68×3 = 204 byte-identity checks).** [PR #38](https://github.com/gHashTag/tri-net/pull/38)
   и его расширение — реальный, работающий, воспроизводимый механизм translation
   validation, пусть и слабее полной формальной верификации. Это редкий случай,
   когда claim в W6.2-аудите «слабейшая, но реальная форма translation validation»
   абсолютно точен и не подлежит пересмотру.

3. **Self-errata культура.** [`docs/W6_CODEGEN_AUDIT_2026-07-05.md`](https://github.com/gHashTag/tri-net/blob/main/docs/W6_CODEGEN_AUDIT_2026-07-05.md)
   §«Anchor-bias record» и [`docs/WAVE_REPORT_2026-07-05.md`](https://github.com/gHashTag/tri-net/blob/main/docs/WAVE_REPORT_2026-07-05.md)
   Часть 4 «Что не переживёт» — команда сама отменяет свои headline-claims, когда
   находит контрдоказательства (`Vec<>` narrative, «C silently accepts», «under
   any Zig mode»). Такая структурная привычка редка и должна быть сохранена как
   процесс, а не как разовая акция.

4. **M1 крипто-ядро на реальном железе с воспроизводимым хешем.** [`smoke/M1_RESULTS.md`](https://github.com/gHashTag/tri-net/blob/main/smoke/M1_RESULTS.md) —
   два независимых прогона (2026-07-01, 2026-07-04) на разных платах, оба с
   sha256 бинарника и RC=0 в логе. Это настоящий hardware-evidence, не
   декларация, и единственный пункт всей дорожной карты, который уже прошёл
   путь от идеи до `hw`-статуса полностью.

5. **Признание собственных архитектурных пределов вместо их сокрытия.** Пример —
   [`docs/PAPER_DELTA_v0.md:230,253`](https://github.com/gHashTag/tri-net/blob/main/docs/PAPER_DELTA_v0.md):
   «byte-determinism… much weaker property today than downstream compilability»
   написано в тексте, который идёт в академический препринт, а не спрятано в
   internal notes. Это выше стандартной практики большинства DePIN-питчей на
   рынке.

---

phi^2 + phi^-2 = 3
