# Step 1 of the DFX restructure: a PS-only block design.
# PS7 + AXI-GPIO(mailbox), exposing fclk_o/rstn_o/mbox_i/mbox_valid_i (+ the
# auto DDR/FIXED_IO) so an RTL top can wire the PS to neorv32_soc_dfx and keep
# the TPU RP cell at top level for DFX. Prints the generated wrapper ports.

set part   xc7z010clg400-1
set origin [file normalize [file dirname [info script]]]
set bdir   $origin/ps_build
create_project ps_bd $bdir -part $part -force

create_bd_design "ps"
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7_0]
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_EN_CLK0_PORT {1} CONFIG.PCW_FCLK_CLK0_BUF {TRUE}] $ps7
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1} \
  CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {1} CONFIG.C_ALL_INPUTS_2 {1}] $gpio
set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_0]
set_property CONFIG.NUM_MI {1} $ic
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0

create_bd_port -dir O fclk_o
create_bd_port -dir O rstn_o
create_bd_port -dir I -from 31 -to 0 mbox_i
create_bd_port -dir I mbox_valid_i

set clk [get_bd_pins ps7_0/FCLK_CLK0]
foreach p {ps7_0/M_AXI_GP0_ACLK axi_ic_0/ACLK axi_ic_0/S00_ACLK axi_ic_0/M00_ACLK \
           axi_gpio_0/s_axi_aclk rst_0/slowest_sync_clk} {
  connect_bd_net $clk [get_bd_pins $p]
}
connect_bd_net $clk [get_bd_ports fclk_o]
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
foreach p {axi_ic_0/ARESETN axi_ic_0/S00_ARESETN axi_ic_0/M00_ARESETN} {
  connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins $p]
}
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_ports rstn_o]
connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0]  [get_bd_intf_pins axi_ic_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
connect_bd_net [get_bd_ports mbox_i]       [get_bd_pins axi_gpio_0/gpio_io_i]
connect_bd_net [get_bd_ports mbox_valid_i] [get_bd_pins axi_gpio_0/gpio2_io_i]

assign_bd_address
validate_bd_design
save_bd_design
make_wrapper -files [get_files ps.bd] -top -import
puts "=== GPIO base: [get_property OFFSET [get_bd_addr_segs ps7_0/Data/SEG_axi_gpio_0_Reg]] ==="
puts "=== WRAPPER FILE ==="
set wf [glob $bdir/ps_bd.gen/sources_1/bd/ps/hdl/ps_wrapper.v]
puts $wf
puts "=== WRAPPER PORT BLOCK ==="
set fh [open $wf r]
foreach line [split [read $fh] "\n"] {
  if {[regexp {^\s*(module|input|output|inout|\);)} $line]} { puts $line }
}
close $fh
exit
