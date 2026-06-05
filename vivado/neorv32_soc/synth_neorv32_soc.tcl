# Synthesis check for the M2 SoC top (NEORV32 + TPU on XBUS).
# Validates the full compute-core port for XC7Z010 before block-design integration.
#   vivado -mode batch -source synth_neorv32_soc.tcl

set part   xc7z010clg400-1
set origin [file normalize [file dirname [info script]]]
set root   [file normalize $origin/../..]
set nhome  $root/rtl_src/neorv32_tpu/neorv32

create_project soc_synth $origin/build -part $part -force

# NEORV32 SoC sources (library neorv32)
set fl [read [open $nhome/rtl/file_list_soc.f r]]
set fl [string map [list NEORV32_RTL_PATH_PLACEHOLDER $nhome/rtl] $fl]
add_files $fl
set_property library neorv32 [get_files $fl]

# TPU Verilog + SoC top
add_files [glob $root/rtl/pe.v $root/rtl/systolic_array_4x4.v $root/rtl/tpu_accel.v $root/rtl/wb_tpu_accel.v]
add_files $root/rtl/neorv32_soc.vhd
set_property top neorv32_soc [current_fileset]
update_compile_order -fileset sources_1

synth_design -top neorv32_soc -part $part
puts "=== SYNTH_OK ==="
report_utilization -return_string
exit
