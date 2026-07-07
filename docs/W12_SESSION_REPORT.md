# W12 BOARD RECOVERY — COMPLETE SESSION REPORT

**Дата:** 6-7 июля 2026
**Сессия:** W12 board bring-up и recovery (marathon ~20 часов)
**Anchor:** φ² + φ⁻² = 3

---

## Итог: ТРИ ПЛАТЫ P201Mini ЖИВЫ И ДОСТУПНЫ ПО SSH

```
192.168.1.11  Linux 5.10.0  AD9361=ad9361-phy  SD boot  ✓
192.168.1.12  Linux 5.10.0  AD9361=ad9361-phy  SD boot  ✓
192.168.1.13  Linux 5.10.0  AD9361=ad9361-phy  SD boot  ✓
SSH: sshpass -p 'analog' ssh -o PubkeyAuthentication=no root@192.168.1.1N
```

---

## Рабочий рецепт (воспроизводимый)

### SD карта (FAT32, 5 файлов)

| Файл | Размер | Источник |
|------|--------|----------|
| `BOOT.BIN` | 4.7MB | Kuiper/Analog Devices (FSBL + U-Boot + FPGA bitstream) |
| `uImage` | 4.3MB | P201Mini vendor ZIP 001 (kernel 5.10.0) |
| `devicetree.dtb` | 19KB | P201Mini vendor ZIP 002 |
| `uramdisk.image.gz` | 5.6MB | P201Mini vendor ZIP 002 (initramfs rootfs) |
| `uEnv.txt` | 7KB | P201Mini vendor ZIP 001 (stock U-Boot environment) |

### Boot procedure
1. Записать 5 файлов на FAT32 SD карту
2. Boot switch → QSPI/SD позицию
3. SD карту вставить ДО подачи питания (auto-detect в bootROM)
4. USB power + Ethernet в роутер
5. Ждать 60-90 секунд
6. SSH: `sshpass -p 'analog' ssh -o PubkeyAuthentication=no root@192.168.1.10`

### Multi-board: runtime IP separation
```bash
# На каждой плате через SSH:
ip addr add 192.168.1.1N/24 dev eth0
```

---

## Что было сделано за сессию

### Диагностика (12+ попыток)

1. **QSPI boot** — плата 2 загрузилась, SSH работал, dmesg показал AD9361 ✓
2. **QSPI experiments** (spidev, devmem, SLCR reset) — вызвали bus hang → POR бит стёрт
3. **JTAG диагноз** — FSBL паркуется в exception handler при POR=0
4. **DDR3 abort** при JTAG Linux load — PlutoSDR ps7_init ≠ P201Mini DDR3 config
5. **FSBL patch attempts** — code relocation перетирало патчи
6. **10-hour power disconnect** — POR не сбросился (SLCR domain maintained)
7. **nRST button** — это AD9361 reset, не системный (PS_POR)
8. **SD boot with vendor files** — РАБОТАЕТ! FSBL не паркуется при SD boot

### Ключевые находки

| Находка | Значение |
|---------|----------|
| **PLL status register = 0xF800010C** (НЕ 0xF800011C) | Я читал неправильный регистр весь день |
| **P201Mini ps7_init** извлечён из fsbl.elf | 208 команд, правильные DDR3 для MT41K256M16TW |
| **QSPI chip = Winbond W25Q256** (kernel expects N25Q256A) | Driver bug: "failed to read ear reg" → все reads возвращают 0xFF |
| **Ethernet = PL side** (не PS GEM0) | PHY address=010, RGMII через FPGA, требует bitstream |
| **SD boot bypasses POR issue** | bootROM ставит boot_valid=1 для SD автоматически |
| **U-Boot `clear_reset_cause`** очищает POR | После первого boot с QSPI, повторный QSPI boot невозможен |

### Ассеты сохранены

| Файл | Путь | Описание |
|------|------|----------|
| P201Mini ps7_init | `/tmp/ps7_p201mini.tcl` | 208 TCL команд для openOCD |
| Recovery log | `/tmp/W12_RECOVERY_LOG.md` | Лог 10+ попыток с lesson learned |
| SD boot files | `/tmp/sd_boot/` | Все 5 файлов для SD карты |
| FPGA bitstream | `/tmp/p201_bitstream.bin` | 2.47MB, извлечён из FIT image |
| P201Mini FIT | `/tmp/sd_boot/pzp201mini.bin` | 12.4MB, kernel+DTB+rootfs+bitstream |
| Vendor docs | Downloads/P201Mini_P203Mini*.zip | 3 ZIP от ALINX/Aithtech |

---

## Сравнение с планом партнёра (v2)

| Пункт плана | Статус | Комментарий |
|-------------|--------|-------------|
| **3× FPGA-плата** | ✅ Куплены | P201Mini (Zynq 7020 + AD9361), не AX7203 |
| **AntSDR E200** | ❌ Не куплен | P201Mini имеет встроенный AD9361 — не нужен внешний SDR |
| **Антенны 5 ГГц** | ❌ Не куплены | Нет в планах этой сессии |
| **Кабели Ethernet** | ✅ Есть | Используются для подключения к роутеру |
| **Блоки питания** | ✅ Есть | USB power (TypeC) |
| **SD карты** | ✅ Есть | 3× 32GB, загружены рабочим образом |
| **FT2232H программатор** | ✅ Встроен | На каждой P201Mini (JTAG + UART) |
| **3 рабочих узла** | ✅ ДОСТИГНУТО | Все 3 платы грузятся в Linux, AD9361 виден, SSH работает |
| **Радиоканал между узлами** | ⏳ Не начат | Требует antenna + RF testing |
| **Видеозапись работы** | ⏳ Не начат | Требует M2 mesh testing |
| **Открытый код** | ⏳ В репозитории | tri-net на GitHub, Rust crypto stack |

### Важное отличие от плана

План партнёра описывает **AX7203 (XC7A200T) + AntSDR E200** как отдельные компоненты.
Реальность: **P201Mini** — это единая плата с **Zynq 7020 (PS ARM + PL FPGA) + AD9361**.

P201Mini = AX7203 + AntSDR в одном корпусе, но:
- FPGA меньше (7020 vs A200T: 220 DSP vs 740 DSP, 1GB vs 1GB DDR3)
- AD9361 встроен (не нужен внешний радиомодуль)
- Один Ethernet порт (не два)
- Управление через ARM Linux (Zynq PS)

### Что готово для demo партнёру

1. **3 живых узла** на одной сети — готовы к mesh testing
2. **AD9361** обнаружен на каждой плате — RF готов к тестированию
3. **SSH доступ** — можно разворачивать tri-net код
4. **SD boot recipe** — воспроизводимый, задокументированный

### Что нужно для полного MVP demo

1. **Антенны** — 2× на узел (MIMO 2×2), 5 ГГц omni
2. **Кабели SMA** — соединение AD9361 ↔ антенна
3. **Tri-net код** — деплой на платы через SSH
4. **M2 mesh test** — convergence gate (two-board, three-board)

---

## Уроки сессии (для skills/experience)

1. **НЕ экспериментировать с QSPI регистрами через Linux user-space** — spidev/devmem может вызвать bus hang → сброс → POR стёрт → плата "умирает"
2. **НЕ модифицировать network config на платах** — initramfs восстанавливает, но процесс может нарушить ARP
3. **НЕ подключать JTAG к рабочим платам** — U-Boot clear_reset_cause стирает POR
4. **SD boot — безопасный путь** — не зависит от QSPI состояния, POR, или JTAG
5. **Правильный PLL register = 0xF800010C** (не 0xF800011C)
6. **P201Mini ps7_init ≠ PlutoSDR ps7_init** — DDR3 chips разные (MT41K256M16TW vs что-то другое)
7. **macOS блокирует raw disk writes** — используй filesystem operations или Linux VM

---

## Следующие шаги

1. **M1 crypto smoke** на каждой плате — X25519 + ChaCha20-Poly1305 (Rust cross-compile)
2. **AD9361 digital loopback** — internal LOOPBACK=1, SNR ≥ 100 dB
3. **M2 mesh test** — two-board convergence (triangles), затем three-board
4. **MAC separation** — per-board уникальный MAC (02:00:00:00:00:0N) при boot
5. **QSPI recovery** — записать stock firmware в QSPI через SSH (когда драйвер починят)

phi² + φ⁻² = 3
