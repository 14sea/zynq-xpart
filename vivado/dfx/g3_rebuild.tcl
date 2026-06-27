# g3_rebuild.tcl — rebuild static (impl_1) + RM (impl_8) for the BAD (diag2pad) case
# with the NEORV32 confined to the left column (g3_neorv32_pblock.tcl). synth_1 reused
# (firmware unchanged = diag2pad). If the board then computes {19,2,10,-1}, keeping the
# static out of the RP cures the M7.2 divergence (G3 = the real fix).
set origin [file normalize [file dirname [info script]]]
open_project $origin/build/dfx.xpr
reset_run impl_1
reset_run impl_8
set_property STEPS.PLACE_DESIGN.TCL.PRE $origin/g3_neorv32_pblock.tcl [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "=== impl_1: [get_property STATUS [get_runs impl_1]] ==="
launch_runs impl_8 -to_step write_bitstream -jobs 8
wait_on_run impl_8
puts "=== impl_8: [get_property STATUS [get_runs impl_8]] ==="
foreach b [glob -nocomplain $origin/build/dfx.runs/impl_8/dfx_top.bit] { puts "  $b" }
exit
