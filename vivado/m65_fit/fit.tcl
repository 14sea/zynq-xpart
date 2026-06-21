# M6.5 fit-check: OOC synth the worst-case LUT-KCM 4x4 array, report LUT/DSP.
set here [file dirname [info script]]
read_verilog $here/m65_fit.v
synth_design -top m65_fit -part xc7z010clg400-1 -mode out_of_context -flatten_hierarchy rebuilt
report_utilization -file $here/m65_fit_util.rpt
# Pull the headline numbers to stdout.
set luts [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
set dsps [llength [get_cells -hier -filter {PRIMITIVE_GROUP == DSP || REF_NAME =~ DSP*}]]
set ffs  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
puts "=== M65_FIT RESULT: LUT=$luts  DSP=$dsps  FF=$ffs ==="
puts "=== GATE: 4x4 LUT array must be <= ~1600 LUT to fit RP headroom (4400 - 2799 used) ==="
exit
