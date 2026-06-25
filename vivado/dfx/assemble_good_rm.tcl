# assemble_good_rm.tcl — import the KNOWN-GOOD rm_train place+route (from the diag2
# build) onto the BAD-size (diag2pad) static, freezing the ENTIRE RP region (DSP +
# CARRY4 psum chains + FFs + routing) to good. Tests M7.2 fix (b), strong variant:
# "lock the known-good RP route." If the board then computes {19,2,10,-1}, the RM's
# internal fabric place+route is the cause and locking it is the fix.
set origin [file normalize [file dirname [info script]]]
set bb   $origin/build/dfx.runs/impl_1/dfx_top_routed_bb.dcp
set good [lindex $argv 0]
set out  [lindex $argv 1]
open_checkpoint $bb
read_checkpoint -cell u_soc/wb_tpu_inst $good
# legalize/lock the imported RM, verify DFX rules
catch {pr_verify -full_check} msg
puts "== pr_verify: $msg =="
report_route_status
write_checkpoint -force ${out}.dcp
write_bitstream -force -bin_file $out
puts "== assembled bitstreams =="
foreach b [glob -nocomplain ${out}*.bit] { puts "  $b" }
exit
