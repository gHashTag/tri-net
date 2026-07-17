# Wave v0.16 — what the node actually carries, measured

Wave v0.15 recommended two things: point the real app at the bridge (1), then
measure the node (2). Option 1 needs the iPhone attached and it is not
(`devicectl list devices` is empty), so this wave did option 2 — and it corrected
a false claim I made in the last report.

## The correction first

`WAVE_REPORT_v0.15.md` said of the node's receive-buffer overflow:

> *Separate finding: the node's rx buffer overflows under burst and nothing
> reports it.*

**That is false.** The kernel has counted every one of those drops all along:

```
$ grep '^Udp:' /proc/net/snmp
Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors ...
Udp:      1409      76      420      3855          420
```

`RcvbufErrors = 420` — the exact drops from the experiment I described as
unreported. The instrument existed; I did not look. This is the same rule I broke
earlier in that same wave (*"RTFM before reverse-engineering"*, `SOUL.md` Art.
VIII), twice in one session. v0.15 is corrected in place rather than left with a
second truth appended next to the first.

## What the node carries

Sustained 3s per rate, 700B datagrams (10 fragments each), rate limiter lifted
out of the way so this measures the **node**, not the policy. Ground truth is the
kernel's counter, not this script's arithmetic:

| offered/s | kernel got | rcvbuf drops | relayed | loss | frags/s out |
|---:|---:|---:|---:|---:|---:|
| 400 | 1207 | 0 | 1200 | 0.0% | 4 000 |
| **800** | **2404** | **0** | **2400** | **0.0%** | **8 000** |
| 1000 | 2950 | 50 | 2950 | 1.7% | 9 833 |
| 1200 | 3457 | 143 | 3457 | 4.0% | 11 523 |
| 1600 | 4372 | 428 | 4372 | 8.9% | 14 573 |
| 2400 | 5897 | 1303 | 5897 | 18.1% | 19 657 |

**The node sustains 800 datagrams/s = 8000 fragments/s ~= 4.8 Mbps with zero
loss.** The knee is between 800 and 1000.

`relayed == kernel got` at **every** rate, including 2400/s: the bridge relays
everything the kernel hands it and loses nothing of its own. All loss above the
knee is the kernel dropping what the bridge was too slow to collect.

### The number that matters

`FRAG_RATE_PER_SEC = 800` is **fragments** per second — 480 kbps. The node does
**8000 fragments/s**. So the default rate limit sits **10x below the hardware**,
and a video call (~100 datagrams/s) sits ~8x below the node's ceiling.

**The node is not the bottleneck and never was.** The limiter is a guess about the
*radio*, and it should be set from the radio's measured capacity when a radio
exists — not from caution about the board.

## Three hypotheses, three refutations

Worth recording, because being wrong three times is what produced the actual
answer:

1. **"The receive buffer is too small."** Raised `rmem_default`/`rmem_max` 8x
   (180 KB -> 1.4 MB, runtime only). At 1600/s: 8.9% -> 7.7%. At 2400/s: 18.1% ->
   20.3%. **No effect.** Obvious in hindsight: buffer size absorbs a *burst*; in
   sustained overload only the drain rate matters. The board was restored to stock
   180224 afterwards.
2. **"The per-NAL `println!` is the cost."** 800 log lines/s to flash on a
   667MHz part is a plausible suspect. Same node, same rmem, only the log
   destination changed to `/dev/null`: 1600/s -> 9.1% (was 8.9%), 2400/s -> 20.4%
   (was 18.1%). **No effect.**
3. **"The cost is per fragment"** (10 `sendto` per datagram). Decisive test:
   60B datagrams costing **one** fragment each. If the ceiling were in fragments,
   2400 datagrams/s = 2400 frags/s would be far under the proven 8000 and lose
   nothing. Measured: 800/s -> 0%, 2400/s -> **10.5%**, 6000/s -> 12.4%.
   **Refuted.**

So the ceiling is **per datagram**, in the receive loop itself — not the buffer,
not the log, not the fragment count.

### Latent, deliberately not fixed

The receive loop calls `set_read_timeout` on **every iteration** (a `setsockopt`
syscall per datagram, both threads), plus an `Instant::now()` and an O(n)
`reassembly.retain()` scan. That is real waste in exactly the path the
measurement points at.

It is **not** being fixed: the node already has ~8x headroom over a video call
and ~10x over the rate limiter. Optimising an 800/s ceiling that nothing
approaches would be speculative work. Revisit only if a radio ever proves fast
enough to need it — at which point the measurement above is the baseline to beat.

## Option 1 status: blocked on the phone, not on code

Pointing the real app at the bridge needs **no app change at all**, which is the
good news: the app sends to and listens on the same port (7000) and takes the
peer address from a UI text field. Set `VIDEO_OUT_PORT=7000` on each node and
type the local node's IP into the field instead of the far device's:

```
Mac --(:7000)--> [.11] --(:5000)--> [.12] --(:7000)--> iPhone
iPhone --(:7000)--> [.12] --(:5000)--> [.11] --(:7000)--> Mac
```

Both nodes are running in exactly this configuration right now. Verified along
the way:

- The handshake survives it — `MeshCrypto` is role-free (X25519 is symmetric,
  "no role negotiation is needed"), so it does not matter which side speaks first.
- The transport does not filter by source address in 1-1 mode, so a datagram
  arriving from the node rather than the far device is accepted.
- Each node learns its device from ingress, so no address needs configuring.

What is missing is only the iPhone being attached and someone typing an IP into
two text fields.

## Honest status

Unchanged from v0.15 on the thing that matters: **the radio has never carried a
byte**, because two working AD9361s have never existed at once (`.11` has no
radio, `.12` has one, `.13` is off the network). Everything measured here is the
node around a link that does not exist. The good news this wave adds is that when
a link does exist, the node will not be what limits it.

## Three options for the next wave

### 1. The real app across the mesh (needs your hands for ~2 minutes)
Attach the iPhone by USB (or just type `192.168.1.11` into the Mac's Remote IP
field and `192.168.1.12` into the iPhone's, and press Start on both). The nodes
are already configured and waiting. This is the first time the product itself
would cross the mesh. Expect one real obstacle: the app fragments at 1200B and
the bridge re-fragments each piece into 18 x 70B, so one lost VSTREAM fragment
kills an app fragment **and then** the whole NAL — double all-or-nothing. The
app's XOR-FEC exists for this and is currently gated off.

### 2. Make the loss recoverable instead of catastrophic (software, unblocked)
The double-fragmentation above is the next real defect, and it does not need a
phone to work on: give the bridge its own FEC or ARQ across the 70-byte fragment
layer, so a single lost fragment does not destroy a whole NAL. This is the
difference between "the mesh works on a clean bench" and "the mesh works in a
field", and it is the layer a radio will actually stress.

### 3. The radio (blocked on you, unchanged)
Cold power cycle `.11` on dedicated power, not the shared USB hub. Bring `.13`
back onto the network. If a second AD9361 comes up, the cabled SMA + 30-40 dB
attenuator link is the last missing layer.

**Recommendation: 2.** Option 1 is two minutes of your time and I cannot do it
alone; option 3 is hands. Option 2 is the real engineering left, it is unblocked,
and this wave's numbers say it is the right thing to harden — the node has
capacity to spare, so spending it on redundancy costs nothing that matters.
