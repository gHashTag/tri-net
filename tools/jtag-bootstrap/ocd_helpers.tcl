# openOCD-compatible XSDB helpers
proc mask_write {addr mask val} {
    set r [read_memory $addr 32 1]
    set cur [lindex $r 0]
    mww $addr [expr {($cur & ~($mask)) | ($val & $mask)}]
}
proc mask_poll {addr mask} {
    for {set i 0} {$i < 10000} {incr i} {
        set r [read_memory $addr 32 1]
        if {([lindex $r 0] & $mask) != 0} { return }
    }
}
proc mask_delay {args} { after 1 }
proc mwr {args} {
    set addr ""; set val ""
    foreach a $args { if {$a eq "-force"} continue; if {$addr eq ""} {set addr $a} else {set val $a} }
    mww $addr $val
}
proc mrd {args} {
    set addr [lindex $args 0]
    set r [read_memory $addr 32 1]
    return [format "%x" [lindex $r 0]]
}
proc get_number_of_cycles_for_delay {val} { return $val }
proc perf_reset_and_start_timer {} {}
proc configparams {args} {}
proc ps_version {} { return 3 }
