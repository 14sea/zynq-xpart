# settle_rebuild.tcl — clean BASELINE rebuild for the diag2settle firmware (settle-before-
# forward). Clears any leftover G2/G3 placement hooks so the floorplan is baseline and the
# ONLY variable vs diag2pad is the firmware settle. If the board forward then = {19,2,10,-1},
# the M7.2 divergence is a placement-dependent post-config settle, not the in-context route.
set origin [file normalize [file dirname [info script]]]
open_project $origin/build/dfx.xpr
reset_run synth_1
reset_run impl_1
reset_run impl_8
# strip leftover G2 (impl_8) / G3 (impl_1) TCL.PRE hooks -> baseline floorplan
set_property STEPS.PLACE_DESIGN.TCL.PRE {} [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.TCL.PRE {} [get_runs impl_8]
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "=== impl_1: [get_property STATUS [get_runs impl_1]] ==="
launch_runs impl_8 -to_step write_bitstream -jobs 8
wait_on_run impl_8
puts "=== impl_8: [get_property STATUS [get_runs impl_8]] ==="
foreach b [glob -nocomplain $origin/build/dfx.runs/impl_8/dfx_top.bit] { puts "  $b" }
exit
