# extract_array_loc.tcl <routed.dcp> <out.xdc> — emit fixed LOC/BEL for every
# placed leaf cell in the systolic array + train_unit, so the good floorplan can
# be frozen and reused regardless of static/firmware size (M7.2 fix option b).
set dcp [lindex $argv 0]; set out [lindex $argv 1]
open_checkpoint $dcp
set fp [open $out w]
puts $fp "# Frozen array placement extracted from a KNOWN-GOOD build (diag2)."
puts $fp "# Apply before impl to make the array P&R invariant to firmware size."
set cells [get_cells -hier -quiet -filter {(NAME =~ *sa_inst/pe_?_?* || NAME =~ *u_tu/*) && IS_PRIMITIVE && LOC != ""}]
set n 0
foreach c [lsort $cells] {
    set loc [get_property -quiet LOC $c]; set bel [get_property -quiet BEL $c]
    if {$loc eq "" || $bel eq ""} continue
    # BEL property is SITE_TYPE.BEL_NAME; xdc BEL needs the BEL_NAME suffix
    set belname [lindex [split $bel .] end]
    puts $fp "set_property LOC $loc \[get_cells {$c}\]"
    puts $fp "set_property BEL $belname \[get_cells {$c}\]"
    incr n
}
close $fp
puts "wrote $n cell LOC/BEL constraints to $out"
exit
