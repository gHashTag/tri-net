# synth_vivado.tcl — Ratchet 2/4 synth via Xilinx Vivado (batch mode).
#
# Alternative path for hosts that have Vivado 2020.2+ installed (macbook
# ssdm4). openXC7 is preferred for open-hardware discipline, but Vivado
# gives a canonical WNS/TNS number for the Ratchet-2 gate.
#
# Usage:
#   vivado -mode batch -source scripts/synth_vivado.tcl
#
# Ratchet 2/4 gate:
#   - synth_design completes with 0 errors
#   - place_design + route_design complete
#   - report_timing_summary shows WNS >= -0.5 ns
#
# phi^2 + phi^-2 = 3

set ROOT [file normalize [file dirname [info script]]/..]
set BUILD $ROOT/build
file mkdir $BUILD

create_project -force -in_memory -part xc7a200tfbg484-2

add_files $ROOT/dna_reader.v
read_xdc  $ROOT/constraints/dna_reader_ax7203.xdc

synth_design -top dna_reader -part xc7a200tfbg484-2
write_checkpoint -force $BUILD/post_synth.dcp
report_utilization -file $BUILD/utilisation.rpt
report_timing_summary -file $BUILD/timing_synth.rpt

opt_design
place_design
route_design

write_checkpoint -force $BUILD/post_route.dcp
report_timing_summary -file $BUILD/timing_route.rpt

# Extract WNS for the Ratchet-2 gate
set fd [open $BUILD/timing_route.rpt r]
set contents [read $fd]
close $fd
if {[regexp {WNS\(ns\)\s+=\s+([-0-9.]+)} $contents _ wns]} {
    puts "RATCHET2 WNS = $wns ns"
    set ok [expr {$wns >= -0.5}]
    if {$ok} {
        puts "RATCHET2 PASS"
    } else {
        puts "RATCHET2 FAIL (WNS too negative)"
    }
} else {
    puts "RATCHET2 UNKNOWN (could not parse WNS)"
}
