# TRI-NET транш 2 — ссылки на закупку (9 позиций)

Дата: 12 июня 2026 · Курс ~32.4 THB/$ · Доставка: Таиланд (Чумпхон)

**Вывод:** все 9 позиций одним заказом собираются только на **AliExpress** — AntSDR E200 на Alibaba.com отсутствует (проверено в браузере 12.06.2026). Alibaba — запасной вариант для опта при масштабировании.

> **⚠️ Если прямая ссылка AliExpress отдаёт 404 — лот чаще всего жив.** Это глюк гостевого режима: при переходе сайт добавляет параметр `gatewayAdapt` и ломает страницу (проверено 13.06: лот 1005006566555223 по прямой ссылке — 404, из поиска — открывается). Решение: войти в аккаунт (тогда прямые ссылки работают) или открыть товар через поиск — у каждой позиции ниже указан запрос и как узнать карточку в выдаче.

---

## 1. AntSDR E200 — 3 шт

- **AliExpress (проверено, в наличии, бесплатная доставка в TH):**
  https://www.aliexpress.com/item/1005008647281550.html
  **Если 404:** поиск `AntSDR E200` → карточка MicroPhase «Professional radio applications», продавец Chip Board House Store:
  https://www.aliexpress.com/w/wholesale-AntSDR-E200.html
  - Вариант **E200-AD9361** — THB 23 027 ≈ **$710/шт** — диапазон 70 МГц–6 ГГц, как в смете
  - Вариант E200-AD9363 — THB 13 676 ≈ $420/шт — официально до 3.8 ГГц, **5 ГГц недоступен** (иногда разблокируется прошивкой, без гарантии)
- **Alibaba:** ❌ нет
- **Официально:** https://www.crowdsupply.com/microphase-technology/antsdr-e200 ($499, AD9361)

> ⚠️ Решение по варианту AD9361/AD9363 не принято. AD9361 = перерасход ~$630 на 3 шт против сметы ($1 497). Crowd Supply по $499 дешевле AliExpress-варианта AD9361 — стоит сравнить сроки доставки в Таиланд.

## 2. Антенна omni 6 dBi 5 ГГц с SMA — 6 шт (по 2 на узел, MIMO 2×2)

- **AliExpress:** https://www.aliexpress.com/item/1005007449002305.html (лот = 2 шт → 3 лота)
  - альтернатива: https://www.aliexpress.com/item/1005005990402902.html
- **Alibaba:** https://www.alibaba.com/product-detail/WiFi-Antenna-with-RP-SMA-Male_1601061691258.html
  - подборка 6dBi: https://www.alibaba.com/showroom/6dbi-wifi-antenna.html

> ⚠️ Wi-Fi антенны почти всегда **RP-SMA**, у E200 порты **SMA female**. Проверить разъём или добавить переходники RP-SMA→SMA (копейки, но без них не соединится).

## 3. Кабель SMA male–SMA male, RG316, 1 м — 6 шт

- **AliExpress:** https://www.aliexpress.com/item/1005006175927479.html
  - альтернатива (выбрать 1m): https://www.aliexpress.com/item/32948634584.html
- **Alibaba:** https://www.alibaba.com/product-detail/SMA-Male-to-SMA-Male-Cable_1601019984604.html
  - вариант: https://www.alibaba.com/product-detail/Coaxial-Cable-RG316-Extension-Jumper-SMA_1601671842905.html
  - угловой: https://www.alibaba.com/product-detail/Factory-Low-Price-RG316-SMA-Male_1601022984539.html

## 4–5. Ethernet Cat6, 3 м — 6 шт (3× радио→FPGA + 3× FPGA→пользователь)

- **AliExpress:** https://www.aliexpress.com/item/1005009952356384.html
  - плоский: https://www.aliexpress.com/item/1005003514674765.html
- **Alibaba:** https://www.alibaba.com/product-detail/CAT-6e-Ethernet-Patch-Cable-RJ45_1601023026960.html
  - подборка: https://www.alibaba.com/showroom/3m-utp-cat6-patch-cord.html

## 6–7. Блоки питания 12В — 6 шт (3× AntSDR + 3× AX7203B)

> ⚡ **Позиция 7 возвращена 13.06.2026 после проверки заказа:** в карточке лота AX7203 (Alibaba, Shanghai Tianhui) таблица «Product Package» показывает — **блока питания НЕТ ни в одной комплектации** (только плата + USB Downloader; в Luxury ещё модули AN9767/AN706/AN9238, камера, LCD). ALINX продаёт 12В-адаптер отдельным аксессуаром. Докупить **3× 12В 3А** для AX7203B (рекомендация ALINX — 3А) + 3× 12В 3А для AntSDR = **6 шт из лота ниже**.

- **AliExpress (✅ лот жив, перепроверено 13.06 через поиск):**
  https://www.aliexpress.com/item/1005006566555223.html
  Варианты 12V 1А/2А/3А × вилки EU/US/UK/AU, штекер 5.5×2.1–2.5 мм. Цена 3А EU: THB 88 по welcome-акции / THB 269 (~$8.3) обычная. Choice, 279 продаж, рейтинг 4.5, продавец Aamasun Global.
  **Если 404:** поиск по запросу `12V 3A power adapter 5.5x2.5mm` → карточка «12V 1A 2A 3A» с четырьмя вилками (EU/US/UK/AU), THB ~63, Choice — обычно в первой строке выдачи:
  https://www.aliexpress.com/w/wholesale-12V-3A-power-adapter-5.5x2.5mm.html
- Запасной (✅ жив, но «не более 1 шт» в гостевом режиме): https://www.aliexpress.com/item/1005006596717341.html
- **Alibaba (универсальный 2A/3A):** https://www.alibaba.com/product-detail/universal-power-supply-ac-adapter-12v_60681382994.html

> ⚠️ В гостевом режиме на обоих лотах висит лимит «1 шт на покупателя» (условие welcome-цены). После входа в аккаунт берите по обычной цене — лимит снимается; если нет, у первого лота есть аналоги в той же выдаче: https://www.aliexpress.com/w/wholesale-12V-3A-power-adapter-5.5x2.5mm.html

## 8. SD-карта 16 ГБ Class 10 — 3 шт

- **AliExpress (выбрать из выдачи):** https://www.aliexpress.com/w/wholesale-sandisk-16gb-micro-sd-class-10.html
- **Alibaba:** https://www.alibaba.com/product-detail/16GB-Class-10-SD-Memory-Card_1601219994272.html
  - вариант: https://www.alibaba.com/product-detail/16GB-Class-10-SD-Memory-Card_1601220020268.html

## 9. USB-C кабель (отладочная консоль) — 3 шт

- **AliExpress:** https://www.aliexpress.com/item/1005006505041416.html (UGREEN, выбрать длину)
- **Alibaba:** https://www.alibaba.com/product-detail/Real-Full-3A-USB-Type-C_1600453197315.html
  - USB-A→C: https://www.alibaba.com/product-detail/USB-Type-C-to-A-USB_62035764403.html

## 10. FT2232H модуль (программатор) — 1 шт, ВОЗМОЖНО НЕ НУЖЕН

> 💡 13.06: в каждой комплектации AX7203B (вкл. базовую) уже идёт **USB Downloader (JTAG-кабель)** — см. таблицу Product Package в карточке заказа. FT2232H остаётся опцией для openFPGALoader-тулчейна / отладки AntSDR. Решить перед заказом.

- **AliExpress (✅ проверено в браузере 12.06):** https://www.aliexpress.com/item/1005009705189817.html
  YourCee CJMCU-2232HL — THB 204 (~$6.3) + доставка THB 91, рейтинг 5.0, 96 продаж. **Выбрать вариант FT2232HL (двухканальный), не FT232HQ.**
  **Если 404:** поиск `FT2232HL development board` → фиолетовая плата YourCee/CJMCU-2232, THB ~204:
  https://www.aliexpress.com/w/wholesale-FT2232HL-development-board.html
- ~~https://www.aliexpress.com/item/32898010758.html~~ — лот удалён (404, проверено 12.06)
- **Alibaba:** https://www.alibaba.com/product-detail/FT2232HL-Development-Board-FT2232H-USB-To-1600568031836.html
  - вариант: https://www.alibaba.com/product-detail/FT2232HL-USB-to-UART-FIFO-SPI_62047167059.html

---

## Примечания

- Проверены в браузере лично (12.06.2026): поз. 1 (E200), поз. 6–7 (БП), поз. 10 (FT2232HL). Остальные ссылки — из поиска, перед заказом перепроверить.
- Мёртвые ссылки заменены 12.06: БП 1005006774623855 (404) → 1005006566555223; FT2232H 32898010758 (404) → 1005009705189817.
- На Alibaba у большинства лотов **MOQ 10–100+ шт** и цены «от» — под 3–6 штук многие продавцы не отгружают.
- Два открытых решения перед заказом: **AD9361 vs AD9363** (бюджет vs 5 ГГц) и **SMA vs RP-SMA** (разъёмы антенн).
- Смета транша 2: **$1 771** (поз. 7 возвращена — БП в комплекте плат нет). С AD9361 по $710 итог ≈ $2 404. Минус ~$16, если откажетесь от FT2232H (поз. 10).
- Статус транша 1 (13.06.2026): заказано на Alibaba у Shanghai Tianhui Trading Firm: 2× AX7203B ($388/шт) + 1× Luxury Package ($625, = плата + AN9767 DAC + AN706 + AN9238 ADC + камера + 4.3" LCD), итого USD 1 401, отгрузка началась. Документация AX7203/AN9767/AN706 — в чате заказа.
- ❗ Проверить по мануалу: в атрибутах лота у AX7203B указан **1× Gigabit Ethernet** (в описании и у обычного AX7203 — 2×). Для архитектуры узла TRI-NET (радио-порт + пользовательский порт) это критично.
