# timing_check.tcl <routed.dcp> <out.txt> — hold + unconstrained focus on the array
set dcp [lindex $argv 0]; set out [lindex $argv 1]
open_checkpoint $dcp
set fp [open $out w]
# overall WNS/WHS + unconstrained count
puts $fp "== timing summary =="
puts $fp [report_timing_summary -no_detailed_paths -return_string]
# worst HOLD paths anywhere
puts $fp "\n== worst 8 HOLD paths (min) =="
foreach p [get_timing_paths -delay_type min -max_paths 8 -nworst 1] {
  puts $fp "  WHS=[get_property SLACK $p]  from=[get_property STARTPOINT_PIN $p] -> to=[get_property ENDPOINT_PIN $p]"
}
# worst HOLD specifically ending inside the array (psum/x regs)
puts $fp "\n== worst HOLD ending in systolic array =="
set arrcells [get_cells -hier -quiet -filter {NAME =~ *sa_inst/pe_?_?*}]
foreach p [get_timing_paths -delay_type min -max_paths 8 -nworst 1 -to [get_pins -quiet -of $arrcells -filter {IS_CLOCK==0 && DIRECTION==IN}]] {
  puts $fp "  WHS=[get_property SLACK $p]  from=[get_property STARTPOINT_PIN $p] -> to=[get_property ENDPOINT_PIN $p]"
}
# any unconstrained paths in the array clock?
puts $fp "\n== check_timing (unconstrained / no_clock) =="
puts $fp [check_timing -return_string -verbose -override_defaults no_clock]
close $fp
puts "timing check written: $out"
exit
