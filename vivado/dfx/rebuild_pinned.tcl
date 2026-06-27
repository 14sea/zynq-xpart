# rebuild_pinned.tcl — re-place/route ONLY impl_8 (rm_train RM) with the array
# placement FROZEN to the known-good diag2 floorplan (apply_array_pins.tcl), against
# the existing (diag2pad/bad-size) static impl_1. M7.2 fix option (b).
#   vivado -mode batch -source rebuild_pinned.tcl
# Static (synth_1/impl_1) is reused — only the RM placement changes, so if the board
# then computes correctly, placement-sensitivity is confirmed and the fix is in hand.
set origin [file normalize [file dirname [info script]]]
open_project $origin/build/dfx.xpr
reset_run impl_8
set_property STEPS.PLACE_DESIGN.TCL.PRE $origin/apply_array_anchors.tcl [get_runs impl_8]
launch_runs impl_8 -to_step write_bitstream -jobs 8
wait_on_run impl_8
puts "=== impl_8 (pinned): [get_property STATUS [get_runs impl_8]] ==="
open_run impl_8
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
puts "=== PINNED TIMING: WNS=$wns WHS=$whs ==="
foreach b [glob -nocomplain $origin/build/dfx.runs/impl_8/*.bit] { puts "  $b" }
exit
