# Measured facts

Every number here is produced by a testbench in this directory and is
re-derived by `./sim.py --facts`. Nothing in this file is typed in by
hand -- it is generated from the table in `sim.py`, so the document
and the check cannot disagree.

A number that changes is not a number to update here. It means the
design changed, and the reason column says what would have to be true
for the new value to be right.

| value | claim | bench | why this value and not another |
|---|---|---|---|
| `1` | correlator pipeline lag | `corr_tops` | the registered output reflects the window ending one sample back; measured independently on the 8-tap and 63-tap designs and equal on both |
| `600` | matched-filter peak, TX to RX loop | `tx_rx_loop` | the TX->RX loop closes and the peak's sign follows the data bit; this figure does NOT witness the carrier's structure, because both sides of the loop share one definition |
| `6` | non-zero carrier entries per period | `nco` | sign(cos(2*pi*k/8)) is zero at k=2 and k=6; measured on the generator's own output, which is why this one does move when the carrier table is altered |
| `63` | PN processing gain | `pn_despread` | a 63-chip m-sequence gives peak/off-peak of exactly N |
| `-100` | PN autocorrelation sidelobe | `pn_despread` | an m-sequence has a flat sidelobe of -A at every non-zero shift |
| `6300` | tree despreader peak | `corr_tree` | N*A = 63*100 |
| `6300` | streaming despreader peak | `corr_stream` | the same figure from an implementation sharing no code |
| `256` | throughput harness comparisons | `speed_harness` | the fabric ROM holds 256 samples; a pass comparing fewer is not a full pass and its throughput figure would not stand |
| `2688` | pipelined vs combinational correlator agreement | `corr_equiv` | 8 tap sets x 336 comparisons, all exact, between two implementations sharing no code |
| `859` | dot-product core agreement | `dot27_equiv` | random corpus plus the -128 negation asymmetry and a single-weight sweep across all 27 positions |
| `131` | correlator boundary cases | `corr_bounds` | includes the case where negating -32768 before widening returns the input unchanged |
| `63` | golden vector, fully-determined outputs | `verify_in_datapath.py` | every output whose window lies entirely inside the capture. Reports before cycle 73 said 65: the per-sample lag added in cycle 44 can be 2, which makes outputs 0..64 depend on samples taken before recording began, not 0..62. The check became narrower and more correct; the published figure was never recomputed, and this table is what caught it |
| `128961` | golden vector, matched-filter peak | `verify_in_datapath.py` | 63*2047, the accumulator's true maximum for a 63-tap matched filter at full chip amplitude |
| `1291` | MAC top-level checks | `mac_tops` | all 256 sample values against three weight codes, on two designs at once |

## Stated from hardware, and not re-derivable today

These came from runs on the board. The board has been unreachable
since cycle 52, so none of them can be re-derived the way the table
above can. They are listed with what would be needed to restate them,
because a number nobody can reproduce should say so on its face.

| value | claim | how it was obtained | what it would take to restate |
|---|---|---|---|
| `83.3 MHz` | standalone correlator Fmax, silicon | swept on the board until the self-test failed | the board, and `ps7_speed` |
| `50 MHz` | correlator in the vendor datapath, clean | rate sweep with a fabric clock divider | the board, and `ps7_ad9361_rate` |
| `62 of 64` | outputs matching at 62.5 MHz | the same sweep | the board; and note this was under the constant-lag reading, which cycle 44 showed to be wrong at that rate |
| `256 of 256` | bit-exact at 8 and 63 taps | one sample per devmem write | the board |
| `1219` | sample pairs bit-exact in the datapath | accumulated over several captures | the board |

One hardware result did survive: the golden vector, in the table
above. It survived because the capture was committed to the
repository rather than left in `/tmp` -- unlike the vendor bitstream,
which was not, and is gone.

## Not measured anywhere yet

The receive path on real pins. `realpin` verifies the design is
correct when a signal arrives; that a signal arrives at all needs the
control plane, which needs pins this project has not identified.

