# M2 loopback smoke — sandbox results 2026-07-05

> phi^2 + phi^-2 = 3

**Что запущено**: `smoke/m2_loopback_smoke.sh` — 3 узла `trios_meshd` через UDP на loopback (127.0.0.1:5011/5012/5013), stagger 100ms между стартами, duration 10 с.

**Trust class**: `-sim` (host loopback, sandbox), НЕ hardware M2 datapoint. Ничего радио-эфирного. Ничего на реальных P203 Mini. Это pre-flight sanity check daemon кода перед flash на 3 коробки.

**Reproduction**:
```bash
cargo build --bin trios_meshd --release
DURATION=10 ./smoke/m2_loopback_smoke.sh
```

## Observed behaviour

Три daemon процесса стартовали чисто, все три остались RUNNING в конце теста. HELLO периодические записи в лог каждые ~300 мс (по `HELLO_MS = 300` в `src/bin/trios_meshd.rs:26`).

**ETX table state @ 10s**:

| Node view | 11 | 12 | 13 |
|---|---|---|---|
| node 11 sees | — | inf | inf |
| node 12 sees | inf | — | 1.00 |
| node 13 sees | inf | 1.00 | — |

**Аномалия**: node-11 не слышит никого; никто не слышит node-11. **Асимметрия**.

## Root cause — sandbox-testability bug, not hardware defect

Найден в `src/bin/trios_meshd.rs:125,138,168`:

```rust
let mut ip_to_id: HashMap<IpAddr, NodeId> = HashMap::new();
...
ip_to_id.insert(addr.ip(), *pid);   // insert overwrites on IP collision
...
let from = match ip_to_id.get(&src.ip()) {  // lookup by IP only
    Some(f) => *f,
    None => continue,                        // rejects unknown IP
};
```

На loopback все три узла имеют `127.0.0.1` как source IP. `ip_to_id.insert(127.0.0.1, ...)` перезаписывает — последний peer occupies слот. Rest — silently dropped через `None => continue`.

Node-11 стартовал первым (`sleep 0.1` stagger), к моменту его `ip_to_id` build'а peers 12/13 ещё не имеют bind'а — но фиксированные `addr` в config'е указывают на 127.0.0.1:5012 и 127.0.0.1:5013, у обоих `src.ip() == 127.0.0.1`. Второй `insert` перезаписал первый. Peer-12 lookup `src.ip() == 127.0.0.1` возвращает id 13 (последняя запись), а если src port 5012 — router думает это от peer 13.

Плюс node-11 не занял слот в `ip_to_id` node-12 и node-13, потому что у них тоже коллизия — их последний insert конфликтует между 11 и 12 (для node-13) или между 12 и 13 (для node-12).

## Implication

**Hardware M2 не заблокирован**: на реальных P203 Mini каждая коробка имеет уникальный IP `10.42.0.1..3` из baked-image milestone. Проблема loopback-only.

**Sandbox testability заблокирована**: без фикса мы не можем M2 smoke в CI/sandbox между flash-циклами. Каждое изменение в daemon требует физического board flash для теста, что медленно.

## Fix — one-line change to key by SocketAddr not IpAddr

Изменить `ip_to_id: HashMap<IpAddr, NodeId>` на `addr_to_id: HashMap<SocketAddr, NodeId>` и lookup по `src` целиком, не `src.ip()`. Это будет корректно для loopback (порт различает) и корректно для hardware (у каждой P203 Mini уникальный IP и обычно фиксированный порт 5000).

Draft PR — в следующем шаге текущего плана (M2.0-M2.2 sandbox code prep).

## Что этот smoke уже доказал

1. **daemon стартует без crash** на loopback UDP transport (три instance параллельно) — release build 9.75s cold, RC=0 на всех трёх.
2. **HELLO discovery работает между двумя из трёх узлов** (12↔13 converge to ETX 1.00 — тавтологично one-hop через loopback без потерь, но это baseline).
3. **ETX table в consistent state** после ~5-10 HELLO rounds.
4. **Найдена реальная testability проблема ДО flash на hardware** — это точная цель такого pre-flight smoke.

Ни один из четырёх пунктов не требовал реального железа. Это добавляет **cargo test** уровня уверенности к M2, оставляя hardware smoke как ортогональное подтверждение.

## Log artifact

Полные логи per-node сохранены в `/tmp/m2-loopback-*/node{11,12,13}.log` (ephemeral в sandbox).

## Next steps

1. Draft PR `feat/m2-daemon-loopback-fix` — one-line изменение `ip_to_id → addr_to_id`.
2. Extended smoke script проверяющий full ETX symmetry (все три узла должны видеть остальных двух после N sec).
3. После fix — тот же harness должен показать 3×3 полную матрицу sub-2.0 ETX без inf.
4. Затем — flash на реальные board'ы (M2.0 image-bake blocker) и повторить с уникальными IP.

## Sha of binary tested

Не берётся в этот отчёт как cryptographic-grade attest (это ephemeral sandbox build), но:

```
$ sha256sum target/release/trios_meshd
```
записывается автоматически в log через harness если требуется — сейчас без него, чтобы не переусложнять runbook.

## Honesty ledger

- Всё выше — sandbox (Perplexity Computer isolated Linux VM, 2 vCPU, 8 GB RAM, x86_64), НЕ armv7l ARM.
- Ничего в этом smoke не касалось `/dev/net/tun`, реального радио, реальной P203 Mini.
- HELLO 300ms и ETX 1.00 — консистентны с loopback zero-loss, НЕ с over-the-air 5.8 GHz.
- `-sim` marker обязателен на всех цифрах из этого файла.

phi^2 + phi^-2 = 3
