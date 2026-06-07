# T1b — PS->PL AXI *write* loopback test for EBAZ4205 (XC7Z010).
#   Zynq PS7 --M_AXI_GP0--> AXI-GPIO dual channel
#     ch1 = OUTPUT (32b), drives gpio_io_o; C_TRI_DEFAULT=0 so outputs are active
#          from reset WITHOUT needing a runtime TRI write (the TRI write would
#          itself be a PS->PL write, i.e. the thing under test — avoid the dependency).
#     ch2 = INPUT  (32b), reads gpio2_io_i.
#   gpio_io_o (ch1) is looped back internally to gpio2_io_i (ch2).
#
# Test from PS (U-Boot or Linux):
#   read  ch2 @ base+0x08  -> expect 0x00000000 (C_DOUT_DEFAULT) before any write
#   write ch1 @ base+0x00 = 0xA5A5A5A5
#   read  ch2 @ base+0x08  -> if 0xA5A5A5A5 the PS->PL AXI WRITE landed and drove PL.
#                             if still 0x00000000 the write did NOT reach the PL.
#
# Run:  source <Vivado>/settings64.sh ; vivado -mode batch -source build_axi_wtest.tcl

set proj   axi_wtest
set part   xc7z010clg400-1
set origin [file normalize [file dirname [info script]]]
set bdir   $origin/build

create_project $proj $bdir -part $part -force

create_bd_design "system"

# --- Zynq PS7 (minimal: GP0 master + FCLK0) ---
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7_0]
set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_EN_CLK0_PORT {1} \
  CONFIG.PCW_FCLK_CLK0_BUF {TRUE} \
] $ps7

# --- AXI-GPIO dual: ch1 output (active at reset), ch2 input ---
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {32} \
  CONFIG.C_ALL_INPUTS {0} \
  CONFIG.C_TRI_DEFAULT {0x00000000} \
  CONFIG.C_DOUT_DEFAULT {0x00000000} \
  CONFIG.C_IS_DUAL {1} \
  CONFIG.C_GPIO2_WIDTH {32} \
  CONFIG.C_ALL_INPUTS_2 {1} \
] $gpio

# --- AXI interconnect (AXI3 GP0 -> AXI4-Lite gpio) + reset ---
set ic  [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_0]
set_property -dict [list CONFIG.NUM_MI {1}] $ic
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0

# --- clocks ---
set clk [get_bd_pins ps7_0/FCLK_CLK0]
foreach p {ps7_0/M_AXI_GP0_ACLK axi_ic_0/ACLK axi_ic_0/S00_ACLK axi_ic_0/M00_ACLK \
           axi_gpio_0/s_axi_aclk rst_0/slowest_sync_clk} {
  connect_bd_net $clk [get_bd_pins $p]
}

# --- resets ---
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
foreach p {axi_ic_0/ARESETN axi_ic_0/S00_ARESETN axi_ic_0/M00_ARESETN} {
  connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins $p]
}
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]

# --- AXI data path ---
connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0]  [get_bd_intf_pins axi_ic_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]

# --- internal loopback: ch1 output -> ch2 input ---
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins axi_gpio_0/gpio2_io_i]

assign_bd_address
validate_bd_design
save_bd_design
puts "=== GPIO base address ==="
puts [get_property OFFSET [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7_0/Data]]]

# --- wrapper + run to bitstream ---
make_wrapper -files [get_files system.bd] -top -import
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "=== IMPL STATUS: [get_property STATUS [get_runs impl_1]] ==="
puts "=== PROGRESS:    [get_property PROGRESS [get_runs impl_1]] ==="
foreach b [glob -nocomplain $bdir/$proj.runs/impl_1/*.bit] { puts "=== BITSTREAM: $b" }
exit
