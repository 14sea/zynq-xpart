set origin [file normalize [file dirname [info script]]]
foreach r {impl_1 impl_2 impl_3} {
  open_checkpoint $origin/artifacts/$r/dfx_top_routed.dcp
  set fp [open $origin/artifacts/$r/array_fingerprint.txt w]
  puts $fp "roll $r"
  set dsps [lsort [get_cells -hier -filter {REF_NAME == DSP48E1}]]
  puts $fp "DSP48E1 count: [llength $dsps]"
  foreach c $dsps { puts $fp "DSP  [get_property LOC $c]  $c" }
  puts $fp "array leaf cells: [llength [get_cells -hier -filter {NAME =~ u_soc/wb_tpu_inst/*}]]"
  close $fp
  close_design
}
exit
