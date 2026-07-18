# Continuous evolving stream over the air (2026-07-18)

Last wave's "live source" was discrete ticks -- restart the cyclic TX buffer per message. This
wave is ONE continuous, NON-repeating stream fed once through a non-cyclic writer: the receiver
catches a live run of unique evolving frames deep inside the stream -- a real telemetry / file
stream, not a repeating buffer.

## Framing

New modes `otatxstream` / `otarxstream`. Each frame's 8-byte payload = `seq:u16 LE ++ 6-byte
ASCII "{:06}" of seq` (self-verifying: the value IS the frame's sequence number in decimal).
`.13` generated 4000 unique frames (seq 0..3999, 82 MB, ~15 s to synthesise on the ARM) and
streamed them ONCE via `iio_writedev -b 51200` with NO `-c` -- a ~667 ms continuous burst that
never repeats.

## What the receiver caught

`.12` captured a 524288-sample window during the stream and reassembled a live run:

```
best   : seen=100 verified=99  corrupt=1  seq_run=[1560..1659]  drops=1   (1%)
run2   : seen=84  verified=83  corrupt=1  seq_run=[1581..1681]  drops=18
run3   : seen=64  verified=55  corrupt=9  seq_run=[1547..1643]  drops=42
values : "001560","001561","001563",...,"001659"   <- gap at 1562 is the 1 drop
```

The runs sit deep in the stream (seq ~1550, not seq 0) -- proof the source was continuously
streaming non-repeating data and `.12` reassembled a live evolving slice by sequence number,
each frame's value verified against its seq. The consistent ~1550 offset is just the fixed
ssh-to-capture latency (~250 ms into a 667 ms stream ~= frame 1500).

## Honest, important finding: streaming exposes the raw link FER

Earlier waves recovered messages cleanly because the small cyclic buffer let the receiver
MAJORITY-VOTE over many repeats of each frame. A single-pass stream has NO repeats, so the raw
per-frame error rate of the .13->.12 link shows through directly -- 1% on a good capture, up to
~40% on a bad one (SNR varies). This is not a regression; it is the true link quality that
majority-voting was hiding. It is exactly why a real streaming link needs per-frame FEC
(`tri_fec` interleaved across frames) or a small repeat factor -- the robustness next step.

## Scientific picture

The tick-relay was a photo of a sign, re-shot when it changed. This is a live broadcast: the
source keeps emitting new, numbered readings, and the receiver tunes in mid-stream and follows
along, checking each reading's number as it arrives. If one reading is garbled it is simply
dropped (a gap in the numbers), like a dropped video frame -- the stream keeps flowing. And the
gaps MEASURE the channel: a 1% drop is a clean link, 40% a marginal one, with no averaging to
paper over it.

## Boundary

- Pre-generated 4000-frame stream (a true real-time ARM producer can't feed 30.72 MSa/s); but
  the stream is continuous and non-repeating, which is the point.
- No FEC/repeat yet -> drops = raw link FER (1-40% here). FEC is the next step.
- DSP mod/demod is scratchpad Rust in relay_meter; the receipt it seals IS t27 (tri_depin).

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, IQ removed.
