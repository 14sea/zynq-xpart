# Rebuild the static (synth_1 + impl_1) with the new IMEM (diag firmware) + the
# impl_8 full bitstream. The rm_train OOC synth (rm_train_synth_1) is unchanged
# (train_unit not modified), so it is reused.
#   vivado -mode batch -source rebuild_static_diag.tcl
set origin [file normalize [file dirname [info script]]]
open_project $origin/build/dfx.xpr
reset_run synth_1
reset_run impl_1
reset_run impl_8
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "=== impl_1: [get_property STATUS [get_runs impl_1]] ==="
launch_runs impl_8 -to_step write_bitstream -jobs 8
wait_on_run impl_8
puts "=== impl_8: [get_property STATUS [get_runs impl_8]] ==="
foreach b [glob -nocomplain $origin/build/dfx.runs/impl_8/*.bit] { puts "  $b" }
exit
