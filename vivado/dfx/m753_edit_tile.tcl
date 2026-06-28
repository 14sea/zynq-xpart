# M7.5.3-lite: bake an arbitrary 4x4 INT8 weight tile into the ROUTED impl_7
# rm_lutkcm checkpoint (generalises m75_edit_tile.tcl with args, so L1 and L2 each
# get their own controlled-diff partial). Edits the 16 PE weight-LUT6 INITs only.
#
#   vivado -mode batch -source m753_edit_tile.tcl -tclargs <name> w0 w1 ... w15
# where w0..w15 = row-major W[r][c]. Writes m65_icap/dfx_top_<name>*.bit.
set name [lindex $argv 0]
set WT   [lrange $argv 1 16]
if {[llength $WT] != 16} { error "need <name> + 16 ints, got: $argv" }

set origin [file normalize [file dirname [info script]]]
open_checkpoint $origin/build/dfx.runs/impl_7/dfx_top_routed.dcp

set INIT1 64'h0000000000000001
set INIT0 64'h0000000000000000
puts "=== M7.5.3-lite: baking tile '$name' = $WT ==="
for {set r 0} {$r < 4} {incr r} {
  for {set c 0} {$c < 4} {incr c} {
    set w [expr {[lindex $WT [expr {$r*4+$c}]] & 0xFF}]
    set pe "*g_row\[$r\].g_col\[$c\].pe_i*"
    for {set b 0} {$b < 8} {incr b} {
      set bit  [expr {($w >> $b) & 1}]
      set cell [get_cells -hier -filter "NAME =~ ${pe}g_wbit\[$b\].wlut*"]
      set_property INIT [expr {$bit ? "$INIT1" : "$INIT0"}] [get_cells $cell]
    }
  }
}
# verify readback
for {set r 0} {$r < 4} {incr r} {
  for {set c 0} {$c < 4} {incr c} {
    set pe "*g_row\[$r\].g_col\[$c\].pe_i*"; set val 0
    for {set b 0} {$b < 8} {incr b} {
      set cell [get_cells -hier -filter "NAME =~ ${pe}g_wbit\[$b\].wlut*"]
      if {[string match "*1" [get_property INIT [get_cells $cell]]]} { set val [expr {$val | (1 << $b)}] }
    }
    if {$val > 127} { set val [expr {$val - 256}] }
    puts [format "  PE\[%d\]\[%d\] = %d (want %d)" $r $c $val [lindex $WT [expr {$r*4+$c}]]]
  }
}
write_bitstream -force -file $origin/m65_icap/dfx_top_$name.bit
puts "=== wrote m65_icap/dfx_top_${name}*.bit ==="
exit
