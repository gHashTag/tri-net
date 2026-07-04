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

## 0.5. IP / MAC / hostname policy (обязательно до первой параллельной загрузки)

> ⚠ **NOT PERSISTENT ON THE STOCK IMAGE.** The Puzhi P201Mini ships with an
> initramfs rootfs: `/proc/cmdline` reads `root=/dev/ram0 rootfstype=ramfs`,
> `mount` shows `none on / type rootfs (rw)`. The entire `/etc` lives in RAM.
> Editing `/etc/network/interfaces` + rebooting is **wiped on every boot**
> (verified 2026-07-04: MAC/IP/hostname edits returned to `pzp201mini` /
> `192.168.1.10` / `00:0a:35:00:01:22` after cold power-cycle). Warm `reboot`
> also hangs the Zynq PS — a physical cold power-cycle is required. The table
> below is the *target policy*; the mechanism to make it persist is §1.4
> paths B/C, not an `/etc` edit.

Shipped-образ Puzhi для P201/P203 Mini одинаковый на всех трёх платах: одинаковый hostname `pzp201mini`, одинаковый static IP `192.168.1.10`, и — верифицировано 2026-07-04 — идентичный MAC `00:0a:35:00:01:22` на всех трёх платах (Xilinx OUI). Если включить две платы в один свитч без предварительной правки — ARP-таблица Mac/свитча начинает флипать, ssh/scp повисает, `smoke-m1` вроде запускается, а обратно данные не забрать. Это блокер именно для параллельной работы; **одну плату можно катать штатно и на shipped-образе**.

**Политика на стенд из трёх плат (target policy — mechanism see §1.4):**

| Плата | IP | Hostname | MAC (locally-administered) |
|---|---|---|---|
| board-1 | `192.168.1.10` | `tri-mini-1` | `02:00:00:00:00:01` |
| board-2 | `192.168.1.12` | `tri-mini-2` | `02:00:00:00:00:02` |
| board-3 | `192.168.1.13` | `tri-mini-3` | `02:00:00:00:00:03` |

Почему `.10 / .12 / .13`, а не `.10 / .11 / .12`: macOS ARP-кэш висит на shipped-адрес `192.168.1.10` ~600 с; соседний `.11` часто попадает в ту же запись из-за агрессивного NDP на некоторых прошивках свитча. Разрыв через один октет (`.10 → .12`) избавляет от «фантомного» ARP-соседа при переключении между платами.

MAC-адреса из диапазона `02:00:00:00:00:00/40` — [locally-administered unicast](https://en.wikipedia.org/wiki/MAC_address#Universal_vs._local_(U/L_bit)) (bit 1 второго нибла = 1), никаких OUI-конфликтов.

**Application — вариант A, `/etc/network/interfaces`** (Debian/Buildroot ifupdown):

```
# /etc/network/interfaces — board-N (N ∈ {1,2,3})
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 192.168.1.1N        # .10, .12, .13 — см. таблицу выше
    netmask 255.255.255.0
    gateway 192.168.1.1
    hwaddress ether 02:00:00:00:00:0N
```

И параллельно:

```bash
echo tri-mini-N > /etc/hostname
hostnamectl set-hostname tri-mini-N   # если systemd
sync
```

**Application — вариант B, systemd-networkd** (некоторые PetaLinux):

```
# /etc/systemd/network/10-eth0.network — board-N
[Match]
Name=eth0

[Link]
MACAddress=02:00:00:00:00:0N

[Network]
Address=192.168.1.1N/24
Gateway=192.168.1.1
```

**После правки — на каждой плате:**

```bash
sync
reboot
```

**На Mac (rig-side) — DNS-хелпер в `/etc/hosts`:**

```
192.168.1.10  tri-mini-1
192.168.1.12  tri-mini-2
192.168.1.13  tri-mini-3
```

После этого все ssh/scp примеры ниже используют `tri-mini-{1,2,3}` вместо голых IP.

**Как проверить, что политика применилась:**

```bash
# с Mac
sudo arp -d 192.168.1.10 2>/dev/null    # снести старый кэш
for h in tri-mini-1 tri-mini-2 tri-mini-3; do
  ssh root@$h 'hostname; ip -4 addr show eth0 | grep inet; ip link show eth0 | grep ether'
done
```

Ожидание: три разных hostname, три разных IP (`.10 / .12 / .13`), три разных MAC (`02:00:00:00:00:0{1,2,3}`). Если хоть один параметр совпал — не идём дальше, возвращаемся в serial-консоль (см. §1.4 и [`SERIAL_NET_FIX.md`](SERIAL_NET_FIX.md)).

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

### 1.4. Identical-image trap — root cause + real fixes

**Symptom:** three boards on the LAN → ssh/scp flaky, ARP table unstable,
`scp` of the 537 KB `smoke-m1` binary produces size-0 files, `ssh echo`
works intermittently.

**Root cause (verified 2026-07-04, all three P201Mini units):**

1. The stock image runs `root=/dev/ram0 rootfstype=ramfs` — `/etc` is
   RAM-only. Runtime edits to `/etc/network/interfaces`,
   `/etc/hostname`, `/etc/hosts`, `/etc/systemd/network/*` **do not
   survive reboot**. Warm `reboot` also hangs the Zynq PS on this image
   — a physical cold power-cycle is required to reboot.
2. All three boards ship with **identical MAC `00:0a:35:00:01:22`** +
   identical hostname `pzp201mini` + identical IP `192.168.1.10`. Three
   identical MACs on one L2-domain means the switch and the host ARP
   table cannot tell them apart → forwarding entry flips several times
   per second → TCP sessions break mid-transfer.
3. Runtime MAC override (`ifconfig eth0 hw ether 02:00:00:00:00:0N`)
   fixes L2 identity for small packets but **breaks bulk TX**: the Zynq
   GEM (`macb` driver) computes the TX checksum in hardware and mangles
   large frames under a spoofed MAC. `scp` of the 537 KB `smoke-m1`
   binary fails **10 out of 10** attempts (destination size = 0), while
   tiny `ssh echo` traffic works intermittently. `ethtool` is **not
   installed** on the stock image, so `tx-checksumming off` cannot be
   disabled from userspace.

**Why the obvious shortcuts fail:**

- `ip addr add …` / edit `/etc/network/interfaces` + reboot → wiped
  (ramfs).
- Base64-over-serial → command chunks larger than ~2 KB overflow the tty
  line buffer (shell starts reading a `> ` continuation prompt and
  corrupts the encoded payload).
- `nmcli` / `NetworkManager` are absent on the stock image (Buildroot
  minimal).
- MAC spoof alone → GEM TX checksum offload breaks `scp` (see above); no
  `ethtool` to disable it.

**Real fixes:**

- **(A) Persistent SSH-key access — NO reflash.** The stock image's
  `/etc/init.d/S21misc` already restores `/root/.ssh/authorized_keys`
  from `/mnt/jffs2/root/.ssh/` on every boot (jffs2 lives on mtd2 and
  **is** persistent). Drop the host public key there together with a
  matching `keys.md5` → permanent key-based SSH that survives every
  power-cycle. **This restores access only** — it does NOT fix
  IP/MAC/hostname uniqueness.

- **(B) Persistent network uniqueness — needs image work.** `S21misc`
  restores passwd / dropbear host keys / SSH authorized_keys but **not**
  the network config. Two options, both require rebuilding the
  initramfs:
  - **(B1)** Extend `S21misc` (or add a new `S22net`) in the initramfs
    to `cp /mnt/jffs2/etc/network/interfaces /etc/` +
    `cp /mnt/jffs2/etc/hostname /etc/` at boot. Per-board differences
    live in the persistent jffs2 partition.
  - **(B2)** Bake the unique IP / MAC / hostname into a per-board image
    at build time — one image per physical board. Cleaner, but requires
    three separate SD-card flashes.

- **(C) M1×3 without network uniqueness — usb0 gadget.** Each Puzhi
  P201Mini exposes a **USB-CDC-Ethernet gadget `usb0` at `192.168.2.1`**.
  Each board's USB cable is a separate point-to-point link to the host
  → **no shared L2, no ARP conflict, no GEM offload path** (usb0 has
  its own MAC and does not go through the eth0 macb driver). Assign each
  host-side `enX` interface a distinct `192.168.2.x` address and reach
  each board via its own USB cable. This bypasses the eth0 identity
  problem entirely and lets M1 run in parallel on all three boards
  **on the stock image, without reflash**.

**Recommended order:**

1. Path (A) first — permanent key SSH, no reflash. Costs ~5 minutes,
   removes password-echo friction forever.
2. Path (C) for M1×3 — gets all three boards to `smoke-m1 RC=0` today,
   still on the stock image. Every M1 datapoint is real hw.
3. Path (B) only when we need M2/M3/M4 on real ethernet (multi-hop
   routing over usb0 is not representative of the target radio topology).
   That is a scheduled image-build task, not an emergency.

For the paste-ready serial recipe (previous approach — kept as reference
for a persistent-ext4-rootfs image) see [`SERIAL_NET_FIX.md`](SERIAL_NET_FIX.md).

**What NOT to do:**

- Do not apply the §0.5 policy via `/etc/network/interfaces` + reboot on
  the stock image — it is silently wiped.
- Do not spoof only the MAC via `ifconfig hw ether` and expect `scp` to
  work — the GEM offload will mangle every frame > MTU. Verified 10/10.
- Do not try `arp -s` on the Mac. Static ARP only lives until the Mac
  reboots and does not solve the L2 conflict on the switch.
- Do not try to `gzip | base64` and paste in one chunk — that increases
  the chunk size; the tty line-buffer falls over even faster.

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
sha256sum "$BIN"       # ожидаемо: 534604 B, sha256 e5abc335…7290a (2026-07-01 build)
                       # или  a17e88e6… (2026-07-04 build, rustup-stable + rust-lld)
                       # оба sha256 должны быть в smoke/M1_RESULTS.md
```

Для каждой платы (после применения политики §0.5 hostname/IP/MAC разные):
```bash
for h in tri-mini-1 tri-mini-2 tri-mini-3; do
  scp "$BIN" root@$h:/root/smoke-m1
  ssh root@$h 'chmod +x /root/smoke-m1 && /root/smoke-m1; echo RC=$?'
done
```

Пароль на всех трёх P201/P203 Mini — `analog` (PlutoSDR default, shipped из коробки). Если пароль другой — образ был кастомизирован, обновить рецепт под свой стенд.

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
