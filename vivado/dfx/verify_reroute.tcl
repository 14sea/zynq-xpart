# Quick root-cause verification (no RTL change): re-place/route ONLY impl_8 (rm_train
# RM) against the existing diag3 static (impl_1), with timing-driven directives +
# phys_opt enabled. If WNS/WHS jump from the razor-thin 0.103/0.024 ns back to a
# healthy margin AND the board then trains the multi-epoch curve correctly, that
# confirms the divergence is implementation timing marginality (build-to-build route
# variance), not a logic bug. The robust fix (clock↓ / sync reset) comes next session.
set origin [file normalize [file dirname [info script]]]
open_project $origin/build/dfx.xpr
reset_run impl_8
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE       ExtraTimingOpt [get_runs impl_8]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED        true           [get_runs impl_8]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE    AggressiveExplore [get_runs impl_8]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE       AggressiveExplore [get_runs impl_8]
launch_runs impl_8 -to_step write_bitstream -jobs 8
wait_on_run impl_8
puts "=== impl_8 (re-route): [get_property STATUS [get_runs impl_8]] ==="
open_run impl_8
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
puts "=== RE-ROUTE TIMING: WNS=$wns ns  WHS=$whs ns  (was WNS=0.103 WHS=0.024) ==="
report_timing_summary -file $origin/build/impl8_reroute_timing.rpt
foreach b [glob -nocomplain $origin/build/dfx.runs/impl_8/*.bit] { puts "  $b" }
exit
