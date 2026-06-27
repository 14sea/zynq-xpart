# g2_place_reroute.tcl — G2 diagnostic: keep the KNOWN-GOOD RM PLACEMENT but throw away
# its routing and reroute fresh against the bad static. Decides placement vs routing/
# config-time as the cause of the M7.2 divergence.
#   correct {19,2,10,-1} on board => placement is the cause & freezable (fix = lock RM place)
#   wrong   {-5,-3,-8}    on board => not placement; it's routing/config-time
#   args: <good_rm_routed.dcp> <out_basename>
set origin [file normalize [file dirname [info script]]]
set bb   $origin/build/dfx.runs/impl_1/dfx_top_routed_bb.dcp
set good [lindex $argv 0]
set out  [lindex $argv 1]
open_checkpoint $bb
read_checkpoint -cell u_soc/wb_tpu_inst $good
puts "== after import: route status =="
report_route_status
# 1. clear the imported RM routing (keep placement)
if {[catch {route_design -unroute -cell [get_cells u_soc/wb_tpu_inst]} m]} {
    puts "== unroute -cell failed ($m); trying global -unroute of RM nets =="
    set rmnets [get_nets -quiet -of [get_cells -hier -filter {NAME =~ u_soc/wb_tpu_inst/*}]]
    catch {route_design -unroute -nets $rmnets}
}
# 2. lock the good RM placement so reroute can't move cells
if {[catch {lock_design -level placement -cell u_soc/wb_tpu_inst} m]} {
    puts "== lock_design -cell failed ($m); fixing LOC on RM leaf cells instead =="
    set_property IS_LOC_FIXED 1 [get_cells -hier -filter {NAME =~ u_soc/wb_tpu_inst/* && IS_PRIMITIVE}]
    set_property IS_BEL_FIXED 1 [get_cells -hier -filter {NAME =~ u_soc/wb_tpu_inst/* && IS_PRIMITIVE}]
}
# 3. reroute the RM in-context (static is fixed)
route_design
puts "== after reroute: route status =="
report_route_status
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
puts "== G2 TIMING: WNS=$wns WHS=$whs =="
write_checkpoint -force ${out}.dcp
write_bitstream -force ${out}
foreach b [glob -nocomplain ${out}*.bit] { puts "  $b" }
exit
