# T2.3 build (BRAM-staged payload): PS7 + neorv32_soc_icap (NEORV32 -> xbus_icap ->
# ICAPE2 + AXI-Lite framebuf) + AXI-GPIO. The PS stages the ICAP frame sequence into the
# SoC's AXI-Lite framebuf, grants PCAP_PR=0, and NEORV32 streams it to ICAP -> flips the
# LUT. Single build: lut_A.bit (INIT[0]=0, the one we LOAD) + lut_B.bit (INIT[0]=1, for
# host frame extraction). CRC disabled so loadb of lut_A works and the frame is clean.
#
#   vivado -mode batch -source build_t23b.tcl

set proj   t23b
set part   xc7z010clg400-1
set origin [file normalize [file dirname [info script]]]
set root   [file normalize $origin/../..]
set nhome  $root/rtl_src/neorv32_tpu/neorv32
set bdir   $origin/buildb

create_project $proj $bdir -part $part -force

set fl [read [open $nhome/rtl/file_list_soc.f r]]
set fl [string map [list NEORV32_RTL_PATH_PLACEHOLDER $nhome/rtl] $fl]
add_files $fl
set_property library neorv32 [get_files $fl]
add_files [glob $root/rtl/xbus_icap.v $root/rtl/lut_probe.v]
add_files [list $root/rtl/axil_framebuf.vhd $root/rtl/neorv32_soc_icap.vhd]
update_compile_order -fileset sources_1

create_bd_design "system"
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7_0]
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_EN_CLK0_PORT {1} CONFIG.PCW_FCLK_CLK0_BUF {TRUE}] $ps7
create_bd_cell -type module -reference neorv32_soc_icap soc_0

set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1} \
  CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {32} CONFIG.C_ALL_INPUTS_2 {1}] $gpio

set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_0]
set_property CONFIG.NUM_MI {2} $ic
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0
set c1 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant const1]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $c1

set clk [get_bd_pins ps7_0/FCLK_CLK0]
foreach p {ps7_0/M_AXI_GP0_ACLK axi_ic_0/ACLK axi_ic_0/S00_ACLK axi_ic_0/M00_ACLK \
           axi_ic_0/M01_ACLK axi_gpio_0/s_axi_aclk rst_0/slowest_sync_clk \
           soc_0/clk_i soc_0/s_axi_aclk} {
  connect_bd_net $clk [get_bd_pins $p]
}
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
foreach p {axi_ic_0/ARESETN axi_ic_0/S00_ARESETN axi_ic_0/M00_ARESETN axi_ic_0/M01_ARESETN} {
  connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins $p]
}
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins soc_0/rstn_i]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins soc_0/s_axi_aresetn]

connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0]  [get_bd_intf_pins axi_ic_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M01_AXI] [get_bd_intf_pins soc_0/S_AXI]

connect_bd_net [get_bd_pins soc_0/lut_o]  [get_bd_pins axi_gpio_0/gpio_io_i]
connect_bd_net [get_bd_pins soc_0/mbox_o] [get_bd_pins axi_gpio_0/gpio2_io_i]
connect_bd_net [get_bd_pins const1/dout]  [get_bd_pins soc_0/uart0_rxd_i]

assign_bd_address
validate_bd_design
save_bd_design
puts "=== ADDRESS MAP ==="
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7_0/Data]] {
  puts "  $seg -> [get_property OFFSET $seg]  range [get_property RANGE $seg]"
}

make_wrapper -files [get_files system.bd] -top -import
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
puts "=== IMPL: [get_property STATUS [get_runs impl_1]] ==="

open_run impl_1
set_property BITSTREAM.GENERAL.CRC Disable [current_design]
set lut [get_cells -hier -filter {REF_NAME == LUT6 && NAME =~ *l_probe*}]
puts "=== LUT cell: $lut  LOC=[get_property LOC $lut] ==="
set_property INIT 64'h0000000000000000 $lut
write_bitstream -force $bdir/lut_A.bit
set_property INIT 64'h0000000000000001 $lut
write_bitstream -force $bdir/lut_B.bit
puts "=== A(load this): $bdir/lut_A.bit  B(extract frame): $bdir/lut_B.bit ==="
exit
