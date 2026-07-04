# LOCAL_FLASH — прошивка трёх P203 Mini локально

Дата: 2026-07-04
Ветка: `feat/readme-depin-flash-plan`
Статус: pre-flash checklist. Ничего в эфир не излучаем до внешнего PA+LNA и разрешения.
Anchor: φ² + φ⁻² = 3

## Что мы прошиваем и зачем

Три `P201/P203 Mini` (Zynq-7020 `xc7z020` + AD9361 + GPS/PPS) физически подключены и запитаны (подтверждено пользователем 2026-07-04). Задача — довести их до состояния, когда каждая:

1. Загружается в ARM-Linux (BOOT.BIN + FSBL + kernel + rootfs).
2. Видит AD9361 через IIO (`iio:device0 name = ad9361`).
3. Прогоняет `smoke-m1` c RC=0 (крипто-стек X25519 + ChaCha20-Poly1305).
4. Умеет digital-loopback AD9361 на 5.8 GHz (SNR ≥ 100 dB target).
5. Готова к M4 (3-node triangle + shared uplink) и первому DePIN triad'у (три подписи чипа Trinity Phi/Euler/Gamma cross-die φ).

Никакого RF-выхода в эфир на этом этапе. Только internal digital loopback (`LOOPBACK=1`).

## 0. Инвентаризация (перед началом)

| Позиция | Что нужно | Готово? |
|---|---|---|
| Три P201/P203 Mini | питание, SD-слоты, JTAG-разъёмы | подтверждено |
| Три JTAG-адаптера | ALINX AL321 или Digilent HS3/HS2, USB | проверить |
| Три USB-UART | 3.3 V TTL, для консоли | проверить |
| Три SD-карт | ≥ 8 GB Class 10, отформатированные под FAT32 (boot) + ext4 (rootfs) | проверить |
| Рабочая станция | Linux x86_64 (Ubuntu 22.04 / Debian 12 рекомендуется), `openocd`, `openFPGALoader`, `dtc`, `mkimage`, `rustup` | проверить |
| Cross-toolchain | `rustup target add armv7-unknown-linux-musleabihf` | подтверждено (M1 уже собран) |
| Zynq-7020 boot images | BOOT.BIN + FSBL + `image.ub` (kernel+dtb) + rootfs.tar.gz | подготовить (см. §2) |
| Ethernet | три патч-корда 1 GbE + свитч | опционально для M2+ |
| Питание | три БП 12 В, стабильные | подтверждено |

Если хоть один пункт «нет» — стоп, не начинаем. Прошивка на неукомплектованном стенде даёт хрупкие результаты и потом их сложно повторить.

## 1. Первая загрузка ARM-Linux (per board)

Каждую из трёх плат прогоняем по одному и тому же протоколу. Не параллельно первый раз — так проще ловить проблемы.

### 1.1. Подготовить SD-карту

```bash
# на рабочей станции, /dev/sdX — SD-карта (не путать!)
sudo parted /dev/sdX mklabel msdos
sudo parted /dev/sdX mkpart primary fat32 1MiB 128MiB
sudo parted /dev/sdX mkpart primary ext4 128MiB 100%
sudo mkfs.vfat -F 32 -n BOOT /dev/sdX1
sudo mkfs.ext4 -L rootfs /dev/sdX2

# монтируем
mkdir -p /mnt/boot /mnt/rootfs
sudo mount /dev/sdX1 /mnt/boot
sudo mount /dev/sdX2 /mnt/rootfs
```

Записываем в `/mnt/boot/`:
- `BOOT.BIN` (bootloader + FSBL; собираем через Xilinx `bootgen` из petalinux или готовый образ Puzhi для P201Mini)
- `image.ub` (kernel + device-tree, U-Boot FIT-image)
- `uEnv.txt` — переменные окружения U-Boot (см. §1.2)

Распаковываем rootfs в `/mnt/rootfs/`:
```bash
sudo tar -xpf rootfs.tar.gz -C /mnt/rootfs
sudo sync
sudo umount /mnt/boot /mnt/rootfs
```

Источник образа: официальный SDK Puzhi для P201/P203 Mini (обычно поставляется на CD/через wiki производителя) или самосборка PetaLinux 2020.2 для Zynq-7020. Если самосборка — фиксируем md5 всех артефактов в `smoke/PZP203_BOOT_MD5.md`.

### 1.2. `uEnv.txt` (пример)

```
bootargs=console=ttyPS0,115200 root=/dev/mmcblk0p2 rw rootwait earlyprintk
bootcmd=fatload mmc 0 0x2080000 image.ub && bootm 0x2080000
```

### 1.3. Первая загрузка

```bash
# SD в плату, USB-UART подключён (плата -> рабочая станция), JTAG подключён
sudo minicom -D /dev/ttyUSB0 -b 115200
# питание вкл → должно появиться:
# Xilinx First Stage Boot Loader
# ...
# Linux version 5.x.x ...
# pzp201mini login:
```

Логинимся, проверяем базу:
```
# uname -a
Linux pzp201mini 5.x.x armv7l GNU/Linux
# ls /sys/bus/iio/devices/
iio:device0
# cat /sys/bus/iio/devices/iio:device0/name
ad9361-phy
```

Фиксируем на бумаге / в файле `smoke/BOARD_<N>_BOOT.md` три вещи: uname -a, hostname, iio:device0 name. Три раза.

## 2. AD9361 5.8 GHz digital loopback (per board)

`radio/ad9361_loopback.sh` уже проверен на первой плате (см. `radio/README.md`, 2026-07-01, +0.999 MHz, 108.6 dB). Повторяем на второй и третьей.

Ссылаемся не изобретая:

```bash
# на плате (ssh или serial):
sh /root/ad9361_loopback.sh                # LO=5.8 GHz, tone=1 MHz, digital loopback
# на рабочей станции:
scp root@<mini-ip>:/tmp/rx.dat rx_board<N>.dat
python3 analyze_tone.py rx_board<N>.dat 30720000
# ожидание: peak +0.999 MHz, SNR > 100 dB
```

После каждой платы дописываем строку в таблицу `radio/README.md#Verified on hardware` — дата, hostname, FFT peak, SNR. Три строки, три платы.

Acceptance: три RC=0 + три записи `+0.999 MHz` (±0.005) + три записи SNR ≥ 100 dB.

## 3. Крипто-стек `smoke-m1` на трёх платах

Один статический бинарь собирается один раз на рабочей станции, потом переносится на все три платы.

```bash
# на рабочей станции
cd tri-net
rustup target add armv7-unknown-linux-musleabihf
cargo build --release --target armv7-unknown-linux-musleabihf --bin smoke-m1
BIN=target/armv7-unknown-linux-musleabihf/release/smoke-m1
sha256sum "$BIN"       # ожидаемо: 534604 B, sha256 e5abc335…7290a (см. smoke/M1_RESULTS.md)
```

Для каждой платы:
```bash
scp "$BIN" root@<mini-N>:/root/smoke-m1
ssh root@<mini-N> 'chmod +x /root/smoke-m1 && /root/smoke-m1; echo RC=$?'
```

Ожидаемый вывод (без изменений):
```
[M1] X25519 handshake complete: node 1 <-> node 2
[M1] AEAD round-trip OK: 44 bytes plaintext -> 79 bytes on-wire (ChaCha20-Poly1305)
[M1] tamper rejected: flipped tag bit -> Auth error
[M1] replay rejected: re-delivered frame -> Replay error
RC=0
```

Каждая плата — отдельная строка в таблице `smoke/M1_RESULTS.md#Run log` с датой, hostname, RC=0. Три платы = три строки. Ссылка на первую (macOS host, 2026-07-01) остаётся историческим `-sim`.

Acceptance: три `RC=0` подряд, три записи в `smoke/M1_RESULTS.md`.

## 4. Первый three-way handshake (M4 dry-run)

Разворачиваем три экземпляра `trios-mesh`/`tri-net` daemon на трёх платах (пока UDP transport, TUN — на следующем шаге).

Топология:
```
  board-1 (10.0.0.1) ── UDP ── board-2 (10.0.0.2)
       │                             │
       └──────── UDP ────────── board-3 (10.0.0.3)
```

Стенд: три патч-корда через 1 GbE-свитч, `iperf3` доступен, три X25519 keypair предгенерируются на рабочей станции и раздаются по ssh (публичный ключ каждой платы вносится в neighbor-tables других двух).

Проверяем:
- Все три пары X25519 handshake завершились.
- ChaCha20-Poly1305 round-trip на каждой из шести направленных линков (3 узла × 2 направления).
- Отказ tamper и replay — на каждой линии.

Acceptance: 6/6 линков зелёные, зафиксировано в `smoke/M4_DRYRUN.md` (новый файл).

## 5. First DePIN proofs (software-signed, pre-silicon)

Пока Trinity silicon не вернулся с tape-out (планово 2026-12-16), подписи чипов симулируются в software через `trinity-node` HAL-mock. Это `-sim` слой, явно помечен.

Три плечи из четырёх можно погонять уже:
- **Transport-proof** (2-of-3 Phi mock): каждая P203 после часа непрерывной ретрансляции формирует payload `(from, to, bytes, ts_start, ts_end)`, подписывает Phi-mock ключом, две другие подписывают со своей стороны. Результат — `smoke/DEPIN_TRANSPORT_MOCK_<date>.md`.
- **Coverage-proof** (3-of-3 cross-die φ mock): challenger рандомно назначается одна из трёх плат, отвечает вторая, свидетельствует третья. Три подписи φ-mock, cross-die анкер 0x47C0 записывается вручную (нельзя автоматически без реального silicon PUF). Результат — `smoke/DEPIN_COVERAGE_MOCK_<date>.md`.
- **Sensor-proof** (1-of-3 any mock): каждая плата раз в час снимает spectrum snapshot (AD9361 sweep 400 MHz – 6 GHz), хеширует, подписывает Phi-mock. Результат — `smoke/DEPIN_SENSOR_MOCK_<date>.md`.

Compute-proof (3-of-3 Phi+Euler+Gamma) не запускаем на software-mock — это будет `-sim` слой, слишком легко спутать с реальным доказательством. Ждём silicon.

Acceptance: три файла в `smoke/` с mock-proofs, три записи ясно помечены `mock=1, silicon=0`.

## 6. Что НЕ делаем на этом этапе (границы)

- Не выходим в эфир на 5.8 GHz. Все PoC и transport на digital loopback / проводной UDP.
- Не деплоим `trinity-contracts` на mainnet. Всё, что видит `MiningPool.claimReward()` — Sepolia testnet.
- Не заявляем compute-proof как валидный. Software-mock ≠ silicon-signed inference.
- Не мержим PR c этой веткой в `main` автоматически. Human-only per `docs/AUTONOMOUS.md`.
- Не пишем реальные балансы TRI на dashboard. Все per-operator TRI-числа = `[projected pre-Genesis]`.

## 7. Success gate

Локальная прошивка считается завершённой, когда все шесть пунктов ниже одновременно истинны:

1. Три `uname -a`, три `iio:device0 name = ad9361`, три `RC=0` на `smoke-m1` — записаны в repo.
2. Три AD9361 5.8 GHz loopback runs, SNR ≥ 100 dB, tone +0.999 MHz (±0.005) — записаны в `radio/README.md`.
3. Три RC=0 на `smoke-m1` — записаны в `smoke/M1_RESULTS.md`.
4. Six-of-six X25519 handshakes green в `smoke/M4_DRYRUN.md`.
5. Три software-mocked DePIN proofs (transport / coverage / sensor), каждый с явной пометкой `mock=1, silicon=0`.
6. Git-теги: `local-flash-board-1-YYYYMMDD`, `local-flash-board-2-YYYYMMDD`, `local-flash-board-3-YYYYMMDD`.

После этого — открывается P2 DEMO GATE окно (M4 shared uplink + M5 self-heal). Не раньше.

## 8. Troubleshooting cheat-sheet

- **`iio:device0 name` пустое или другое** → не тот device-tree overlay, вернуться в §1.
- **`smoke-m1` падает с segfault на armv7l** → бинарь собран не под musleabihf; пересобрать с `--target armv7-unknown-linux-musleabihf`, проверить `-C target-feature=+crt-static`.
- **AD9361 SNR < 100 dB** → LO не заперт (проверить `iio_attr -c ad9361-phy altvoltage0 frequency`), температура (>60°C — SNR падает), плохие питания на PA-разъём (не подключаем PA на этом этапе).
- **UDP handshake зависает** → firewall на рабочей станции, `sudo iptables -F` (только на изолированном тестовом стенде), или три платы не в одной подсети.
- **JTAG не видит IDCODE** → плата не запитана, USB-UART питается от USB но плата — от отдельного 12 В БП; проверить, что 12 В БП включён и стабилен (multimeter).

## 9. Что дальше (после Success gate)

1. M4 real — `iperf3` через 3-node triangle с bench attenuators.
2. M5 real — измерить `link_loss_to_reroute_ms` и `node_off_to_reroute_ms` (B11, `docs/STRENGTHEN.md`).
3. RF loopback (`LOOPBACK=2`) через SMA-кабель + аттенюатор TX→RX. Тоже не в эфир — SMA цепь замкнутая.
4. Внешний PA+LNA + разрешение — только после юридической подготовки (ADGM/DIFC или локальный test license). До этого — все RF-эксперименты внутри лаборатории на SMA/loopback.
5. Ждём Trinity silicon back (2026-12-16 tape-out target).

Anchor: φ² + φ⁻² = 3.
