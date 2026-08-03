# The AD9361 pinout on this board: what is known and what is not

Loading the `axi_ad9361` bitstream needs this board's actual AD9361 pin
assignment. The harness that placed and routed used 30 pins picked arbitrarily
from banks 34 and 35 -- fine for measuring place-and-route, unsafe to load,
because 16 of them are outputs and none was checked against the schematic.

## The published pinout is for a different part

ADI publishes `projects/pluto/system_constr.xdc`, and it has exactly what is
wanted:

```
set_property -dict {PACKAGE_PIN L12 IOSTANDARD LVCMOS18} [get_ports rx_clk_in]
set_property -dict {PACKAGE_PIN N13 IOSTANDARD LVCMOS18} [get_ports rx_frame_in]
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS18} [get_ports rx_data_in[0]]
...
```

**It cannot be used.** `projects/pluto/system_project.tcl` targets
`xc7z010clg225-1`; this board is `xc7z020clg400`. Different die, different
package, different pin names. Two other things in that file are worth carrying
across regardless: the bus is **LVCMOS18**, not the LVCMOS33 the harness
assumed, and the interface is CMOS rather than LVDS -- which matches what
`CMOS_OR_LVDS_N 1` in the Pluto build already told us.

Copy kept at `results/pluto_reference_constr.xdc` for the signal names and
standards, not for the pin numbers.

## The board's own bitstream is extractable, and that is the real answer

The board identifies itself in its FIT image as **"7PUZHI PZSDR P201MINI"**
with a `zynq-pluto-sdr` device tree -- a Pluto-compatible design on different
silicon, so the vendor bitstream is the only authority on its pinout.

It is readable, non-destructively:

```
/proc/mtd: mtd3 "qspi-linux", 0x01e00000
bitstream sync 0xAA995566 at byte 0xE060 of mtd3
dd if=/dev/mtd3ro bs=4096 skip=14 count=990     # NOT bs=1 -- that crawls
```

`bitread` parses the extracted payload: **5 600 configuration frames, 5 479 of
them with set bits.**

## Where this stopped, and why

Turning those frames into a pin list means disassembling the IOB tiles and
mapping tile plus site back through `package_pins.csv`. The frames are in hand;
the query against prjxray's grid API returned nothing on the first attempt,
which means the block-type key or the tile-type filter is wrong -- an API
detail, not a conceptual obstacle.

That is a few debugging steps, and they were not taken here because the
alternative was to start guessing at an answer whose whole purpose is to avoid
guessing. A pinout that is *probably* right is worth nothing: it is exactly the
input that turns a working bitstream into contention on somebody's board.

**Next step, concretely:** enumerate `grid.tiles()` filtered to IOB tile types,
read each one's `bits` block descriptor for the correct block type key, and
intersect its frame range with the set-bit map already built. Then join to
`package_pins.csv` on tile plus site.

---

## The pinout question, answered enough to matter

The vendor bitstream was extracted from `mtd3` and analysed two independent
ways. Both give the same number, and a control design pins the method down.

| method | IOB tiles carrying configuration |
|---|---|
| counting set bits in each IOB tile's frame range | **78** |
| `FasmDisassembler.find_features_in_bitstream` | **78** |
| **control: our portless `ps7_pn_tree`** | **0** |

The control matters as much as the agreement: a design that declares no ports
produces zero IOB configuration, so the method detects real usage and does not
manufacture it.

Used sites by bank: **bank 34 = 50, bank 35 = 50, bank 13 = 25**.

The densest tiles form contiguous runs that read like a bus. `RIOB33_X73Y57`
through `Y69` is seven tiles, fourteen sites -- `V18 V17 R18 T17 R17 R16 W16
V16 Y19 Y18 W20 V20 U20 T20` -- which is the shape of twelve data lines plus
frame plus clock. A second run in bank 35, `Y133`-`Y143`, gives twelve.

## The finding that justifies not having loaded anything

The place-and-route harness assigned 30 pins picked from banks 34 and 35 in
`package_pins.csv` order, on the reasoning that any valid pins would do for
measuring placement.

**All 30 collide with pins the vendor design drives.**

```
A20 B19 B20 C20 D18 D19 D20 E17 E18 E19 F16 F17 F19 F20 G15 G17 G18 G19 G20
H15 H16 H17 H18 H20 J14 J16 J18 J19 J20 K14
```

Sixteen of those thirty are **outputs** in that harness. Loading it would have
driven them onto pins wired to the AD9361 and to whatever else sits on those
banks. The earlier decision to verify by round-trip instead of by loading was
made on the general principle that an unchecked pinout is unsafe; this is that
principle turning out to be concretely true.

## What is still not established

**Per-pin direction.** The obvious heuristic -- treat a tile as an output if it
carries `DRIVE` or `SLEW` features -- classifies all 78 as outputs, which cannot
be right: the receive bus must be inputs. So those features are evidently
emitted for configured IOBs regardless of direction, and the real indicator is
something else in the decoded feature set.

Until direction per pin is known, the pin *set* is not enough to build a safe
constraint file: assigning an output to a pin the AD9361 drives is exactly the
contention this whole exercise exists to avoid. The remaining work is to read
the IOB33 segbits documentation for the feature that actually distinguishes
input from output, rather than to guess a third time.
