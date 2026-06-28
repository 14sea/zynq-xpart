# M7.5.1 checkpoint-to-fabric: bake a FULL trained 4x4 weight tile (16 INT8 values)
# into the ROUTED impl_7 rm_lutkcm checkpoint by editing the PE weight-LUT6 INITs —
# the generalisation of m73p_edit_init.tcl (which edited only PE[0][0], 3 bits).
#
# Each PE[r][c] holds its INT8 weight as 8 dont_touch LUT6s (g_wbit[b].wlut),
# INIT[0]=WEIGHT[b]. Editing INIT is a property change on the already-placed/routed
# cell => the resulting partial differs from the impl_7 baseline by EXACTLY the
# flipped INIT bits => a clean controlled-diff for prjxray + the on-board ICAP write.
#
# WT = trained tile, row-major W[r][c] (r=0..3 hidden, c=0..3 first 4 inputs), the
# INT8 view of M7.4-tiny's converged W1[0:4][0:4]. Regenerate with:
#   python3 sim/m75_predict.py --tcl-args
# Baseline (lutkcm_array.v) = {1 1 1 1  1 2 3 4  2 2 2 2  1 0 1 0}.
set WT { 3 11 16 12   2 2 -4 -3   2 13 13 15   -4 16 15 12 }

set origin [file normalize [file dirname [info script]]]
set run    $origin/build/dfx.runs/impl_7
open_checkpoint $run/dfx_top_routed.dcp

set INIT1 64'h0000000000000001
set INIT0 64'h0000000000000000

puts "=== M7.5.1: baking trained tile $WT ==="
for {set r 0} {$r < 4} {incr r} {
  for {set c 0} {$c < 4} {incr c} {
    set w [expr {[lindex $WT [expr {$r*4+$c}]] & 0xFF}]   ;# 8-bit two's-complement
    set pe "*g_row\[$r\].g_col\[$c\].pe_i*"
    for {set b 0} {$b < 8} {incr b} {
      set bit [expr {($w >> $b) & 1}]
      set cell [get_cells -hier -filter "NAME =~ ${pe}g_wbit\[$b\].wlut*"]
      set_property INIT [expr {$bit ? "$INIT1" : "$INIT0"}] [get_cells $cell]
    }
  }
}

# Verify the readback matches WT (each PE's 8 LUT INIT[0]s reassembled).
puts "=== verify baked weights ==="
for {set r 0} {$r < 4} {incr r} {
  for {set c 0} {$c < 4} {incr c} {
    set pe "*g_row\[$r\].g_col\[$c\].pe_i*"
    set val 0
    for {set b 0} {$b < 8} {incr b} {
      set cell [get_cells -hier -filter "NAME =~ ${pe}g_wbit\[$b\].wlut*"]
      set in [get_property INIT [get_cells $cell]]
      if {[string match "*1" $in]} { set val [expr {$val | (1 << $b)}] }
    }
    if {$val > 127} { set val [expr {$val - 256}] }
    puts [format "  PE\[%d\]\[%d\] = %d (want %d)" $r $c $val [lindex $WT [expr {$r*4+$c}]]]
  }
}

write_bitstream -force -file $origin/m65_icap/dfx_top_m75tile.bit
puts "=== wrote partial(s) next to m65_icap/dfx_top_m75tile*.bit ==="
exit
