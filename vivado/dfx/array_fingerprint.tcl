# array_fingerprint.tcl — dump a diffable place+route fingerprint of the systolic
# array (and train_unit DSP) from a routed DFX checkpoint. Run once per DCP:
#   vivado -mode batch -source array_fingerprint.tcl -tclargs <routed.dcp> <out.txt>
# Then `diff good.txt bad.txt` to see exactly what P&R shifts between builds.
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set fp [open $out w]

proc netsig {fp net} {
    # compact, deterministic routing signature of a net
    if {$net eq "" || [llength $net] == 0} { puts $fp "    (no net)"; return }
    set n [llength [get_nodes -quiet -of_objects $net]]
    set p [llength [get_pips  -quiet -of_objects $net]]
    set st [get_property -quiet ROUTE_STATUS $net]
    puts $fp "    net=[get_property NAME $net] status=$st nodes=$n pips=$p"
}

# ---- 1. every DSP48: placement + cascade wiring (sorted = comparable) ----
set dsps [lsort [get_cells -hier -filter {PRIMITIVE_TYPE =~ *DSP* || REF_NAME =~ DSP48*}]]
puts $fp "==== DSP48 cells: [llength $dsps] ===="
foreach c $dsps {
    set loc  [get_property -quiet LOC $c]
    set bel  [get_property -quiet BEL $c]
    # cascade pins: is PCOUT driven / PCIN sourced?
    set pcout [get_nets -quiet -of [get_pins -quiet $c/PCOUT*]]
    set pcin  [get_nets -quiet -of [get_pins -quiet $c/PCIN*]]
    set pout  [get_nets -quiet -of [get_pins -quiet $c/P*]]
    puts $fp "DSP $c"
    puts $fp "    LOC=$loc BEL=$bel"
    puts $fp "    USE_SIMD=[get_property -quiet USE_SIMD $c] AREG=[get_property -quiet AREG $c] BREG=[get_property -quiet BREG $c] PREG=[get_property -quiet PREG $c] USE_DPORT=[get_property -quiet USE_DPORT $c]"
    set pcN [llength $pcout]; set piN [llength $pcin]
    puts $fp "    PCOUT_driven=[expr {$pcN>0}] PCIN_sourced=[expr {$piN>0}]"
    if {$pcN>0} { puts $fp "  PCOUT:"; netsig $fp $pcout }
    if {$piN>0} { puts $fp "  PCIN :"; netsig $fp $pcin }
}

# ---- 2. systolic psum (p_*) and x (x_w_*) cascade nets ----
puts $fp "\n==== inter-PE cascade nets ===="
set pnets [lsort [get_nets -hier -quiet -filter {NAME =~ *pe_*psum_out* || NAME =~ *p_?_? || NAME =~ *x_w_?_? || NAME =~ *x_out*}]]
puts $fp "matched [llength $pnets] cascade-ish nets"
foreach nt $pnets { netsig $fp [get_nets $nt] }

# ---- 3. PE psum_out registers: placement ----
puts $fp "\n==== PE psum/x registers (FDRE/FDCE) ===="
set ffs [lsort [get_cells -hier -quiet -filter {(NAME =~ *pe_?_?* ) && (REF_NAME =~ FD*)}]]
foreach c $ffs { puts $fp "FF $c LOC=[get_property -quiet LOC $c] BEL=[get_property -quiet BEL $c]" }

# ---- 4. RP pblock + partition pin routing summary ----
puts $fp "\n==== route status summary ===="
puts $fp [report_route_status -return_string]

# ---- 5. timing: worst paths inside the RP ----
puts $fp "\n==== worst 5 setup paths (whole design) ===="
foreach pth [get_timing_paths -max_paths 5 -nworst 1 -delay_type max] {
    puts $fp "  slack=[get_property SLACK $pth] from=[get_property STARTPOINT_PIN $pth] to=[get_property ENDPOINT_PIN $pth]"
}
close $fp
puts "fingerprint written: $out"
exit
