# Routing metric: SNR-aware, loop-free, flap-resistant path selection

A spec-first routing-metric stack that lets a drone-mesh node pick the fastest
loop-free path and hold it stable. Four `.t27` specs, each generated to Rust (host)
and Verilog/C/Zig (FPGA) by `t27c`, machine-verified by property tests over the
generated code. It reuses the same SNR/MCS link adaptation as the FEC pipeline
(see FEC_PIPELINE.md), so the physical link quality drives route choice.

## Problem and approach

Hop-count routing ignores link quality; a two-hop clean path can beat a one-hop
marginal one, and vice versa. This stack layers four well-founded ideas:

1. **ETT, not ETX.** ETX (Couto et al., SIGCOMM 2003) counts (re)transmissions but
   not link speed. ETT (Draves et al., MobiCom 2004) divides ETX by the link rate,
   and the rate is the adaptive-MCS decision -- so SNR feeds the metric.
2. **WCETT for channel diversity.** Hops on the same channel serialise; WCETT adds
   a bottleneck term so channel-diverse paths (which parallelise) win.
3. **Loop-free feasibility.** A neighbor becomes a next hop only if strictly closer
   to the destination (Babel RFC 8966 / EIGRP DUAL) -- no count-to-infinity.
4. **Switch hysteresis.** A route is held until an alternative is clearly better,
   mirroring the MCS hysteresis -- near-equal paths do not flap.

## Pipeline

```
  SNR --adaptive_mcs--> modulation --mcs_rate_x2--> link rate
        |                                               |
   ETX  |                                               v
        +----------------> ett_metric.link_ett_x100 = ETX * 2 / rate
                                        |
                 hops (ett, channel)    v
                        +------> wcett.wcett3 = (1-b)*sum + b*max_channel(sum)
                                        |
                current cost, candidate v
   neighbor/feasible distance -> routing_capstone.adopt_from_distances
                        |                    |
                        v                    v
              route_select.feasible   hysteresis (margin)
                        \____________________/
                                 |
                                 v
                        switch (1) or hold (0)
```

## Module map (4 specs)

- `ett_metric` -- `link_ett_x100` (ETX*2/mcs_rate_x2, composes adaptive_mcs),
  `link_ett_from_snr`, `path_ett_x100` (additive), `prefer_a`.
- `wcett` -- `channel_load3` (ETT on a channel), `max3`, `bottleneck3` (busiest
  channel's serialised time), `wcett3` (beta in x100).
- `route_select` -- `route_ett2` (composes ett_metric), `path_ett3`, `best2/best3`
  (lowest ETT), `pick2` (argmin index), `improves`, `feasible` (loop-freedom).
- `routing_capstone` -- `link_cost`/`path_cost` (compose ett_metric + wcett),
  `should_adopt` (feasible AND cheaper by > hysteresis), `adopt_from_distances`
  (composes route_select). The end-to-end decision.

## Machine-verified integration invariants

- **ETT flips ETX:** a link with worse ETX (1.5) on QPSK beats a better-ETX (1.2)
  BPSK+FEC link (ETT 75 vs 240) -- plain ETX would pick the slower route.
- **WCETT rewards diversity:** two paths of equal total ETT (180), the
  channel-diverse one has the lower WCETT (120 vs 180 at beta 0.5); a sweep shows
  WCETT always in [bottleneck, total] and a diverse path never worse.
- **Feasibility is loop-free:** only a strictly-closer neighbor is admitted (equal
  or farther rejected) -- monotone progress.
- **Selection is argmin:** pick2 returns the lowest-cost path over a full sweep.
- **Hysteresis kills flapping:** a no-flap sweep confirms every candidate within
  [cur - margin, cur] is held; only a gain beyond the margin switches; an
  infeasible candidate is never adopted however cheap.

## Scientific grounding

- ETX: Couto, Aguayo, Bicket, Morris -- SIGCOMM 2003.
- ETT / WCETT: Draves, Padhye, Zill -- MobiCom 2004.
- Loop-free feasibility: Babel (RFC 8966) / EIGRP DUAL.
- Rate adaptation / hysteresis: Bianchi, IEEE J-SAC 2000 (802.11-style).

## Boundaries

- Paths are modelled at fixed small sizes (2-3 hops) because t27 has no arrays;
  the metric is per-hop-additive, so longer paths extend the same way.
- Per-link ETX is assumed available (from etx.t27 delivery-ratio tracking); this
  stack consumes it and adds rate/diversity/stability.
- Topology discovery and the neighbor table are out of scope -- this is the metric
  and the decision, not the protocol wire format.
- All logic is generated from the specs; `gen/` is rebuilt by build.rs. The specs
  and the pending t27c codegen fixes live on `codegen-clean`, not yet
  resealed/merged to master (a coupled step; see t27
  docs/PARSE_SILENT_DROP_AUDIT.md).

phi^2 + 1/phi^2 = 3 | TRINITY
