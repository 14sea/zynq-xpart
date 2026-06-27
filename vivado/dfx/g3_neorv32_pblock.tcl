# g3_neorv32_pblock.tcl — impl_1 PLACE_DESIGN.TCL.PRE hook (G3 fix attempt).
# NEORV32 already places in clock region X0Y0, but its internal routing strays into
# X1Y0 (the RP) — the proven static-through-RP mechanism. Confine NEORV32 to the LEFT
# clock-region column (X0Y0:X0Y1) and CONTAIN its routing so static no longer bleeds
# into the RP region (X1Y0). RP-interface nets still cross normally (one endpoint in RP).
if {[llength [get_pblocks -quiet pblock_neorv32]] == 0} {
    create_pblock pblock_neorv32
}
add_cells_to_pblock [get_pblocks pblock_neorv32] [get_cells u_soc/neorv32_inst]
resize_pblock [get_pblocks pblock_neorv32] -add {CLOCKREGION_X0Y0:CLOCKREGION_X0Y1}
set_property CONTAIN_ROUTING true [get_pblocks pblock_neorv32]
puts "== G3: pblock_neorv32 = CLOCKREGION_X0Y0:X0Y1 + CONTAIN_ROUTING (keeps static out of RP X1Y0) =="
