# W12 Board Manifest — plate 1 alive

Дата: 2026-07-07
Ветка: `feat/w12-board-manifest`
Anchor: phi^2 + phi^-2 = 3

## Session outcome (2026-07-06 → 2026-07-07)

Плата 1 жива. SSH + Linux + AD9361 verified после отключения JTAG и подключения только питание + Ethernet.

## Working board state (verified)

| Поле | Значение |
|---|---|
| access | `ssh root@192.168.1.10` password `analog` |
| boot_mode | QSPI, without SD, without JTAG |
| kernel | `5.10.0-97866-g4efeacd06cfc-dirty armv7l` |
| u-boot | `PZSDR-P201MINI v0.20-PlutoSDR` |
| QSPI chip | Winbond W25Q256 (не N25Q256A как ожидал driver) |
| phy_mode | `rgmii-rxid` |
| eth0 | MAC `00:0a:35:00:01:22`, IP `192.168.1.10/24`, 1 Gbps |
| ad9361 | `iio:device0 = ad9361-phy` |
| mtd0 | `qspi-fsbl-uboot` 1MB (unreadable via Linux MTD driver) |
| mtd3 | `qspi-linux` 30MB (unreadable via Linux MTD driver) |

## Root cause finding — FSBL parking

FSBL на QSPI паркуется в exception handler если POR bit в `RESET_REASON` был очищен предыдущим JTAG-loaded U-Boot через `clear_reset_cause`. Это объясняет weeks of intermittent failures — не hardware damage, а состояние RESET_REASON регистра переживает soft reset.

Recovery: физическое отключение питания на 5+ минут → полный power-cycle → POR bit восстанавливается → FSBL проходит validation → QSPI boot штатный.

## QSPI driver caveat

Kernel MTD driver в stock image ожидает Micron N25Q256A, реально на плате Winbond W25Q256. Расхождение проявляется на 4-byte addressing (EAR register). Оба чипа 32 MB QSPI NOR, но register maps несовместимы для 3-byte→4-byte mode switch.

Практические последствия:
- `dd if=/dev/mtd0` возвращает мусор или зависает — driver не умеет читать `W25Q256` через EAR
- `mtd_debug read` тот же результат
- **QSPI dump через Linux MTD невозможен на stock image без patch driver'а**
- QSPI dump возможен через U-Boot `sf read` (U-Boot имеет generic SPI-NOR driver с proper JEDEC ID detection)

## План между сессиями

1. **Плата 1: 5+ минут отключения от всего**  
   Физически отключить питание, ethernet, USB. Ждать 5+ мин чтобы RESET_REASON POR bit стабилизировался. Подключить питание + ethernet в роутер, ждать 30 сек, `ping 192.168.1.10` + `arp -a | grep 00:0a:35` со Mac. Ожидание: pингуется, ssh работает.

2. **Плата 2 и 3: boot switch в QSPI, без SD, без JTAG**  
   По одной за раз (все три ходят на 192.168.1.10 → MAC/ARP конфликт). Каждую подключать индивидуально к роутеру, проверять `ping 192.168.1.10`. Если пингуется — записать факт "плата N жива в shipped state, W07 date". Если нет — записать факт "плата N требует recovery, W07 date".

3. **ALINX + Puzhi: запросить stock BOOT.BIN**  
   Email обеим компаниям параллельно. Приложить: фото трёх плат с видимыми серийниками, PO/invoice (если есть), запрос `BOOT.BIN + image.ub + rootfs.tar.gz + XSA` for P201Mini. Указать что boards полностью функциональны, требуется stock image для recovery/re-flash после experimentation.

4. **Не модифицировать network config на платах**  
   IP/MAC/hostname уникальность решать через switch VLAN или port-based isolation. Не пытаться править `/etc/network/interfaces` — wiped by ramfs каждый boot (verified LOCAL_FLASH §1.4).

## Инструментальный upgrade — UTM

Для W12 stage 2 (когда будут два+ живых плат в сети одновременно, MAC conflict неизбежен) — UTM + Ubuntu 22.04 ARM64 + FTDI passthrough для одновременного JTAG + serial. Не срочно — плата 1 уже живёт без этого. Приоритет ниже пунктов 1-4.

## Что НЕ делать (learned this session)

- Не запускать JTAG на плате которая работает по Ethernet. JTAG-loaded U-Boot очищает RESET_REASON POR bit → следующий QSPI boot паркует FSBL → нужна физическая изоляция для recovery.
- Не пытаться `dd` QSPI через `/dev/mtdN` на stock image — W25Q256 driver mismatch, будет мусор.
- Не переключать boot mode в JTAG на рабочей плате без крайней необходимости.
- Не подключать одновременно две+ плат к одному Ethernet segment без VLAN — MAC/IP identity conflict → ARP флиппинг → TCP break.

## Ссылки

- [LOCAL_FLASH.md](https://github.com/gHashTag/tri-net/blob/main/docs/LOCAL_FLASH.md) — bring-up protocol, MAC/IP identity trap §1.4
- [SERIAL_NET_FIX.md](https://github.com/gHashTag/tri-net/blob/main/docs/SERIAL_NET_FIX.md) — serial console recipes
- [tools/jtag-bootstrap/README.md](https://github.com/gHashTag/tri-net/blob/feat/jtag-bootstrap-tools/tools/jtag-bootstrap/README.md) — JTAG bring-up (used this session, do NOT repeat on live boards)

Anchor: phi^2 + phi^-2 = 3
