# M2 block design: PS7 + neorv32_soc (NEORV32+TPU) + AXI-GPIO on the mailbox.
# The PS reads the firmware result (mbox_o) at the AXI-GPIO address.
#   vivado -mode batch -source build_m2.tcl
#
# Until the real firmware image is built, NEORV32 boots the default IMEM image
# (BOOT_MODE_SELECT=2); this run validates synth/impl/bitstream + the PS<->PL path.

set proj   m2
set part   xc7z010clg400-1
set origin [file normalize [file dirname [info script]]]
set root   [file normalize $origin/../..]
set nhome  $root/rtl_src/neorv32_tpu/neorv32
set bdir   $origin/build

create_project $proj $bdir -part $part -force

# sources
set fl [read [open $nhome/rtl/file_list_soc.f r]]
set fl [string map [list NEORV32_RTL_PATH_PLACEHOLDER $nhome/rtl] $fl]
add_files $fl
set_property library neorv32 [get_files $fl]
add_files [glob $root/rtl/pe.v $root/rtl/systolic_array_4x4.v $root/rtl/tpu_accel.v $root/rtl/wb_tpu_accel.v]
add_files $root/rtl/neorv32_soc.vhd
update_compile_order -fileset sources_1

create_bd_design "system"

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7_0]
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_EN_CLK0_PORT {1} CONFIG.PCW_FCLK_CLK0_BUF {TRUE}] $ps7

# NEORV32+TPU SoC as a module reference
create_bd_cell -type module -reference neorv32_soc soc_0

# AXI-GPIO: ch1 = mbox[31:0] (input), ch2 = mbox_valid (1-bit input)
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1} \
  CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {1} CONFIG.C_ALL_INPUTS_2 {1}] $gpio

set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_0]
set_property CONFIG.NUM_MI {1} $ic
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0

# UART rx idle-high constant
set c1 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant const1]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $c1

# clocks
set clk [get_bd_pins ps7_0/FCLK_CLK0]
foreach p {ps7_0/M_AXI_GP0_ACLK axi_ic_0/ACLK axi_ic_0/S00_ACLK axi_ic_0/M00_ACLK \
           axi_gpio_0/s_axi_aclk rst_0/slowest_sync_clk soc_0/clk_i} {
  connect_bd_net $clk [get_bd_pins $p]
}
# resets
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
foreach p {axi_ic_0/ARESETN axi_ic_0/S00_ARESETN axi_ic_0/M00_ARESETN} {
  connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins $p]
}
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins soc_0/rstn_i]
# AXI
connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0]  [get_bd_intf_pins axi_ic_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
# mailbox -> gpio inputs
connect_bd_net [get_bd_pins soc_0/mbox_o]       [get_bd_pins axi_gpio_0/gpio_io_i]
connect_bd_net [get_bd_pins soc_0/mbox_valid_o] [get_bd_pins axi_gpio_0/gpio2_io_i]
# uart rx idle
connect_bd_net [get_bd_pins const1/dout] [get_bd_pins soc_0/uart0_rxd_i]

assign_bd_address
validate_bd_design
save_bd_design
puts "=== GPIO base: [get_property OFFSET [get_bd_addr_segs ps7_0/Data/SEG_axi_gpio_0_Reg]] ==="

make_wrapper -files [get_files system.bd] -top -import
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "=== IMPL: [get_property STATUS [get_runs impl_1]] / [get_property PROGRESS [get_runs impl_1]] ==="
foreach b [glob -nocomplain $bdir/$proj.runs/impl_1/*.bit] { puts "=== BIT: $b" }
exit
