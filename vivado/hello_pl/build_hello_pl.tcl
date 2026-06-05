# Phase-1 "Hello-PL" reproducible build for EBAZ4205 (XC7Z010).
#   Zynq PS7  --M_AXI_GP0-->  AXI-GPIO(32b, input)  <--  free-running PL counter
# The ARM side reads the GPIO data reg over AXI and sees an incrementing value,
# proving a self-made bitstream runs on the board via the A-route.
#
# Run:  source <Vivado>/settings64.sh
#       vivado -mode batch -source build_hello_pl.tcl
#
# Note: PL-only design loaded into the already-running miner Linux, so the PS7
# DDR/MIO preset is irrelevant at runtime (FSBL already configured the PS).

set proj   hello_pl
set part   xc7z010clg400-1
set origin [file normalize [file dirname [info script]]]
set root   [file normalize $origin/../..]
set bdir   $origin/build

create_project $proj $bdir -part $part -force

add_files -norecurse $root/rtl/counter.v
update_compile_order -fileset sources_1

create_bd_design "system"

# --- Zynq PS7 (minimal: GP0 master + FCLK0) ---
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7_0]
set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_EN_CLK0_PORT {1} \
  CONFIG.PCW_FCLK_CLK0_BUF {TRUE} \
] $ps7

# --- AXI-GPIO, 32-bit, all inputs ---
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1}] $gpio

# --- PL counter (RTL module reference) ---
create_bd_cell -type module -reference counter counter_0

# --- AXI interconnect (AXI3 GP0 -> AXI4-Lite gpio) + reset ---
set ic  [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_0]
set_property -dict [list CONFIG.NUM_MI {1}] $ic
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0

# --- clocks ---
set clk [get_bd_pins ps7_0/FCLK_CLK0]
foreach p {ps7_0/M_AXI_GP0_ACLK axi_ic_0/ACLK axi_ic_0/S00_ACLK axi_ic_0/M00_ACLK \
           axi_gpio_0/s_axi_aclk rst_0/slowest_sync_clk counter_0/clk} {
  connect_bd_net $clk [get_bd_pins $p]
}

# --- resets ---
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
foreach p {axi_ic_0/ARESETN axi_ic_0/S00_ARESETN axi_ic_0/M00_ARESETN} {
  connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins $p]
}
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins counter_0/resetn]

# --- AXI data path ---
connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0]  [get_bd_intf_pins axi_ic_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]

# --- counter value -> gpio input ---
connect_bd_net [get_bd_pins counter_0/cnt] [get_bd_pins axi_gpio_0/gpio_io_i]

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
