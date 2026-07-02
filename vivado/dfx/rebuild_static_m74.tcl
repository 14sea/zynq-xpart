# Rebuild static + impl_5 (cfg5 rm_tpuvpu) with the current IMEM (M7.4 MNIST firmware).
set origin [file normalize [file dirname [info script]]]
open_project $origin/build/dfx.xpr
reset_run synth_1
reset_run impl_1
reset_run impl_5
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "=== impl_1: [get_property STATUS [get_runs impl_1]] ==="
launch_runs impl_5 -to_step write_bitstream -jobs 8
wait_on_run impl_5
puts "=== impl_5: [get_property STATUS [get_runs impl_5]] ==="
exit
