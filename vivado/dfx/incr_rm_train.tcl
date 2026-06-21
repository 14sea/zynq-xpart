# Incremental rebuild of ONLY the rm_train RM + impl_8 (M7.2), reusing the cached
# locked static (impl_1) and the already-built rm_tpuvpu (impl_5). Used after a
# train_unit.v-only change (e.g. the DSP→shift leaky' fix) so we don't re-run the
# ~30 min static synth/impl.
#   vivado -mode batch -source incr_rm_train.tcl
set origin [file normalize [file dirname [info script]]]
open_project $origin/build/dfx.xpr
reset_run rm_train_synth_1
reset_run impl_8
launch_runs impl_8 -to_step write_bitstream -jobs 8
wait_on_run impl_8
puts "=== impl_8 (cfg8 rm_train): [get_property STATUS [get_runs impl_8]] ==="
if {[get_property PROGRESS [get_runs impl_8]] eq "100%"} {
  open_run impl_8
  report_utilization -file $origin/build/impl8_util.rpt
  report_drc        -file $origin/build/impl8_drc.rpt
  puts "=== impl_8 reports: $origin/build/impl8_util.rpt , $origin/build/impl8_drc.rpt ==="
}
puts "=== rm_train bitstreams ==="
foreach b [glob -nocomplain $origin/build/dfx.runs/impl_8/*.bit] { puts "  $b" }
exit
