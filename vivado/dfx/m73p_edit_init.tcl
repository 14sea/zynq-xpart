# M7.3+ checkpoint-to-fabric: produce a CLEAN single-netlist w45 partial by editing
# only the PE[0][0] weight-LUT6 INITs in the ROUTED impl_7 checkpoint (NOT a rebuild).
# The 8 weight bits are dont_touch LUT6s (INIT[0]=weight bit), already placed/routed;
# changing INIT is a property edit (no re-place/route), so the resulting partial differs
# from the impl_7 baseline by EXACTLY the edited INIT bits -> a clean controlled-diff for
# the on-board ICAP frame-write. PE[0][0]: 1 (0b00000001) -> 45 (0b00101101) = set bits 2,3,5.
set origin [file normalize [file dirname [info script]]]
set run    $origin/build/dfx.runs/impl_7
open_checkpoint $run/dfx_top_routed.dcp

set pe {*g_row[0].g_col[0].pe_i*}
puts "=== PE[0][0] weight LUT6 cells (name / BEL / INIT) ==="
foreach c [lsort [get_cells -hier -filter "NAME =~ ${pe}g_wbit*wlut*"]] {
    puts [format "  %-70s  BEL=%-22s INIT=%s" $c \
        [get_property BEL [get_cells $c]] [get_property INIT [get_cells $c]]]
}

# set INIT[0]=1 for bits 2,3,5 (the bits that differ between weight 1 and 45).
foreach b {2 3 5} {
    set c [get_cells -hier -filter "NAME =~ ${pe}g_wbit\[$b\].wlut*"]
    set_property INIT 64'h0000000000000001 [get_cells $c]
    puts "  set bit$b: $c -> INIT=[get_property INIT [get_cells $c]]"
}

puts "=== after edit: PE\[0\]\[0\] weight should now read 45 (bits 0,2,3,5) ==="
foreach c [lsort [get_cells -hier -filter "NAME =~ ${pe}g_wbit*wlut*"]] {
    puts [format "  %-70s INIT=%s" $c [get_property INIT [get_cells $c]]]
}

write_bitstream -force -file $origin/m65_icap/dfx_top_w45edit.bit
puts "=== wrote partial(s) next to m65_icap/dfx_top_w45edit*.bit ==="
exit
