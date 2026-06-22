# Completing the root-cause verification: re-place/route the STATIC (impl_1) too,
# with timing-driven directives + phys_opt (synth unchanged → still the diag3
# firmware/netlist), then re-implement impl_8 against it. The earlier RM-only
# re-route did NOT fix the board AND gave bit-identical wrong values across routes,
# so the marginal path is on the STATIC side (NEORV32↔RP XBUS / DFX boundary), which
# impl_8 can't touch. If a better-timed static makes the board train correctly, that
# pins it to static-side timing marginality → next session's fix = clock↓ (relaxes
# static+RP+boundary at once). If it stays wrong, it is NOT static-route variance.
set origin [file normalize [file dirname [info script]]]
open_project $origin/build/dfx.xpr
reset_run impl_1
reset_run impl_8
foreach r {impl_1 impl_8} {
  set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE    ExtraTimingOpt    [get_runs $r]
  set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED     true              [get_runs $r]
  set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs $r]
  set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE    AggressiveExplore [get_runs $r]
}
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
set w1 [get_property SLACK [get_timing_paths -delay_type max -nworst 1]]
set h1 [get_property SLACK [get_timing_paths -delay_type min -nworst 1]]
puts "=== STATIC impl_1 re-route: WNS=$w1  WHS=$h1  (was WNS~0.10) ==="
close_design
launch_runs impl_8 -to_step write_bitstream -jobs 8
wait_on_run impl_8
open_run impl_8
set w8 [get_property SLACK [get_timing_paths -delay_type max -nworst 1]]
set h8 [get_property SLACK [get_timing_paths -delay_type min -nworst 1]]
puts "=== impl_8 (new static): WNS=$w8  WHS=$h8 ==="
puts "=== bitstream: ==="
foreach b [glob -nocomplain $origin/build/dfx.runs/impl_8/*.bit] { puts "  $b" }
exit
