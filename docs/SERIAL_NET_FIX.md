# Serial-console recipe: unique IP / hostname / MAC on three Puzhi P201/P203 Mini

**Когда читать**: три (или две) идентичные Puzhi Mini на shipped-образе,
одинаковый `pzp201mini` hostname, одинаковый `192.168.1.10`, ssh/scp
нестабильны, `arp` фликтует. Полное описание симптома —
[`LOCAL_FLASH.md`](LOCAL_FLASH.md) §1.4. Целевая политика (кому какой
IP/hostname/MAC) — [`LOCAL_FLASH.md`](LOCAL_FLASH.md) §0.5.

Этот файл — механика. Никакой новой политики, только «где именно править
на конкретном образе, чем, как проверить».

## 0. Инструмент — `screen` с логированием

```bash
# на Mac, для каждой платы отдельным окном:
screen -L /dev/tty.usbserial-*  115200
```

- Флаг `-L` включает write-into-file по умолчанию → `screenlog.0` в текущем
  каталоге. Всё, что ты набираешь, и всё, что отвечает плата, попадает
  туда. Это будущий вещдок для `smoke/BOARD_N_SERIAL_FIX_<date>.log`.
- Выход из `screen`: `Ctrl-A`, потом `k`, потом `y`. Не путать с `Ctrl-C`
  — он уйдёт в шелл платы, не в `screen`.
- Если `tty.usbserial-*` не резолвится — `ls /dev/tty.usb*`, взять точное
  имя (обычно `/dev/tty.usbserial-A906KRZK` или подобное).
- Скорость `115200` — стандарт для Zynq через ttyPS0. Если ничего не
  видно на экране — попробовать `38400` и `9600`, но 99% случаев 115200.

## 1. Login и первичная диагностика

```
pzp201mini login: root
Password: analog                # PlutoSDR default, echo выключен
```

Первое, что делаем — не трогаем сеть, а понимаем, чем управляем:

```bash
# кто запускает сеть?
systemctl list-units --type=service --state=running 2>/dev/null | grep -Ei 'network|net' || true
ls -la /etc/systemd/network/    2>/dev/null || echo "no systemd-networkd"
ls -la /etc/network/interfaces  2>/dev/null || echo "no ifupdown"
ls -la /etc/init.d/S*network*   2>/dev/null || echo "no busybox init net script"
cat /boot/uEnv.txt              2>/dev/null || echo "no /boot/uEnv.txt"
cat /proc/cmdline
# кто сейчас держит IP?
ip -4 addr show eth0
ip link show eth0
cat /etc/hostname
```

По этой пятёрке безошибочно определяется сценарий. Дальше — четыре
варианта: A (ifupdown), B (systemd-networkd), C (busybox init script + udhcpc
или статическая настройка в скрипте), D (адрес зашит в U-Boot bootargs).

## 2. Сценарий A — `/etc/network/interfaces` (ifupdown)

Признак: `cat /etc/network/interfaces` показывает `auto eth0 / iface eth0`
и systemd-networkd не запущен.

```bash
# board-N, где N ∈ {1,2,3}
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 192.168.1.1N
    netmask 255.255.255.0
    gateway 192.168.1.1
    hwaddress ether 02:00:00:00:00:0N
EOF
# замени N на 1, 2 или 3 — руками, чтобы не забыть
```

**Важно**: heredoc `<<'EOF'` через serial работает нормально, пока каждая
строка < ~200 символов. Если файл большой — писать по кусочкам через
`>>`, не одним куском (см. §6, лимит tty).

Далее hostname:

```bash
echo tri-mini-N > /etc/hostname                        # без переноса строки в конце если busybox
hostname tri-mini-N                                    # применить в текущей сессии
hostnamectl set-hostname tri-mini-N 2>/dev/null || true # если есть systemd
```

Синк и ребут:

```bash
sync
reboot
```

После ребута плата должна прийти на `192.168.1.1N` со своим hostname.
Проверка описана в §7.

## 3. Сценарий B — systemd-networkd

Признак: `systemctl status systemd-networkd` показывает `active (running)`,
в `/etc/systemd/network/` лежат `*.network` файлы.

```bash
# сначала посмотреть, что там уже есть
ls /etc/systemd/network/
# бэкап любого eth0-конфига
cp /etc/systemd/network/*eth0* /root/eth0.bak.$(date +%s) 2>/dev/null || true

# board-N
cat > /etc/systemd/network/10-eth0.network <<'EOF'
[Match]
Name=eth0

[Link]
MACAddress=02:00:00:00:00:0N

[Network]
Address=192.168.1.1N/24
Gateway=192.168.1.1
EOF
# замени N руками
```

Hostname через `hostnamectl`, потому что systemd:

```bash
hostnamectl set-hostname tri-mini-N
sync
reboot
```

Если systemd-networkd не подхватил MAC на новом бинде — на некоторых
ядрах L2 MAC живёт в netdev, не в .network:

```bash
# /etc/systemd/network/10-eth0.link
cat > /etc/systemd/network/10-eth0.link <<'EOF'
[Match]
OriginalName=eth0

[Link]
MACAddress=02:00:00:00:00:0N
EOF
```

`.link` файлы применяются на очень раннем этапе, до systemd-networkd, и
именно они меняют hardware MAC. Ребут обязателен, `networkctl reload` не
успеет.

## 4. Сценарий C — busybox init script (`/etc/init.d/S40network` и т.п.)

Признак: ни `/etc/network/interfaces` полноценного, ни
systemd-networkd; в `/etc/init.d/` есть `S*network*`, который делает
`ifconfig eth0 192.168.1.10 up` или `udhcpc`.

Правим скрипт напрямую:

```bash
grep -Rin '192.168.1.10\|pzp201mini' /etc/init.d/ /etc/ 2>/dev/null | head -20
# в найденном файле — руками vi/nano, чтобы поменять IP и добавить MAC
```

Пример правки (после нахождения строки в скрипте):

```bash
# было:
#   ifconfig eth0 192.168.1.10 netmask 255.255.255.0 up
# стало (board-N):
#   ip link set dev eth0 address 02:00:00:00:00:0N
#   ifconfig eth0 192.168.1.1N netmask 255.255.255.0 up
#   route add default gw 192.168.1.1
```

Hostname на busybox — обычно `/etc/hostname` + `hostname -F /etc/hostname`
из init:

```bash
echo tri-mini-N > /etc/hostname
sync
reboot
```

## 5. Сценарий D — bootargs / U-Boot (крайний случай)

Признак: ни один из скриптов не содержит `192.168.1.10`, но `ip -4 addr`
всё равно его показывает — IP приходит из `ip=` в `/proc/cmdline`.

```bash
cat /proc/cmdline
# если видно  ip=192.168.1.10::192.168.1.1:255.255.255.0::eth0:off  —
# правим /boot/uEnv.txt

mount -o remount,rw /boot 2>/dev/null || true
sed -i 's|ip=192.168.1.10:|ip=192.168.1.1N:|' /boot/uEnv.txt
# замени N руками
sync
reboot
```

Этот сценарий редкий; на shipped-Puzhi обычно A или C, не D.

## 6. Ограничения tty и обход

- Максимальный чанк, который надёжно проходит через serial + shell
  line-buffer: ~2 KB (4 KB иногда проходит, > 4 KB — почти всегда падает
  на `> ` continuation prompt посреди base64).
- Если очень нужно залить бинарь через serial — `base64` + режем на
  строки по 76 символов + пауза 50 мс между строками:
  ```bash
  # на Mac
  base64 -b 76 smoke-m1 | awk 'BEGIN{print "cat > /tmp/smoke-m1.b64 <<'\''EOF'\''"} {print} END{print "EOF"}' > payload.txt
  # затем в screen: paste postoji медленно, не всё сразу.
  ```
  Но 500 KB через 115200 baud без flow-control — это ~1 час, часто рвётся.
  Быстрее и надёжнее: починить IP по §2/3/4, потом `scp` через нормальный
  ethernet.
- `screen` может проглатывать длинные строки при быстрой вставке из
  clipboard. Проверять `screenlog.0` — если там `> > > > `, значит tty
  улетел в continuation, всё, что дальше, битое.

## 7. Проверка после ребута всех трёх плат

Все три платы физически в свитче, три отдельных ethernet-порта:

```bash
# на Mac
sudo arp -d 192.168.1.10 2>/dev/null
sudo arp -d 192.168.1.12 2>/dev/null
sudo arp -d 192.168.1.13 2>/dev/null

# проверить, что /etc/hosts содержит tri-mini-{1,2,3} (см. LOCAL_FLASH §0.5)

for h in tri-mini-1 tri-mini-2 tri-mini-3; do
  echo "=== $h ==="
  ping -c 2 -W 1000 $h
  ssh -o StrictHostKeyChecking=accept-new root@$h \
    'hostname; ip -4 addr show eth0 | grep -w inet; ip link show eth0 | grep -w ether'
done
```

Ожидание:

- `tri-mini-1` отвечает: hostname `tri-mini-1`, `inet 192.168.1.10/24`, `ether 02:00:00:00:00:01`
- `tri-mini-2` отвечает: hostname `tri-mini-2`, `inet 192.168.1.12/24`, `ether 02:00:00:00:00:02`
- `tri-mini-3` отвечает: hostname `tri-mini-3`, `inet 192.168.1.13/24`, `ether 02:00:00:00:00:03`

Если хоть одна строка не сошлась — вернуть только эту плату на serial и
пройти §2-§5 ещё раз для неё.

## 8. Куда сохранить лог

Стандартный маршрут:

```bash
mkdir -p /home/user/workspace/tri-net/smoke
cp screenlog.0 /home/user/workspace/tri-net/smoke/BOARD_N_SERIAL_FIX_$(date +%F).log
```

Файл — вещдок исправления. Не коммитить бинарные / очень длинные логи в
main без ревизии, но держать локально стоит.

## 9. Что мы НЕ пытались

- **Не пытались** удалённо через ssh поменять IP на «живой» плате — ssh
  сессия рвётся посреди `sync`, конфиг остаётся half-written.
- **Не пытались** обмануть Mac через `arp -s` — L2-конфликт на свитче
  этим не лечится.
- **Не пытались** развести все три платы через USB-tether — Puzhi Mini
  не заявлен как USB-gadget по умолчанию, и это привнесло бы ещё одну
  переменную.
- **Не пытались** объединить `smoke-m1` cross-build и network-fix в один
  проход. Правило: сначала стабильная адресация, потом бинарь. Обратный
  порядок даёт half-copied ELF + non-repro sha256.

## 10. Ссылки

- Симптом и общая стратегия: [`LOCAL_FLASH.md`](LOCAL_FLASH.md) §1.4
- Целевая политика IP/hostname/MAC: [`LOCAL_FLASH.md`](LOCAL_FLASH.md) §0.5
- M1 факт-файл board-1 после этого фикса:
  [`../smoke/M1_BOARD1_2026-07-04.md`](../smoke/M1_BOARD1_2026-07-04.md)
- Cross-compile рецепт (rustup-stable + rust-lld):
  [`../smoke/M1_RESULTS.md`](../smoke/M1_RESULTS.md) §on-device run 2026-07-04

Anchor: φ² + φ⁻² = 3.
