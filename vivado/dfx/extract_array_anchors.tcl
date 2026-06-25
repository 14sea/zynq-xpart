# extract_array_anchors.tcl <routed.dcp> <out.tcl> — emit LOC+BEL for ONLY the
# conflict-free anchor cells of the array+train_unit: DSP48 (one per site) and all
# flip-flops (FD*, distinct FF BELs, no LUT-combine). LUTs are left free so place_design
# legalizes combinational logic around the frozen anchors. M7.2 fix (b), robust variant.
set dcp [lindex $argv 0]; set out [lindex $argv 1]
open_checkpoint $dcp
set fp [open $out w]
puts $fp "# Frozen array ANCHORS (DSP + FF) from the known-good diag2 build."
set cells [get_cells -hier -quiet -filter {(NAME =~ *sa_inst/pe_?_?* || NAME =~ *u_tu/*) && IS_PRIMITIVE && (REF_NAME =~ DSP48* || REF_NAME =~ FD*) && LOC != ""}]
set n 0
foreach c [lsort $cells] {
    set loc [get_property -quiet LOC $c]; set bel [get_property -quiet BEL $c]
    if {$loc eq "" || $bel eq ""} continue
    set belname [lindex [split $bel .] end]
    puts $fp "set_property LOC $loc \[get_cells {$c}\]"
    puts $fp "set_property BEL $belname \[get_cells {$c}\]"
    incr n
}
close $fp
puts "wrote $n anchor (DSP+FF) constraints to $out"
exit
